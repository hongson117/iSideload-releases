//! Transactional storage for iContainer. Guest data is never replaced during
//! preparation; only a successfully patched and signed copy becomes launchable.
use std::{fs, io::{Read, Write}, path::{Path, PathBuf}};
use apple_codesign_quick::{ProvisioningProfile, RustCryptoCmsSigner};
use base64::Engine as _;
use p12_keystore::{KeyStore, Pkcs12ImportPolicy};
use plist::Value as PV;
use rsa::{pkcs8::DecodePrivateKey, RsaPrivateKey};
use serde_json::{json, Value};
use x509_cert::{Certificate, der::Decode};
use crate::{container_macho as macho, ops::s};

const MAX_ENTRIES: usize = 60_000;
const MAX_TOTAL: u64 = 2 * 1024 * 1024 * 1024;
const MAX_FILE: u64 = 512 * 1024 * 1024;

fn err(e: impl std::fmt::Display) -> String { e.to_string() }
fn valid_id(id: &str) -> bool {
    id.len()==36 && id.bytes().enumerate().all(|(i,b)| if [8,13,18,23].contains(&i) { b==b'-' } else { b.is_ascii_hexdigit() })
}
fn root(req: &Value) -> Result<PathBuf,String> {
    let p = PathBuf::from(s(req,"container_root"));
    if !p.is_absolute() || p.file_name().and_then(|s|s.to_str()) != Some("iContainer") { return Err("Invalid iContainer storage root".into()); }
    fs::create_dir_all(&p).map_err(err)?;
    if fs::symlink_metadata(&p).map_err(err)?.file_type().is_symlink() { return Err("Container root must not be a symlink".into()); }
    fs::canonicalize(p).map_err(err)
}
fn guest(req: &Value) -> Result<PathBuf,String> {
    let id = s(req,"guest_id");
    if !valid_id(id) { return Err("Invalid guest identifier".into()); }
    let p = root(req)?.join(id);
    if p.exists() && fs::symlink_metadata(&p).map_err(err)?.file_type().is_symlink() { return Err("Guest path must not be a symlink".into()); }
    Ok(p)
}
fn atomic_json(path: &Path, value: &Value) -> Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp,serde_json::to_vec_pretty(value).map_err(err)?).map_err(err)?;
    fs::rename(tmp,path).map_err(err)
}
fn extract(ipa: &Path, to: &Path) -> Result<PathBuf,String> {
    let mut zip = zip::ZipArchive::new(fs::File::open(ipa).map_err(err)?).map_err(err)?;
    if zip.len()>MAX_ENTRIES { return Err("IPA có quá nhiều file.".into()); }
    let mut total=0u64;
    let mut names=std::collections::HashSet::new();
    let mut app_name: Option<String> = None;
    // Validate the entire directory before writing a single entry.
    for i in 0..zip.len() {
        let f=zip.by_index(i).map_err(err)?;
        let name=f.name();
        if name.contains('\\') || name.contains('\0') || name.split('/').any(|p| p==".." || p.contains(':')) || f.enclosed_name().is_none() { return Err("IPA chứa đường dẫn không an toàn.".into()); }
        if !names.insert(name.trim_end_matches('/').to_lowercase()) { return Err("IPA chứa đường dẫn trùng lặp.".into()); }
        let mode=f.unix_mode().unwrap_or(0o100644)&0o170000;
        if mode!=0 && mode!=0o100000 && mode!=0o040000 { return Err("Bản thử không nhận symlink hoặc file đặc biệt trong IPA.".into()); }
        total=total.checked_add(f.size()).ok_or("IPA size overflow")?;
        if f.size()>MAX_FILE || total>MAX_TOTAL { return Err("IPA vượt giới hạn giải nén của bản thử (2 GiB, 512 MiB/file).".into()); }
        let parts: Vec<_>=name.split('/').collect();
        if parts.len()==3 && parts[0]=="Payload" && parts[1].ends_with(".app") && parts[2]=="Info.plist" {
            if app_name.is_some() { return Err("IPA phải chứa đúng một app chính.".into()); }
            app_name=Some(parts[1].into());
        }
    }
    let app_name=app_name.ok_or("IPA không có Payload/*.app/Info.plist.")?;
    let prefix=format!("Payload/{app_name}/");
    let app=to.join("Original.app"); fs::create_dir_all(&app).map_err(err)?;
    for i in 0..zip.len() {
        let mut f=zip.by_index(i).map_err(err)?;
        let Some(rel)=f.name().strip_prefix(&prefix) else { continue; };
        if rel.is_empty() { continue; }
        let out=app.join(rel);
        if f.is_dir() { fs::create_dir_all(out).map_err(err)?; continue; }
        fs::create_dir_all(out.parent().ok_or("Invalid archive path")?).map_err(err)?;
        let mut file=fs::OpenOptions::new().create_new(true).write(true).open(&out).map_err(err)?;
        let expected=f.size();
        let copied=std::io::copy(&mut (&mut f).take(MAX_FILE+1),&mut file).map_err(err)?;
        if copied!=expected || copied>MAX_FILE { return Err("IPA file size does not match directory".into()); }
        #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; fs::set_permissions(out,fs::Permissions::from_mode(0o700)).map_err(err)?; }
    }
    Ok(app)
}
fn info(app:&Path)->Result<plist::Dictionary,String> { plist::from_file(app.join("Info.plist")).map_err(err) }
fn strval<'a>(d:&'a plist::Dictionary,key:&str)-> &'a str { d.get(key).and_then(PV::as_string).unwrap_or("") }
fn executable(d:&plist::Dictionary)->Result<&str,String> {
    let name=strval(d,"CFBundleExecutable");
    if name.is_empty() || name=="." || name==".." || name.contains(['/', '\\', ':']) { return Err("Invalid CFBundleExecutable".into()); }
    Ok(name)
}
fn validate_app(app:&Path)->Result<Value,String> {
    let d=info(app)?;
    let platforms=d.get("CFBundleSupportedPlatforms").and_then(PV::as_array);
    let family=d.get("UIDeviceFamily").and_then(PV::as_array);
    if strval(&d,"DTPlatformName").starts_with("appletv") || platforms.is_some_and(|a| a.iter().any(|v| v.as_string()!=Some("iPhoneOS"))) || family.is_some_and(|a|a.iter().any(|v|v.as_unsigned_integer()==Some(3))) { return Err("Chỉ nhận IPA iPhone/iPad thật, không nhận tvOS hoặc simulator.".into()); }
    let mut components=Vec::new();
    if app.join("PlugIns").is_dir(){components.push("extensions");}
    if app.join("Watch").is_dir(){components.push("watch");}
    let bundle=strval(&d,"CFBundleIdentifier");
    if bundle.is_empty() { return Err("IPA không có Bundle ID.".into()); }
    let exe=executable(&d)?;
    // Verify the entry point and FairPlay status before committing an import.
    macho::prepare(&fs::read(app.join(exe)).map_err(err)?,true)?;
    Ok(json!({"bundle_id":bundle,"name":if strval(&d,"CFBundleDisplayName").is_empty(){strval(&d,"CFBundleName")}else{strval(&d,"CFBundleDisplayName")},"version":strval(&d,"CFBundleShortVersionString"),"executable":exe,"embedded_components":components,"main_app_only":!components.is_empty()}))
}
pub fn import(req:&Value)->Result<Value,String> {
    let dest=guest(req)?;
    if dest.exists() { return Err("Guest identifier already exists; existing data was preserved".into()); }
    let staging=dest.with_extension("importing");
    if staging.exists() { return Err("Lần nhập trước chưa hoàn tất. Hãy thử nhập lại với danh tính mới.".into()); }
    fs::create_dir(&staging).map_err(err)?;
    let result=(|| {
        let app=extract(Path::new(s(req,"ipa_path")),&staging)?;
        let mut record=validate_app(&app)?;
        record["id"]=json!(s(req,"guest_id")); record["prepared"]=json!(false);
        for d in ["Documents","Library/Preferences","Library/Caches","tmp"] { fs::create_dir_all(staging.join("Data").join(d)).map_err(err)?; }
        atomic_json(&staging.join("manifest.json"),&record)?;
        fs::rename(&staging,&dest).map_err(err)?;
        Ok(json!({"ok":true,"guest":record}))
    })();
    if result.is_err() { let _=fs::remove_dir_all(&staging); }
    result
}
fn copy_tree(from:&Path,to:&Path)->Result<(),String> {
    fs::create_dir_all(to).map_err(err)?;
    for e in fs::read_dir(from).map_err(err)? {
        let e=e.map_err(err)?; let ty=e.file_type().map_err(err)?;
        if ty.is_symlink() { return Err("Unexpected symlink in guest bundle".into()); }
        if ty.is_dir() { copy_tree(&e.path(),&to.join(e.file_name()))?; }
        else if ty.is_file() { fs::copy(e.path(),to.join(e.file_name())).map_err(err)?; }
        else { return Err("Unexpected special file".into()); }
    } Ok(())
}
/// Preserve all components in Original.app. The loadable copy contains only
/// the iPhone application; iOS extensions and watchOS executables are not
/// registered or loaded by this in-process launcher.
fn copy_main_app(from:&Path,to:&Path)->Result<(),String>{
    fs::create_dir_all(to).map_err(err)?;
    for e in fs::read_dir(from).map_err(err)?{
        let e=e.map_err(err)?;let kind=e.file_type().map_err(err)?;let name=e.file_name();
        if kind.is_symlink(){return Err("Unexpected symlink in guest bundle".into());}
        if kind.is_dir() && (name=="PlugIns" || name=="Watch"){continue;}
        if kind.is_dir(){copy_tree(&e.path(),&to.join(name))?;}
        else if kind.is_file(){fs::copy(e.path(),to.join(name)).map_err(err)?;}
        else{return Err("Unexpected special file".into());}
    }
    Ok(())
}
fn macho_paths(app:&Path)->Result<Vec<PathBuf>,String> {
    let mut dirs=vec![app.to_path_buf()]; let mut files=Vec::new();
    while let Some(d)=dirs.pop() {
        for e in fs::read_dir(d).map_err(err)? {
            let e=e.map_err(err)?; let ty=e.file_type().map_err(err)?;
            if ty.is_symlink() { return Err("Unexpected symlink".into()); }
            if ty.is_dir() { dirs.push(e.path()); }
            else if ty.is_file() { let mut magic=[0;4]; if fs::File::open(e.path()).map_err(err)?.read_exact(&mut magic).is_ok() && [ [0xcf,0xfa,0xed,0xfe],[0xca,0xfe,0xba,0xbe],[0xca,0xfe,0xba,0xbf] ].contains(&magic) { files.push(e.path()); } }
        }
    } Ok(files)
}
pub fn prepare(req:&Value)->Result<Value,String> {
    let dest=guest(req)?;
    let original=dest.join("Original.app");
    let mut record=validate_app(&original)?;
    let host=Path::new(s(req,"host_path")); let host_info=info(host)?;
    let host_id=strval(&host_info,"CFBundleIdentifier");
    if host_id!="com.hongson117.icontainer" && !host_id.starts_with("com.hongson117.icontainer.") { return Err("Chỉ chuẩn bị app cho chính iContainer.".into()); }
    let p12=base64::engine::general_purpose::STANDARD.decode(s(req,"p12_base64")).map_err(err)?;
    let keys=KeyStore::from_pkcs12(&p12,s(req,"password"),Pkcs12ImportPolicy::Relaxed).map_err(|_|"Không đọc được chứng chỉ ký.")?;
    let (_,chain)=keys.private_key_chain().ok_or("Chứng chỉ không có khóa riêng.")?;
    let key=RsaPrivateKey::from_pkcs8_der(chain.key().as_der()).map_err(err)?;
    let leaf=chain.certs().first().ok_or("Thiếu chứng chỉ.")?;
    if !macho::signature_contains(&fs::read(host.join(executable(&host_info)?)).map_err(err)?,leaf.as_der())? {
        return Err("Chứng chỉ đã chọn không khớp bản iContainer đang chạy. Hãy gia hạn iContainer bằng tài khoản đó trước, mở lại app rồi chuẩn bị lại; hoặc nhập đúng .p12 đã dùng khi cài iContainer.".into());
    }
    let cert=Certificate::from_der(leaf.as_der()).map_err(err)?;
    let now=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(err)?.as_secs();
    if cert.tbs_certificate.validity.not_after.to_unix_duration().as_secs()<=now { return Err("Chứng chỉ đã hết hạn.".into()); }
    let profile=ProvisioningProfile::parse(&fs::read(host.join("embedded.mobileprovision")).map_err(err)?).map_err(err)?;
    let identity=isideload::sideload::cert_identity::CertificateIdentity {
        machine_id:String::new(), machine_name:String::new(), private_key:key.clone(), certificate:cert.clone(),
    };
    let chain=identity.profile_to_certificate_chain(&profile).map_err(|e|format!("Không dựng được chuỗi chứng chỉ: {e}"))?;
    let signer=RustCryptoCmsSigner::new(key,cert,chain);
    let staging=dest.join("Preparing.app"); let final_app=dest.join("Prepared.app"); let backup=dest.join("Previous.app");
    if !final_app.exists() && backup.exists() { fs::rename(&backup,&final_app).map_err(err)?; }
    if staging.exists() { fs::remove_dir_all(&staging).map_err(err)?; }
    let result=(|| {
        copy_main_app(&original,&staging)?;
        let exe=record["executable"].as_str().ok_or("Missing executable")?.to_string();
        let main=staging.join(&exe); let mut entry=0;
        for path in macho_paths(&staging)? {
            let (patched,offset)=macho::prepare(&fs::read(&path).map_err(err)?,path==main)?;
            if path==main { entry=offset.ok_or("Missing entry")?; }
            // Always sign a new inode; never rewrite code already mapped by a guest.
            let signed=crate::container_signing::sign_guest(&path,&patched,host_id,profile.team_id(),&signer)?;
            fs::write(&path,signed).map_err(err)?;
            #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; fs::set_permissions(&path,fs::Permissions::from_mode(0o700)).map_err(err)?; }
        }
        if entry==0 { return Err("Executable was not prepared".into()); }
        record["id"]=json!(s(req,"guest_id")); record["prepared"]=json!(true); record["preparation_revision"]=json!(3); record["entry_offset"]=json!(entry);
        record["signer"]=json!(s(req,"signer")); record["host_bundle_id"]=json!(host_id);
        record["certificate_expires"]=json!(signer.signer_certificate().tbs_certificate.validity.not_after.to_unix_duration().as_secs());
        // The loader trusts only metadata committed next to the exact signed copy.
        atomic_json(&staging.join("iContainerLaunch.json"),&record)?;
        if backup.exists() { fs::remove_dir_all(&backup).map_err(err)?; }
        if final_app.exists() { fs::rename(&final_app,&backup).map_err(err)?; }
        if let Err(e)=fs::rename(&staging,&final_app) { if backup.exists(){let _=fs::rename(&backup,&final_app);} return Err(err(e)); }
        if let Err(e)=atomic_json(&dest.join("manifest.json"),&record) {
            let _=fs::remove_dir_all(&final_app); if backup.exists(){let _=fs::rename(&backup,&final_app);} return Err(e);
        }
        let _=fs::remove_dir_all(&backup);
        Ok(json!({"ok":true,"guest":record}))
    })();
    if result.is_err(){let _=fs::remove_dir_all(staging);} result
}
pub fn remove(req:&Value)->Result<Value,String> { let p=guest(req)?; fs::remove_dir_all(p).map_err(err)?; Ok(json!({"ok":true})) }

