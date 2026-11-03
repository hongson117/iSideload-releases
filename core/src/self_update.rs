//! Prepare trusted update code for the exact installed owner identity.
use std::{path::Path,fs};
use serde_json::{Value,json};
use isideload::sideload::application::Application;
use crate::ops::s;

pub fn prepare(req:&Value)->Result<Value,String>{
    let input=Path::new(s(req,"ipa_path"));let host=Path::new(s(req,"host_path"));let out=Path::new(s(req,"out_path"));
    let (installed,_,_)=crate::ops::bundle_info(host);
    let family=crate::owner_setup::family(&installed).ok_or("Không xác định được ứng dụng đang cập nhật.")?;
    if installed!=s(req,"installed_bundle_id"){return Err("Bản cập nhật không khớp ứng dụng đang chạy.".into());}
    let expected=s(req,"sha256");
    if expected.len()!=64 || !expected.bytes().all(|b|b.is_ascii_hexdigit()) || crate::owner_setup::hash(&fs::read(input).map_err(|e|e.to_string())?)!=expected.to_ascii_lowercase(){
        return Err("Checksum bản cập nhật không khớp. Chưa ký hoặc cài file này.".into());
    }
    let original=crate::ops::inspect_ipa(input)?;
    if crate::owner_setup::family(original["bundle_id"].as_str().unwrap_or(""))!=Some(family){return Err("File cập nhật thuộc sản phẩm khác.".into());}
    let mut app=Application::new(input.to_path_buf()).map_err(|e|format!("Không mở được bản cập nhật: {e}"))?;
    for (field,key) in [("CFBundleShortVersionString","version"),("CFBundleVersion","build")] {
        if app.bundle.app_info.get(field).and_then(plist::Value::as_string)!=Some(s(req,key)) {
            let _=fs::remove_dir_all(&app.bundle.bundle_dir);
            return Err("Phiên bản trong IPA không khớp thông báo cập nhật.".into());
        }
    }
    let original_id=app.main_bundle_id().map_err(|e|e.to_string())?;
    app.update_bundle_id(&original_id,&installed).map_err(|e|e.to_string())?;
    // Preserve the current owner's team as metadata for the subsequent guarded
    // signing step. The signer replaces this with a fresh provisioning profile.
    fs::copy(host.join("embedded.mobileprovision"),app.bundle.bundle_dir.join("embedded.mobileprovision")).map_err(|_|"Không đọc được profile của bản đang cài.")?;
    let mut old_info:plist::Dictionary=plist::from_file(host.join("Info.plist")).map_err(|e|e.to_string())?;
    if let Some(name)=old_info.remove("CFBundleDisplayName"){app.bundle.app_info.insert("CFBundleDisplayName".into(),name);}
    app.bundle.write_info().map_err(|e|e.to_string())?;
    for bundle in app.bundle.app_extensions_mut(){bundle.write_info().map_err(|e|e.to_string())?;}
    for bundle in app.bundle.frameworks_mut(){bundle.write_info().map_err(|e|e.to_string())?;}
    let result=crate::imported::zip_payload(&app.bundle.bundle_dir,out);
    let _=fs::remove_dir_all(&app.bundle.bundle_dir);result?;
    Ok(json!({"ok":true,"ipa_path":out.to_string_lossy(),"bundle_id":installed,"version":original["version"]}))
}

#[cfg(test)]mod tests {
    use super::*;
    #[test]fn update_keeps_owner_identity_profile_and_display_name_and_rejects_tampering(){
        for family in ["com.hongson117.icontainer","com.hongson117.isideload"] {
            let root=std::env::temp_dir().join(format!("update-{}-{}",std::process::id(),family));
            let _=fs::remove_dir_all(&root);
            let host=root.join("Owner.app");let source=root.join("Source.app");
            fs::create_dir_all(&host).unwrap();fs::create_dir_all(&source).unwrap();
            let owner=format!("{family}.OWNER12345");
            let mut info=plist::Dictionary::new();
            for (key,value) in [("CFBundleIdentifier",family),("CFBundleName","Helper"),("CFBundleShortVersionString","2.0.0"),("CFBundleVersion","25")] {info.insert(key.into(),value.into());}
            plist::to_file_xml(source.join("Info.plist"),&info).unwrap();
            info.insert("CFBundleIdentifier".into(),owner.clone().into());info.insert("CFBundleDisplayName".into(),"Bản Cá nhân".into());
            plist::to_file_xml(host.join("Info.plist"),&info).unwrap();
            fs::write(host.join("embedded.mobileprovision"),b"owner profile metadata").unwrap();
            let input=root.join("download.ipa");let out=root.join("prepared.ipa");
            crate::imported::zip_payload(&source,&input).unwrap();
            let mut req=json!({"ipa_path":input,"host_path":host,"out_path":out,"installed_bundle_id":owner,"sha256":crate::owner_setup::hash(&fs::read(&input).unwrap()),"version":"2.0.0","build":"25"});
            prepare(&req).unwrap();
            let prepared=Application::new(out.clone()).unwrap();
            assert_eq!(prepared.main_bundle_id().unwrap(),owner);
            assert_eq!(prepared.bundle.app_info["CFBundleDisplayName"].as_string(),Some("Bản Cá nhân"));
            assert_eq!(fs::read(prepared.bundle.bundle_dir.join("embedded.mobileprovision")).unwrap(),b"owner profile metadata");
            let _=fs::remove_dir_all(&prepared.bundle.bundle_dir);
            fs::remove_file(&out).unwrap();
            req["sha256"]=json!("0".repeat(64));assert!(prepare(&req).unwrap_err().contains("Checksum"));assert!(!out.exists());
            req["sha256"]=json!(crate::owner_setup::hash(&fs::read(&input).unwrap()));
            req["build"]=json!("26");assert!(prepare(&req).is_err());assert!(!out.exists());
            req["installed_bundle_id"]=json!("com.other.app");assert!(prepare(&req).is_err());
            fs::remove_dir_all(&root).unwrap();
        }
    }
}
