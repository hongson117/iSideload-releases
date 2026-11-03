//! Deliver only the chosen recipient's key and pairing over an authenticated
//! app-container connection. Never copy Apple ID passwords into an IPA or JSON.
use std::path::Path;
use idevice::{afc::{AfcClient,errors::AfcError,opcode::AfcFopenMode},IdeviceError};
use rsa::{pkcs8::DecodePrivateKey,pkcs1::EncodeRsaPublicKey,RsaPrivateKey};
use x509_cert::{Certificate,der::Decode};
use serde_json::{json,Value};
use crate::ops::s;

pub struct RecipientFiles { pub key_path:String, pub key:Option<Vec<u8>>, pub pairing:Vec<u8>,pub identity:Vec<u8> }
pub fn prepare(req:&Value,app:&Path,team:&str,udid:&str)->Result<RecipientFiles,String>{
    let (bundle,_,_)=crate::ops::bundle_info(app);
    if !crate::owner_setup::own_id(&bundle) {return Err("Chỉ thiết lập dữ liệu cho iContainer của người nhận.".into());}
    let account=s(req,"apple_id");
    let hash=crate::owner_setup::hash(account.as_bytes());
    let profile=apple_codesign_quick::ProvisioningProfile::parse(&std::fs::read(app.join("embedded.mobileprovision")).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    if !profile.team_id().eq_ignore_ascii_case(team){return Err("Team của bản cài người nhận không khớp.".into());}
    let bootstrap=req.get("recipient_bootstrap").and_then(Value::as_bool).unwrap_or(false);
    let key=if bootstrap {None}else{
        let key=std::fs::read(Path::new(s(req,"storage_dir")).join(&hash).join("key")).map_err(|_|"Không có khóa ký của tài khoản người nhận.")?;
        let rsa=RsaPrivateKey::from_pkcs8_der(&key).map_err(|_|"Khóa ký không hợp lệ.")?;
        let public=rsa.to_public_key().to_pkcs1_der().map_err(|e|e.to_string())?;
        let certs=profile.plist().get("DeveloperCertificates").and_then(plist::Value::as_array).ok_or("Profile thiếu chứng chỉ ký.")?;
        let matches=certs.iter().filter_map(plist::Value::as_data).filter_map(|d|Certificate::from_der(d).ok()).any(|c|c.tbs_certificate.subject_public_key_info.subject_public_key.as_bytes()==Some(public.as_bytes()));
        if !matches{return Err("Khóa được chuyển không phải khóa đã ký bản cài người nhận.".into());}
        Some(key)
    };
    let pairing=std::fs::read(s(req,"pairing_path")).map_err(|_|"Không đọc được ghép nối của máy nhận.")?;
    if pairing.len()>64*1024 || plist::from_bytes::<plist::Dictionary>(&pairing).is_err(){return Err("Bản ghi ghép nối không hợp lệ.".into());}
    let identity=serde_json::to_vec(&json!({"schema":1,"bundle_id":bundle,"team_id":team,"apple_id":account,"udid":udid,"bootstrap":bootstrap})).map_err(|e|e.to_string())?;
    Ok(RecipientFiles{key_path:format!("/Documents/Storage/{hash}/key"),key,pairing,identity})
}
fn missing(e:&IdeviceError)->bool{matches!(e,IdeviceError::Afc(AfcError::ObjectNotFound))}
async fn read(afc:&mut AfcClient,path:&str)->Result<Option<Vec<u8>>,String>{
    let info=match afc.get_file_info(path).await{Ok(i)=>i,Err(e)if missing(&e)=>return Ok(None),Err(e)=>return Err(e.to_string())};
    if info.size>128*1024{return Err("File thiết lập cũ lớn bất thường; chưa thay dữ liệu.".into());}
    let mut f=afc.open(path,AfcFopenMode::RdOnly).await.map_err(|e|e.to_string())?;
    let bytes=f.read_n(info.size).await;let closed=f.close().await;
    let bytes=bytes.map_err(|e|e.to_string())?;closed.map_err(|e|e.to_string())?;
    if bytes.len()!=info.size{return Err("Đọc file thiết lập chưa đủ.".into());}Ok(Some(bytes))
}
async fn dir(afc:&mut AfcClient,path:&str)->Result<(),String>{
    match afc.get_file_info(path).await{
        Ok(i)if i.st_ifmt=="S_IFDIR"=>Ok(()),Ok(_)=>Err("Thư mục thiết lập bị thay bằng file; chưa ghi đè.".into()),
        Err(e)if missing(&e)=>afc.mk_dir(path).await.map_err(|e|e.to_string()),Err(e)=>Err(e.to_string())
    }
}
async fn replace(afc:&mut AfcClient,path:&str,bytes:&[u8],nonce:&str)->Result<(),String>{
    let old=read(afc,path).await?;if old.as_deref()==Some(bytes){return Ok(());}
    let temp=format!("{path}.new-{nonce}");let backup=format!("{path}.before-{nonce}");
    let mut f=afc.open(&temp,AfcFopenMode::WrOnly).await.map_err(|e|e.to_string())?;
    let written=f.write_entire(bytes).await;let closed=f.close().await;
    written.map_err(|e|e.to_string())?;closed.map_err(|e|e.to_string())?;
    if read(afc,&temp).await?.as_deref()!=Some(bytes){return Err("File tạm đọc lại không khớp.".into());}
    if old.is_some(){afc.rename(path,&backup).await.map_err(|e|e.to_string())?;}
    if let Err(e)=afc.rename(&temp,path).await{if old.is_some(){let _=afc.rename(&backup,path).await;}return Err(e.to_string());}
    if read(afc,path).await?.as_deref()!=Some(bytes){
        let _=afc.remove(path).await;if old.is_some(){let _=afc.rename(&backup,path).await;}
        return Err("File thiết lập đọc lại không khớp; đã khôi phục bản cũ.".into());
    }Ok(())
}
pub async fn deliver(afc:&mut AfcClient,files:&RecipientFiles)->Result<(),String>{
    let nonce=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|e|e.to_string())?.as_nanos().to_string();
    tokio::time::timeout(std::time::Duration::from_secs(45),async{
        dir(afc,"/Documents/Storage").await?;
        // An existing parseable record may be the user's own newer pairing.
        let current=read(afc,"/Documents/Storage/pairing.plist").await?;
        if current.as_ref().is_none_or(|b|plist::from_bytes::<plist::Dictionary>(b).is_err()){
            replace(afc,"/Documents/Storage/pairing.plist",&files.pairing,&nonce).await?;
        }
        if let Some(key)=files.key.as_deref(){
            let parent=files.key_path.rsplit_once('/').ok_or("Invalid key path")?.0;dir(afc,parent).await?;
            replace(afc,&files.key_path,key,&nonce).await?;
        }
        replace(afc,"/Documents/Storage/installation-identity.json",&files.identity,&nonce).await?;
        Ok::<_,String>(())
    }).await.map_err(|_|"Hết thời gian thiết lập máy nhận; giữ máy mở khóa rồi thử lại.".to_string())?
}
