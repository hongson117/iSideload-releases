//! Existing certificate mode: sign with a user-supplied .p12 + .mobileprovision
//! profiles, no Apple ID sign-in. Ops: import_cert, imported_cert,
//! clear_imported_cert, and install with "use_imported_cert": true.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use apple_codesign_quick::{sign_bundle, BundleSigningSettings, ProvisioningProfile, RustCryptoCmsSigner};
use isideload::sideload::application::Application;
use isideload::sideload::cert_identity::CertificateIdentity;
use p12_keystore::{KeyStore, Pkcs12ImportPolicy};
use plist::{Dictionary, Value as PV};
use rsa::pkcs8::DecodePrivateKey;
use rsa::RsaPrivateKey;
use serde_json::{json, Value};
use x509_cert::der::{Decode, Encode};
use x509_cert::Certificate;

use crate::bridge::Ui;
use crate::ops::{bundle_info, explain, profile_expiry, s, HOST_NAME};
use crate::device;

fn dir(req: &Value) -> PathBuf {
    PathBuf::from(s(req, "storage_dir")).join("imported_cert")
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

struct Identity {
    key: RsaPrivateKey,
    cert: Certificate,
    der: Vec<u8>,
    name: String,
    team: String,
    expires: u64,
}

fn attr(name: &x509_cert::name::Name, prefix: &str) -> String {
    for rdn in name.0.iter() {
        for atv in rdn.0.iter() {
            let t = atv.to_string();
            if let Some(v) = t.strip_prefix(prefix) {
                return v.replace("\\,", ",").replace("\\ ", " ").replace("\\+", "+").replace("\\\"", "\"");
            }
        }
    }
    String::new()
}

fn load_identity(p12: &[u8], password: &str) -> Result<Identity, String> {
    let ks = KeyStore::from_pkcs12(p12, password, Pkcs12ImportPolicy::Relaxed)
        .map_err(|_| "Không mở được .p12 — sai mật khẩu hoặc file hỏng.".to_string())?;
    let (_, chain) = ks.private_key_chain().ok_or("File .p12 không chứa khoá riêng (private key).")?;
    let key = RsaPrivateKey::from_pkcs8_der(chain.key().as_der())
        .map_err(|_| "Khoá riêng trong .p12 không phải RSA hợp lệ.".to_string())?;
    let leaf = chain.certs().first().ok_or("File .p12 không chứa chứng chỉ.")?;
    let der = leaf.as_der().to_vec();
    let cert = Certificate::from_der(&der).map_err(|e| format!("Chứng chỉ hỏng: {e}"))?;
    let subj = &cert.tbs_certificate.subject;
    let name = attr(subj, "CN=");
    let mut team = attr(subj, "OU=");
    if team.is_empty() {
        team = attr(subj, "UID=");
    }
    let expires = cert.tbs_certificate.validity.not_after.to_unix_duration().as_secs();
    Ok(Identity { key, cert, der, name, team, expires })
}

struct Prof {
    file: String,
    bytes: Vec<u8>,
    parsed: ProvisioningProfile,
    name: String,
    team: String,
    app_id: String, // without TEAM. prefix
    expires: u64,
    devices: Vec<String>,
    all_devices: bool,
    platforms: Vec<String>,
    certs: Vec<Vec<u8>>,
}

fn load_profile(file: &str, bytes: Vec<u8>) -> Result<Prof, String> {
    let parsed = ProvisioningProfile::parse(&bytes).map_err(|e| format!("{file}: không đọc được profile ({e})"))?;
    let p = parsed.plist();
    let gs = |k: &str| p.get(k).and_then(PV::as_string).unwrap_or("").to_string();
    let team = parsed.team_id().to_string();
    let full = parsed.entitlements().get("application-identifier").and_then(PV::as_string).unwrap_or("").to_string();
    // Strip the App ID prefix (TeamID or a legacy AppIdentifierPrefix that may differ from the team) → "*", "com.x.*" or explicit.
    let app_id = full.strip_prefix(&format!("{team}.")).map(str::to_string).unwrap_or_else(|| match full.split_once('.') {
        Some((pre, rest)) if pre.len() == 10 && pre.chars().all(|c| c.is_ascii_alphanumeric()) => rest.to_string(),
        _ => full.clone(),
    });
    let expires = p
        .get("ExpirationDate")
        .and_then(PV::as_date)
        .and_then(|d| SystemTime::from(d).duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let strs = |k: &str| -> Vec<String> {
        p.get(k).and_then(PV::as_array).map(|a| a.iter().filter_map(|v| v.as_string().map(String::from)).collect()).unwrap_or_default()
    };
    let certs = p
        .get("DeveloperCertificates")
        .and_then(PV::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_data().map(|d| d.to_vec())).collect())
        .unwrap_or_default();
    Ok(Prof {
        file: file.to_string(),
        name: gs("Name"),
        team,
        app_id,
        expires,
        devices: strs("ProvisionedDevices"),
        all_devices: p.get("ProvisionsAllDevices").and_then(PV::as_boolean).unwrap_or(false),
        platforms: strs("Platform"),
        certs,
        bytes,
        parsed,
    })
}

fn wildcard(app_id: &str) -> bool {
    app_id.ends_with('*')
}

/// 2 = exact App ID, 1 = wildcard covering the id, 0 = no match.
fn match_score(app_id: &str, bundle: &str) -> u8 {
    if app_id == bundle {
        2
    } else if let Some(prefix) = app_id.strip_suffix('*') {
        if bundle.starts_with(prefix) { 1 } else { 0 }
    } else {
        0
    }
}

fn udid_ok(p: &Prof, udid: &str) -> bool {
    p.all_devices || p.devices.iter().any(|d| d.eq_ignore_ascii_case(udid))
}

fn profile_json(p: &Prof, id: Option<&Identity>, udid: Option<&str>) -> Value {
    json!({
        "file": p.file,
        "name": p.name,
        "team_id": p.team,
        "app_id": p.app_id,
        "wildcard": wildcard(&p.app_id),
        "expires": p.expires,
        "expired": p.expires <= now(),
        "device_count": p.devices.len(),
        "all_devices": p.all_devices,
        "platforms": p.platforms,
        "matches_cert": id.map(|i| p.certs.contains(&i.der)),
        "has_device": udid.filter(|u| !u.is_empty()).map(|u| udid_ok(p, u)),
    })
}

fn identity_json(i: &Identity) -> Value {
    json!({"name": i.name, "team_id": i.team, "expires": i.expires, "expired": i.expires <= now()})
}

fn load_stored(req: &Value) -> Result<(Identity, Vec<Prof>), String> {
    let d = dir(req);
    let p12 = std::fs::read(d.join("cert.p12")).map_err(|_| "Chưa nhập chứng chỉ có sẵn.".to_string())?;
    let pw = std::fs::read_to_string(d.join("password")).unwrap_or_default();
    let id = load_identity(&p12, &pw)?;
    let mut profs = Vec::new();
    if let Ok(rd) = std::fs::read_dir(d.join("profiles")) {
        for e in rd.flatten() {
            let f = e.file_name().to_string_lossy().to_string();
            if let Ok(b) = std::fs::read(e.path()) {
                if let Ok(p) = load_profile(&f, b) {
                    profs.push(p);
                }
            }
        }
    }
    profs.sort_by(|a, b| a.file.cmp(&b.file));
    Ok((id, profs))
}

fn summary(id: &Identity, profs: &[Prof], udid: &str) -> Value {
    let mut warnings = Vec::<String>::new();
    if id.expires <= now() {
        warnings.push("Chứng chỉ đã hết hạn.".into());
    }
    for p in profs {
        if !p.certs.contains(&id.der) {
            warnings.push(format!("Profile \"{}\" không chứa chứng chỉ này.", p.name));
        }
        if p.team != id.team && !id.team.is_empty() {
            warnings.push(format!("Profile \"{}\" thuộc team {} khác team chứng chỉ {}.", p.name, p.team, id.team));
        }
        if p.expires <= now() {
            warnings.push(format!("Profile \"{}\" đã hết hạn.", p.name));
        }
        if !udid.is_empty() && !udid_ok(p, udid) {
            warnings.push(format!("Profile \"{}\" không có UDID máy {}.", p.name, udid));
        }
        if !p.platforms.is_empty() && !p.platforms.iter().any(|x| x.eq_ignore_ascii_case("iOS")) {
            warnings.push(format!("Profile \"{}\" không dành cho iOS ({}).", p.name, p.platforms.join(", ")));
        }
    }
    if profs.is_empty() {
        warnings.push("Chưa có file .mobileprovision nào.".into());
    }
    json!({
        "ok": true,
        "imported": true,
        "certificate": identity_json(id),
        "profiles": profs.iter().map(|p| profile_json(p, Some(id), Some(udid))).collect::<Vec<_>>(),
        "warnings": warnings,
    })
}

/// import_cert {storage_dir, p12_path?, password?, profile_paths: [..], replace_profiles?: bool, udid?}
pub fn import(req: &Value) -> Result<Value, String> {
    let d = dir(req);
    let pdir = d.join("profiles");
    let p12_path = s(req, "p12_path");
    let password = s(req, "password");
    let p12 = if !p12_path.is_empty() {
        std::fs::read(p12_path).map_err(|_| "Không đọc được file .p12.".to_string())?
    } else {
        std::fs::read(d.join("cert.p12")).map_err(|_| "Hãy chọn file .p12.".to_string())?
    };
    let pw = if !p12_path.is_empty() { password.to_string() } else { std::fs::read_to_string(d.join("password")).unwrap_or_default() };
    let id = load_identity(&p12, &pw)?;

    let mut new_profiles = Vec::new();
    if let Some(arr) = req.get("profile_paths").and_then(Value::as_array) {
        for v in arr {
            let path = v.as_str().unwrap_or("");
            let bytes = std::fs::read(path).map_err(|_| format!("Không đọc được {path}"))?;
            let file = Path::new(path).file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or("profile.mobileprovision".into());
            new_profiles.push(load_profile(&file, bytes)?);
        }
    }

    std::fs::create_dir_all(&pdir).map_err(|e| e.to_string())?;
    if !p12_path.is_empty() {
        std::fs::write(d.join("cert.p12"), &p12).map_err(|e| e.to_string())?;
        std::fs::write(d.join("password"), &pw).map_err(|e| e.to_string())?;
    }
    if req.get("replace_profiles").and_then(Value::as_bool).unwrap_or(false) {
        let _ = std::fs::remove_dir_all(&pdir);
        std::fs::create_dir_all(&pdir).map_err(|e| e.to_string())?;
    }
    for p in &new_profiles {
        std::fs::write(pdir.join(&p.file), &p.bytes).map_err(|e| e.to_string())?;
    }
    let (id2, profs) = load_stored(req)?;
    let _ = id;
    Ok(summary(&id2, &profs, s(req, "udid")))
}

pub fn info(req: &Value) -> Result<Value, String> {
    if !dir(req).join("cert.p12").exists() {
        return Ok(json!({"ok": true, "imported": false}));
    }
    let (id, profs) = load_stored(req)?;
    Ok(summary(&id, &profs, s(req, "udid")))
}

/// Imported identity as a LiveContainer certificate payload.
pub fn lc_cert(req: &Value) -> Result<Value, String> {
    let d = dir(req);
    let p12 = std::fs::read(d.join("cert.p12")).map_err(|_| "Chưa nhập chứng chỉ có sẵn.".to_string())?;
    let pw = std::fs::read_to_string(d.join("password")).unwrap_or_default();
    let id = load_identity(&p12, &pw)?;
    use base64::Engine as _;
    Ok(json!({"ok": true, "p12_base64": base64::engine::general_purpose::STANDARD.encode(&p12), "password": pw, "team_id": id.team}))
}

pub fn clear(req: &Value) -> Result<Value, String> {
    let _ = std::fs::remove_dir_all(dir(req));
    Ok(json!({"ok": true, "imported": false}))
}

/// Profile entitlements made concrete for one bundle id.
fn entitlements_for(p: &Prof, bundle_id: &str) -> Dictionary {
    let mut e = p.parsed.entitlements().clone();
    if match_score(&p.app_id, bundle_id) == 0 {
        // Explicit profile for another ID: keep its entitlements verbatim (that is what installd checks).
        return e;
    }
    let prefix = e.get("application-identifier").and_then(PV::as_string).and_then(|x| x.split_once('.')).map(|x| x.0.to_string()).unwrap_or_else(|| p.team.clone());
    let full = format!("{prefix}.{bundle_id}");
    e.insert("application-identifier".into(), PV::String(full.clone()));
    if let Some(PV::Array(groups)) = e.get_mut("keychain-access-groups") {
        for g in groups.iter_mut() {
            if let PV::String(x) = g {
                if x.ends_with('*') {
                    *x = full.clone();
                }
            }
        }
    }
    e
}

fn pick<'a>(usable: &'a [&'a Prof], bundle: &str) -> Option<&'a Prof> {
    usable
        .iter()
        .copied()
        .filter(|p| match_score(&p.app_id, bundle) > 0)
        .max_by_key(|p| (match_score(&p.app_id, bundle), p.expires))
}

/// Pack a signed .app into Payload/<name>.app inside a stored-deflate IPA, keeping unix modes and symlinks.
pub(crate) fn zip_payload(app_dir: &std::path::Path, out: &std::path::Path) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    let f = std::fs::File::create(out).map_err(|e| format!("Không tạo được IPA: {e}"))?;
    let mut z = zip::ZipWriter::new(f);
    let base = app_dir.parent().unwrap_or(app_dir);
    let root = format!("Payload/{}", app_dir.file_name().unwrap().to_string_lossy());
    let mut stack = vec![app_dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let rel = d.strip_prefix(base).unwrap().to_string_lossy().to_string();
        let rel = format!("Payload/{}", rel).replace(&format!("Payload/{}", app_dir.file_name().unwrap().to_string_lossy()), &root);
        z.add_directory(format!("{rel}/"), zip::write::SimpleFileOptions::default().unix_permissions(0o755)).map_err(|e| e.to_string())?;
        for ent in std::fs::read_dir(&d).map_err(|e| e.to_string())? {
            let ent = ent.map_err(|e| e.to_string())?;
            let p = ent.path();
            let name = format!("{rel}/{}", ent.file_name().to_string_lossy());
            let md = std::fs::symlink_metadata(&p).map_err(|e| e.to_string())?;
            if md.file_type().is_symlink() {
                let t = std::fs::read_link(&p).map_err(|e| e.to_string())?;
                z.add_symlink(name, t.to_string_lossy(), zip::write::SimpleFileOptions::default()).map_err(|e| e.to_string())?;
            } else if md.is_dir() {
                stack.push(p);
            } else {
                let opts = zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Deflated)
                    .unix_permissions(md.permissions().mode() & 0o777)
                    .large_file(md.len() > 0xFFFF_0000);
                z.start_file(name, opts).map_err(|e| e.to_string())?;
                z.write_all(&std::fs::read(&p).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
            }
        }
    }
    z.finish().map_err(|e| format!("Đóng gói IPA lỗi: {e}"))?;
    Ok(())
}

pub async fn install(req: &Value, ui: Ui) -> Result<Value, String> {
    let ipa = PathBuf::from(s(req, "ipa_path"));
    if !ipa.exists() {
        return Err("The IPA file is missing.".into());
    }
    let upgrade = req.get("upgrade").and_then(Value::as_bool).unwrap_or(false);
    let port = req.get("port").and_then(Value::as_u64).unwrap_or(0) as u16;
    let (id, profs) = load_stored(req)?;
    if req.get("self_refresh").and_then(Value::as_bool).unwrap_or(false) {
        let expected=crate::self_refresh::installed_team(&ipa)?;
        if !id.team.eq_ignore_ascii_case(&expected) {
            return Err(format!("Chứng chỉ đã nhập thuộc Team {}, khác Team {} đang ký iContainer. Gia hạn bản hiện tại cần giữ Team đã cài.",id.team,expected));
        }
    }
    if id.expires <= now() {
        return Err("Chứng chỉ có sẵn đã hết hạn.".into());
    }

    // OTA mode (KSign-like): no VPN/device connection; sign, pack an IPA and let the app serve it via itms-services.
    let ota = req.get("ota").and_then(Value::as_bool).unwrap_or(false);
    let rp = device::is_rp_pairing(s(req, "pairing_path"));
    if !ota { ui.progress("Đang kết nối thiết bị qua VPN…", None); }
    let (provider, mut tunnel, tv_name, udid) = if ota {
        (None, None, "iPhone".to_string(), s(req, "udid").to_string())
    } else if rp {
        let (a, hs) = device::rp_tunnel(s(req, "target"), s(req, "pairing_path")).await?;
        let udid = device::rsd_prop(&hs, "UniqueDeviceID");
        if udid.is_empty() { return Err("Thiết bị không trả về UDID qua RSD.".into()); }
        (None, Some((a, hs)), "iPhone".to_string(), udid)
    } else {
        let p = device::provider(s(req, "target"), s(req, "pairing_path"))?;
        let (n, u, _ios) = device::info(&p).await?;
        (Some(p), None, n, u)
    };

    ui.progress("Kiểm tra chứng chỉ & profile…", None);
    let usable: Vec<&Prof> = profs
        .iter()
        .filter(|p| p.certs.contains(&id.der) && p.expires > now() && (udid.is_empty() || udid_ok(p, &udid)))
        .collect();
    if usable.is_empty() {
        let why = summary(&id, &profs, &udid)["warnings"].clone();
        return Err(format!(
            "Không có profile dùng được cho máy này (UDID {udid}). {}",
            why.as_array().map(|a| a.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join(" ")).unwrap_or_default()
        ));
    }

    let mut app = Application::new(ipa).map_err(|e| explain("IPA không hợp lệ", &e))?;
    let original = app.main_bundle_id().map_err(|e| explain("IPA không có bundle ID", &e))?;
    let mut notes = Vec::<String>::new();

    // KSign/ESign behaviour: never touch CFBundleIdentifier. installd validates the *entitlements* against the
    // profile, not Info.plist, so every app keeps its own bundle ID and they all coexist — even with a
    // single explicit App ID profile. Matching profile (exact > wildcard) wins; otherwise the newest usable one.
    let best = |id: &str| pick(&usable, id).or_else(|| usable.iter().copied().max_by_key(|p| (wildcard(&p.app_id), p.expires)));
    let main_id = original.clone();
    let main_prof = best(&main_id).ok_or("Không chọn được profile cho app chính.")?;
    if match_score(&main_prof.app_id, &main_id) == 0 {
        notes.push(format!("Giữ bundle ID {original}; ký bằng profile {} (App ID {}).", main_prof.name, main_prof.app_id));
    }
    let mut ext_settings: Vec<(String, &Prof)> = Vec::new();
    for ext in app.bundle.app_extensions() {
        let eid = ext.bundle_identifier().unwrap_or("").to_string();
        if let Some(p) = best(&eid) { ext_settings.push((eid, p)); }
    }
    let drop_dirs: Vec<PathBuf> = Vec::new();
    app.bundle.write_info().map_err(|e| explain("Ghi Info.plist lỗi", &e))?;
    for ext in app.bundle.app_extensions_mut() {
        ext.write_info().map_err(|e| explain("Ghi Info.plist lỗi", &e))?;
    }
    for ext in app.bundle.frameworks_mut() {
        let _ = ext.write_info();
    }
    for d in &drop_dirs {
        let _ = std::fs::remove_dir_all(d);
    }

    ui.progress("Signing…", Some(0.3));
    let ident = CertificateIdentity {
        machine_id: String::new(),
        machine_name: String::new(),
        private_key: id.key.clone(),
        certificate: id.cert.clone(),
    };
    let chain = ident.profile_to_certificate_chain(&main_prof.parsed).unwrap_or_default();
    let signer = RustCryptoCmsSigner::new(id.key.clone(), id.cert.clone(), chain);
    let mut settings = BundleSigningSettings::new(main_prof.team.clone(), entitlements_for(main_prof, &main_id), Some(&signer));
    settings.embedded_mobileprovision = Some(main_prof.bytes.as_ref());
    for (eid, p) in &ext_settings {
        settings.entitlements_by_bundle_id.insert(eid.clone(), entitlements_for(p, eid));
        settings.embedded_mobileprovisions_by_bundle_id.insert(eid.clone(), p.bytes.as_ref());
    }
    let signed = app.bundle.bundle_dir.clone();
    sign_bundle(&signed, &settings).map_err(|e| format!("Signing failed: {e}"))?;
    let _ = id.cert.to_der();

    let (bundle_id, name, version) = bundle_info(&signed);
    let expires = profile_expiry(&signed).map(|e| e.min(id.expires));
    if ota {
        let out = PathBuf::from(s(req, "ipa_out"));
        ui.progress("Đang đóng gói IPA…", Some(0.8));
        zip_payload(&signed, &out)?;
        let _ = std::fs::remove_dir_all(&signed);
        return Ok(json!({
            "ok": true, "ota": true, "ipa_out": out.to_string_lossy(),
            "bundle_id": bundle_id, "original_bundle_id": original, "name": name, "version": version,
            "team_id": main_prof.team, "expires": expires, "udid": udid, "device_name": tv_name,
            "imported_cert": true, "profile": main_prof.name, "notes": notes,
        }));
    }
    let label = if upgrade { "Đang làm mới app…" } else { "Đang cài app…" };
    ui.progress(label, Some(0.0));
    let cb = move |p: u64| ui.progress(label, Some((p as f64 / 100.0).clamp(0.0, 1.0)));
    if let Some((adapter, hs)) = tunnel.as_mut() {
        isideload::sideload::install::install_app_rsd_mode(adapter, hs, &signed, upgrade, cb).await.map_err(|e| explain("Install failed", &e))?;
    } else if let Some(p) = provider.as_ref() {
        isideload::sideload::install::install_app(p, &signed, cb).await.map_err(|e| explain("Install failed", &e))?;
    }
    let _ = std::fs::remove_dir_all(&signed);

    Ok(json!({
        "ok": true,
        "lc_cert": if bundle_id.starts_with("com.kdt.livecontainer") { lc_cert(req).ok() } else { None },
        "bundle_id": bundle_id,
        "original_bundle_id": original,
        "name": name,
        "version": version,
        "team_id": main_prof.team,
        "expires": expires,
        "udid": udid,
        "device_name": tv_name,
        "imported_cert": true,
        "profile": main_prof.name,
        "notes": notes,
    }))
}

#[cfg(test)]
mod tests {
    use super::match_score;
    #[test]
    fn scores() {
        assert_eq!(match_score("com.a.b", "com.a.b"), 2);
        assert_eq!(match_score("*", "com.a.b"), 1);
        assert_eq!(match_score("com.a.*", "com.a.b"), 1);
        assert_eq!(match_score("*", "com.any.app"), 1);
        assert_eq!(match_score("com.x.*", "com.a.b"), 0);
    }
}