#[cfg(test)]
mod tests {
    use super::*;
    fn temp()->PathBuf { let p=std::env::temp_dir().join(format!("ic-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos())); fs::create_dir_all(&p).unwrap();p }
    #[test] fn prevents_path_escape_and_symlink_archives() {
        for (name,link) in [("../escape",false),("Payload/A.app/../../escape",false),("C:/escape",false),("Payload/A.app/link",true)] {
            let root=temp(); let path=root.join("bad.ipa"); let mut z=zip::ZipWriter::new(fs::File::create(&path).unwrap());
            if link {z.add_symlink(name,"../../../outside",zip::write::SimpleFileOptions::default()).unwrap();}
            else {z.start_file(name,zip::write::SimpleFileOptions::default()).unwrap();z.write_all(b"bad").unwrap();}
            z.finish().unwrap(); assert!(extract(&path,&root.join("out")).is_err()); assert!(!root.join("out").exists());fs::remove_dir_all(root).unwrap();
        }
    }
    #[test] fn refuses_non_uuid_before_deleting() { for id in ["../other","", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA/"] { assert!(!valid_id(id)); } assert!(valid_id("2D3029B6-A7BB-4BD4-A2E9-1F39543A5114")); }
    #[test] fn imports_extension_watch_ipas_but_prepares_only_the_phone_application(){
        let root=temp();let ipa=root.join("with-components.ipa");
        let mut main=vec![0u8;8192];
        let set=|b:&mut[u8],at:usize,n:u32|b[at..at+4].copy_from_slice(&n.to_le_bytes());
        for (at,n) in [(0,0xfeedfacf),(4,0x0100000c),(12,2),(16,2),(20,176),(32,0x19),(36,152),(96,1),(152,4096),(184,0x80000028),(188,24)]{set(&mut main,at,n);}
        main[192..200].copy_from_slice(&4096u64.to_le_bytes());
        let mut d=plist::Dictionary::new();d.insert("CFBundleIdentifier".into(),"com.example.phone".into());d.insert("CFBundleExecutable".into(),"Phone".into());d.insert("CFBundleName".into(),"Phone".into());d.insert("CFBundleSupportedPlatforms".into(),PV::Array(vec!["iPhoneOS".into()]));
        let mut xml=Vec::new();plist::to_writer_xml(&mut xml,&d).unwrap();
        let mut zip=zip::ZipWriter::new(fs::File::create(&ipa).unwrap());
        for (path,bytes) in [("Payload/Phone.app/Info.plist",xml.as_slice()),("Payload/Phone.app/Phone",main.as_slice()),("Payload/Phone.app/PlugIns/Widget.appex/Widget",b"unsupported extension binary".as_slice()),("Payload/Phone.app/Watch/WatchApp.app/WatchExec",b"unsupported watchOS binary".as_slice())]{
            zip.start_file(path,zip::write::SimpleFileOptions::default()).unwrap();zip.write_all(bytes).unwrap();
        }zip.finish().unwrap();
        let storage=root.join("iContainer");let id="2D3029B6-A7BB-4BD4-A2E9-1F39543A5114";
        let result=import(&json!({"ipa_path":ipa,"container_root":storage,"guest_id":id})).unwrap();
        assert_eq!(result["guest"]["embedded_components"],json!(["extensions","watch"]));assert_eq!(result["guest"]["main_app_only"],true);
        let original=storage.join(id).join("Original.app");let prepared=storage.join(id).join("TestPrepared.app");copy_main_app(&original,&prepared).unwrap();
        assert!(original.join("PlugIns/Widget.appex/Widget").exists());assert!(original.join("Watch/WatchApp.app/WatchExec").exists());
        assert!(!prepared.join("PlugIns").exists());assert!(!prepared.join("Watch").exists());
        assert_eq!(fs::read(prepared.join("Phone")).unwrap(),main);assert_eq!(macho_paths(&prepared).unwrap().len(),1);
        fs::remove_dir_all(root).unwrap();
    }
}
