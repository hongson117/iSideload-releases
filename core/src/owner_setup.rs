//! First-use personal installation. A different account receives its own app
//! identity; it must never try to claim the installer's existing App ID.
use std::{path::Path, fs};
use serde_json::{json,Value};
use isideload::dev::teams::DeveloperTeam;
use crate::ops::s;
pub fn family(id:&str)->Option<&'static str>{
    ["com.hongson117.sicontainer.runner1","com.hongson117.sicontainer.runner2","com.hongson117.sicontainer","com.hongson117.icontainer","com.hongson117.isideload"].into_iter().find(|base|id==*base || id.starts_with(&format!("{base}.")))
}
pub fn own_id(id:&str)->bool {family(id).is_some()}
pub fn hash(data:&[u8])->String {ring::digest::digest(&ring::digest::SHA256,data).as_ref().iter().map(|b|format!("{b:02x}")).collect()}
pub fn request(req:&Value)->Result<Value,String> {
    let expected=family(s(req,"source_bundle_id")).ok_or("Chỉ thiết lập tài khoản cho chính ứng dụng hỗ trợ.")?;
    if crate::ops::inspect_ipa(Path::new(s(req,"ipa_path")))?["bundle_id"].as_str()!=Some(expected) {
        return Err("Bản thiết lập chưa bỏ danh tính của tài khoản cài ban đầu.".into());
    }
    if s(req,"ipa_out").is_empty(){return Err("Thiếu nơi lưu bản cài cá nhân.".into());}
    let mut r=req.clone();r["owner_setup"]=json!(true);r["sign_only"]=json!(true);
    r["self_refresh"]=json!(false);r["use_imported_cert"]=json!(false);
    r["owner_source_team"]=json!(crate::self_refresh::installed_team(Path::new(s(req,"ipa_path")))?);
    Ok(r)
}
pub fn choose_team(teams:&[DeveloperTeam],current:&str)->Result<DeveloperTeam,String>{
    teams.iter().find(|t|t.team_id.eq_ignore_ascii_case(current)).or_else(||teams.first()).cloned().ok_or("Apple ID chưa có Team phát triển.".into())
}
pub fn write_result(req:&Value,app:&Path,team:&str,udid:&str)->Result<Value,String>{
    let out=Path::new(s(req,"ipa_out"));
    crate::imported::zip_payload(app,out)?;
    let (id,name,version)=crate::ops::bundle_info(app);
    if family(&id)!=family(s(req,"source_bundle_id")){return Err("Danh tính bản cài cá nhân không hợp lệ.".into());}
    let data=fs::read(out).map_err(|e|e.to_string())?;
    Ok(json!({"ok":true,"prepared":true,"bundle_id":id,"name":name,"version":version,
        "source_bundle_id":s(req,"source_bundle_id"),"source_team_id":s(req,"owner_source_team"),
        "team_id":team,"apple_id":s(req,"apple_id"),"udid":udid,
        "ipa_path":out.to_string_lossy(),"ipa_relative_path":s(req,"ipa_relative_path"),
        "sha256":hash(&data),"same_identity":id==s(req,"source_bundle_id")}))
}
#[cfg(test)]mod tests{
    use super::*;
    fn team(id:&str)->DeveloperTeam {DeveloperTeam{name:None,team_id:id.into(),r#type:None,status:None}}
    #[test]fn a_new_owner_gets_their_team_instead_of_the_installers_team(){
        assert_eq!(choose_team(&[team("NEWTEAM123")],"A5CFR7SJU8").unwrap().team_id,"NEWTEAM123");
        assert_eq!(choose_team(&[team("NEWTEAM123"),team("A5CFR7SJU8")],"A5CFR7SJU8").unwrap().team_id,"A5CFR7SJU8");
    }
    #[test]fn setup_is_not_allowed_for_an_unrelated_application(){assert!(!own_id("com.example.other"));assert!(!own_id("com.hongson117.icontainerFake"));assert!(own_id("com.hongson117.icontainer.A5CFR7SJU8"));}
}
