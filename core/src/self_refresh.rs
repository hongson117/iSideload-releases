//! A refresh must use a team entitled to the installed app. Never silently
//! pick the first team or register the installed identifier in another team.
use std::{io::Read, path::Path};
use isideload::dev::teams::DeveloperTeam;

pub fn installed_team(ipa: &Path) -> Result<String, String> {
    let mut archive=zip::ZipArchive::new(std::fs::File::open(ipa).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    let profiles:Vec<_>=archive.file_names().filter(|name| {
        let p:Vec<_>=name.split('/').collect();
        p.len()==3 && p[0]=="Payload" && p[1].ends_with(".app") && p[2]=="embedded.mobileprovision"
    }).map(str::to_string).collect();
    if profiles.len()!=1 { return Err("Không đọc được Team ký bản iContainer đang chạy. Hãy kiểm tra lại bản cài trước khi gia hạn.".into()); }
    let profile=archive.by_name(&profiles[0]).map_err(|e|e.to_string())?;
    if profile.size()>2*1024*1024 { return Err("Provisioning profile vượt giới hạn.".into()); }
    let mut bytes=Vec::new();profile.take(2*1024*1024+1).read_to_end(&mut bytes).map_err(|e|e.to_string())?;
    let profile=apple_codesign_quick::ProvisioningProfile::parse(&bytes).map_err(|_|"Không đọc được Team ký của provisioning profile.")?;
    let id=profile.team_id();
    if id.len()!=10 || !id.bytes().all(|c|c.is_ascii_alphanumeric()) { return Err("Team ký của bản đang cài không hợp lệ.".into()); }
    Ok(id.to_string())
}

pub fn select_team(teams:&[DeveloperTeam], expected:&str, account:&str)->Result<DeveloperTeam,String> {
    teams.iter().find(|t|t.team_id.eq_ignore_ascii_case(expected)).cloned().ok_or_else(||format!(
        "Apple ID {account} không thuộc Team {expected} đang ký iContainer. Hãy chọn tài khoản đã cài bản này để gia hạn. Tài khoản khác vẫn dùng được để ký app độc lập hoặc cài cho máy khác; chuyển chính iContainer sang tài khoản khác cần đổi danh tính App ID."
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn team(id:&str)->DeveloperTeam {DeveloperTeam{name:None,team_id:id.into(),r#type:None,status:None}}
    #[test]fn selects_installed_team_even_when_it_is_not_first(){
        let teams=vec![team("OTHER12345"),team("A5CFR7SJU8")];
        assert_eq!(select_team(&teams,"A5CFR7SJU8","owner@example.com").unwrap().team_id,"A5CFR7SJU8");
    }
    #[test]fn different_account_is_rejected_instead_of_falling_back(){
        let e=select_team(&[team("OTHER12345")],"A5CFR7SJU8","other@example.com").unwrap_err();
        assert!(e.contains("không thuộc Team A5CFR7SJU8"));
        assert!(select_team(&[],"A5CFR7SJU8","a").is_err());
    }
}
