//! Requests: sign_in, device, apps, install (also refresh), certs, revoke_cert, inspect.

use std::path::PathBuf;

use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::certificates::{CertificatesApi, DevelopmentCertificate};
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::device_type::DeveloperDeviceType;
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::TeamsApi;
use isideload::sideload::builder::{MaxCertsBehavior, SideloaderBuilder};
use isideload::util::callbacks::MaxCertsCallbackFuture;
use isideload::util::fs_storage::FsStorage;
use rootcause::Report;
use serde_json::{json, Value};

use crate::bridge::Ui;
use crate::device;

/// Tried in order. ani.sidestore.io currently gets -80045 from Apple at GSA init;
/// jkcoxson (as used by AltLoad) is accepted.
const DEFAULT_ANISETTE: &[&str] = &[
    "https://ani.jkcoxson.com",
    "https://mac-ani.jkcoxson.com",
    "https://ani.npeg.us",
    "https://ani.sidestore.io",
];
const HOST_NAME: &str = "iSideload";

fn s<'a>(req: &'a Value, key: &str) -> &'a str {
    req.get(key).and_then(Value::as_str).unwrap_or("")
}

fn fail(msg: impl Into<String>) -> Value {
    let msg = msg.into();
    json!({"ok": false, "error": msg, "hint": hint_vi(&msg)})
}

/// A plain Vietnamese explanation for well-known failures (full chain stays in "error").
pub fn hint_vi(m: &str) -> String {
    let l = m.to_lowercase();
    let h = if l.contains("-22406") {
        "Sai Apple ID hoặc mật khẩu."
    } else if l.contains("-80045") || l.contains("anisette") || l.contains("-45025") {
        "Máy chủ anisette bị Apple từ chối hoặc không phản hồi. Đổi Anisette URL trong Cài đặt (để trống = tự chọn)."
    } else if l.contains("maximum number of apps") || l.contains("3 active") || l.contains("app limit") {
        "Apple ID miễn phí chỉ cài tối đa 3 app cùng lúc (tính cả iSideload). Gỡ bớt một app đã sideload rồi thử lại."
    } else if l.contains("app id") && (l.contains("limit") || l.contains("maximum") || l.contains("10")) {
        "Apple ID miễn phí chỉ tạo được 10 App ID mỗi 7 ngày. Đợi hết hạn hoặc dùng lại app đã cài (Làm mới)."
    } else if l.contains("certificate") && (l.contains("maximum") || l.contains("too many")) {
        "Đã đủ số chứng chỉ phát triển. Thu hồi chứng chỉ cũ trong Cài đặt → Chứng chỉ."
    } else if l.contains("10.7.0.1") || l.contains("lockdownd") || l.contains("vpn") {
        "Không thấy chính thiết bị qua VPN. Mở LocalDevVPN, bật VPN, rồi quay lại iSideload."
    } else if l.contains("pairing") || l.contains("ghép nối") {
        "File ghép nối không hợp lệ. Tạo lại bằng máy tính (idevice_pair / iloader / SideStore pairing) và nhập lại."
    } else if l.contains("applicationverificationfailed") || l.contains("0xe8008015") || l.contains("0xe800801c") {
        "iOS từ chối chữ ký. Bật Chế độ nhà phát triển (Cài đặt → Quyền riêng tư & Bảo mật) và thử lại."
    } else {
        ""
    };
    h.to_string()
}

/// Turns a rootcause report into one readable line.
fn explain(context: &str, e: &Report) -> String {
    let text = format!("{e}");
    // Drop source-location lines (e.g. "vendor/…/x.rs:206") and tree glyphs so the
    // real root cause (GrandSlam code, anisette error, …) reaches the UI.
    let first = text
        .lines()
        .map(|l| l.trim().trim_start_matches(|c: char| "│├└─●| ".contains(c)).trim())
        .filter(|l| !l.is_empty() && !(l.contains(".rs:") && !l.contains(' ')))
        .filter(|l| !l.starts_with("at ") && !l.contains("src/") )
        .take(6)
        .collect::<Vec<_>>()
        .join(" — ");
    format!("{context}: {first}")
}

pub async fn dispatch(req: Value, ui: Ui) -> Value {
    let result = match s(&req, "op") {
        "sign_in" => sign_in_only(&req, ui).await,
        "device" => device_info(&req).await,
        "apps" => apps(&req).await,
        "install" => install(&req, ui).await,
        "certs" => certs(&req, ui).await,
        "revoke_cert" => revoke(&req, ui).await,
        "inspect" => inspect(&req),
        "version" => Ok(json!({"ok": true, "version": env!("CARGO_PKG_VERSION")})),
        other => Err(format!("Unknown op '{other}'.")),
    };
    result.unwrap_or_else(fail)
}

async fn device_info(req: &Value) -> Result<Value, String> {
    let p = device::provider(s(req, "target"), s(req, "pairing_path"))?;
    let (name, udid, ios) = device::info(&p).await?;
    Ok(json!({"ok": true, "name": name, "udid": udid, "ios": ios}))
}

async fn apps(req: &Value) -> Result<Value, String> {
    let p = device::provider(s(req, "target"), s(req, "pairing_path"))?;
    Ok(json!({"ok": true, "apps": device::sideloaded_apps(&p).await?}))
}

async fn sign_in_only(req: &Value, ui: Ui) -> Result<Value, String> {
    let (_a, mut dev) = sign_in(req, ui).await?;
    let team = dev.list_teams().await.map_err(|e| explain("No developer team", &e))?
        .into_iter().next().ok_or("This Apple ID has no developer team.")?;
    Ok(json!({"ok": true, "team": team.team_id, "team_name": team.name}))
}

// ---- Apple ID ----

async fn sign_in_with(req: &Value, ui: Ui, email: &str, password: &str, url: &str) -> Result<AppleAccount, String> {
    // Each anisette server provisions its own identity, so each gets its own folder.
    let dir = PathBuf::from(s(req, "storage_dir")).join("anisette").join(host_of(url));
    let _ = std::fs::create_dir_all(&dir);
    let provider = RemoteV3AnisetteProvider::new(url, Box::new(FsStorage::new(dir)), "0".to_string())
        .map_err(|e| explain("Anisette setup failed", &e))?;
    let two_factor = move |params: TwoFactorCallbackParams| async move {
        let question = json!({
            "kind": "2fa",
            "sms": params.sms,
            "last_error": params.last_error,
        });
        Ok::<_, Report>(match ui.ask(question).await {
            Some(code) if code == "sms" => TwoFactorCallbackResponse::SendSms(
                params.selected_number_id.or(params.numbers.first().map(|n| n.id)).unwrap_or(1),
            ),
            Some(code) if code == "resend" => TwoFactorCallbackResponse::ResendCode,
            Some(code) if !code.is_empty() => TwoFactorCallbackResponse::SubmitCode(code),
            _ => TwoFactorCallbackResponse::Abort,
        })
    };
    AppleAccount::builder(email)
        .anisette_provider(provider)
        .login(password, two_factor)
        .await
        .map_err(|e| explain("Apple ID sign-in failed", &e))
}

/// Anisette/Apple-rejected-anisette errors where another server may work (from AltLoad).
fn is_anisette_failure(message: &str) -> bool {
    let m = message.to_lowercase();
    let user_side = ["-22406", "incorrect", "password", "2fa", "two-factor", "verification code", "cancel", "abort", "locked", "disabled"];
    if user_side.iter().any(|s| m.contains(s)) && !m.contains("anisette") {
        return false;
    }
    [
        "anisette", "provision", "client info", "client_info", "-45061", "-45054", "-80045",
        "-22410", "-22411", "websocket", "error sending request", "timed out", "connection",
        "dns", "certificate verify", "status code 5", "502", "503", "504",
    ]
    .iter()
    .any(|s| m.contains(s))
}

fn host_of(url: &str) -> String {
    url.trim()
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .split('/')
        .next()
        .unwrap_or("anisette")
        .replace(':', "_")
}

fn storage(req: &Value) -> FsStorage {
    FsStorage::new(PathBuf::from(s(req, "storage_dir")))
}

async fn sign_in(req: &Value, ui: Ui) -> Result<(AppleAccount, DeveloperSession), String> {
    let email = s(req, "apple_id").to_string();
    let password = s(req, "password").to_string();
    if email.is_empty() || password.is_empty() {
        return Err("Sign in with your Apple ID first.".into());
    }
    let custom = s(req, "anisette_url").trim();
    let mut urls: Vec<&str> = Vec::new();
    if !custom.is_empty() {
        urls.push(custom);
    }
    urls.extend(DEFAULT_ANISETTE.iter().copied().filter(|u| *u != custom));
    ui.progress("Signing in to Apple…", None);
    let mut last = String::new();
    let mut account = None;
    for (i, url) in urls.iter().enumerate() {
        match sign_in_with(req, ui, &email, &password, url).await {
            Ok(a) => {
                account = Some(a);
                break;
            }
            Err(e) => {
                let retry = is_anisette_failure(&e) && i + 1 < urls.len();
                last = format!("{e} [anisette: {url}]");
                if !retry {
                    break;
                }
            }
        }
    }
    let mut account = account.ok_or(last)?;
    let session = DeveloperSession::from_account(&mut account)
        .await
        .map_err(|e| explain("Developer sign-in failed", &e))?;
    Ok((account, session))
}

fn cert_json(c: &DevelopmentCertificate) -> Value {
    json!({
        "name": c.name,
        "serial": c.serial_number,
        "machine": c.machine_name,
        "expires": c.expiration_date.map(|d| std::time::SystemTime::from(d)
            .duration_since(std::time::UNIX_EPOCH).map(|x| x.as_secs()).unwrap_or(0)),
    })
}

// ---- Certificates ----

async fn certs(req: &Value, ui: Ui) -> Result<Value, String> {
    let (_a, mut dev) = sign_in(req, ui).await?;
    let team = dev.list_teams().await.map_err(|e| explain("No developer team", &e))?
        .into_iter().next().ok_or("This Apple ID has no developer team.")?;
    let list = dev.list_ios_certs(&team).await.map_err(|e| explain("Couldn't list certificates", &e))?;
    Ok(json!({"ok": true, "team": team.team_id, "certs": list.iter().map(cert_json).collect::<Vec<_>>()}))
}

async fn revoke(req: &Value, ui: Ui) -> Result<Value, String> {
    let (_a, mut dev) = sign_in(req, ui).await?;
    let team = dev.list_teams().await.map_err(|e| explain("No developer team", &e))?
        .into_iter().next().ok_or("This Apple ID has no developer team.")?;
    dev.revoke_development_cert(&team, s(req, "serial"), DeveloperDeviceType::Ios)
        .await
        .map_err(|e| explain("Revoke failed", &e))?;
    Ok(json!({"ok": true}))
}

// ---- Install / refresh ----

/// Reads ExpirationDate from the signed bundle's embedded.mobileprovision.
fn profile_expiry(app: &std::path::Path) -> Option<u64> {
    let bytes = std::fs::read(app.join("embedded.mobileprovision")).ok()?;
    let start = bytes.windows(6).position(|w| w == b"<?xml ")?;
    let end = bytes.windows(8).rposition(|w| w == b"</plist>")? + 8;
    let dict: plist::Dictionary = plist::from_bytes(&bytes[start..end]).ok()?;
    let date = dict.get("ExpirationDate")?.as_date()?;
    std::time::SystemTime::from(date).duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_secs())
}

fn bundle_info(app: &std::path::Path) -> (String, String, String) {
    let dict: Option<plist::Dictionary> = plist::from_file(app.join("Info.plist")).ok();
    let get = |k: &str| dict.as_ref().and_then(|d| d.get(k)).and_then(|v| v.as_string()).unwrap_or("").to_string();
    let name = [get("CFBundleDisplayName"), get("CFBundleName")].into_iter().find(|x| !x.is_empty()).unwrap_or_default();
    (get("CFBundleIdentifier"), name, get("CFBundleShortVersionString"))
}

async fn install(req: &Value, ui: Ui) -> Result<Value, String> {
    let ipa = PathBuf::from(s(req, "ipa_path"));
    if !ipa.exists() {
        return Err("The IPA file is missing.".into());
    }
    let upgrade = req.get("upgrade").and_then(Value::as_bool).unwrap_or(false);

    // 1. Reach this device through the loopback VPN first.
    let provider = device::provider(s(req, "target"), s(req, "pairing_path"))?;
    ui.progress("Đang kết nối thiết bị qua VPN…", None);
    let (dev_name, udid, _ios) = device::info(&provider).await?;

    // 2. Apple ID + developer session; certificate is reused from storage when valid.
    let (_account, dev) = sign_in(req, ui).await?;
    let revoke_prompt = move |certs: Vec<DevelopmentCertificate>| -> MaxCertsCallbackFuture {
        Box::pin(async move {
            let q = json!({"kind": "revoke", "certs": certs.iter().map(cert_json).collect::<Vec<_>>()});
            match ui.ask(q).await {
                Some(a) if !a.is_empty() => Ok(Some(a.split(',').map(|x| x.trim().to_string()).collect())),
                _ => Ok(None),
            }
        })
    };
    let mut sideloader = SideloaderBuilder::new(dev, s(req, "apple_id").to_string())
        .storage(Box::new(storage(req)))
        .machine_name(HOST_NAME.to_string())
        .max_certs_behavior(MaxCertsBehavior::Prompt(revoke_prompt))
        .build();
    sideloader.set_device_type(Some(DeveloperDeviceType::Ios));

    // 3. Register this iPhone/iPad as a development device.
    ui.progress("Đang đăng ký thiết bị…", None);
    let team = sideloader.get_team().await.map_err(|e| explain("No developer team", &e))?;
    sideloader
        .get_dev_session()
        .ensure_device_registered(&team, &dev_name, &udid, Some(DeveloperDeviceType::Ios))
        .await
        .map_err(|e| explain("Couldn't register this device", &e))?;

    // 4. Fresh profile + signature.
    ui.progress("Đang ký app…", Some(0.0));
    let progress = move |f: f32| async move { ui.progress("Đang ký app…", Some(f as f64)) };
    let (signed, _) = sideloader
        .sign_app(ipa, Some(team), false, Some(progress), None, Some(&udid))
        .await
        .map_err(|e| explain("Signing failed", &e))?;
    let (bundle_id, name, version) = bundle_info(&signed);
    let expires = profile_expiry(&signed);

    // 5. Upload (AFC) + install (installation_proxy) on this same device.
    let label = if upgrade { "Đang làm mới app…" } else { "Đang cài app…" };
    ui.progress(label, Some(0.0));
    isideload::sideload::install::install_app(&provider, &signed, move |p| {
        ui.progress(label, Some((p as f64 / 100.0).clamp(0.0, 1.0)))
    })
    .await
    .map_err(|e| explain("Install failed", &e))?;
    let _ = std::fs::remove_dir_all(&signed);

    Ok(json!({
        "ok": true,
        "bundle_id": bundle_id,
        "name": name,
        "version": version,
        "team_id": team_id_of(&bundle_id),
        "expires": expires,
        "udid": udid,
        "device_name": dev_name,
    }))
}

fn team_id_of(bundle_id: &str) -> String {
    bundle_id.rsplit('.').next().unwrap_or("").to_string()
}

// ---- IPA inspection ----

/// Reads Payload/*.app/Info.plist from an IPA (iSideload refuses tvOS-only IPAs).
pub fn inspect_ipa(path: &std::path::Path) -> Result<Value, String> {
    use std::io::Read;
    let file = std::fs::File::open(path).map_err(|e| format!("Can't open the IPA: {e}"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|_| "This file isn't a valid IPA (zip).".to_string())?;
    let name = (0..zip.len())
        .filter_map(|i| zip.by_index(i).ok().map(|f| f.name().to_string()))
        .find(|n| {
            let parts: Vec<&str> = n.split('/').collect();
            parts.len() == 3 && parts[0] == "Payload" && parts[1].ends_with(".app") && parts[2] == "Info.plist"
        })
        .ok_or("No Payload/*.app/Info.plist in this IPA.")?;
    let mut data = Vec::new();
    zip.by_name(&name).map_err(|e| e.to_string())?.read_to_end(&mut data).map_err(|e| e.to_string())?;
    let dict: plist::Dictionary = plist::from_bytes(&data).map_err(|e| format!("Info.plist is unreadable: {e}"))?;
    let get = |k: &str| dict.get(k).and_then(|v| v.as_string()).unwrap_or("").to_string();
    let families: Vec<u64> = dict
        .get("UIDeviceFamily")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_unsigned_integer()).collect())
        .unwrap_or_default();
    let platform = get("DTPlatformName");
    let supported: Vec<String> = dict
        .get("CFBundleSupportedPlatforms")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_string().map(str::to_string)).collect())
        .unwrap_or_default();
    let is_tvos = families.contains(&3)
        || platform.starts_with("appletv")
        || supported.iter().any(|p| p.starts_with("AppleTV"));
    let display = [get("CFBundleDisplayName"), get("CFBundleName")].into_iter().find(|x| !x.is_empty()).unwrap_or_default();
    Ok(json!({
        "ok": true,
        "bundle_id": get("CFBundleIdentifier"),
        "name": display,
        "version": get("CFBundleShortVersionString"),
        "is_tvos": is_tvos,
        "has_extensions": (0..zip.len()).filter_map(|i| zip.by_index(i).ok().map(|f| f.name().to_string()))
            .any(|n| n.contains(".appex/")),
    }))
}

fn inspect(req: &Value) -> Result<Value, String> {
    inspect_ipa(std::path::Path::new(s(req, "ipa_path")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("isl-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_ipa(dir: &std::path::Path, family: u64) -> PathBuf {
        let path = dir.join("t.ipa");
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&path).unwrap());
        let mut info = plist::Dictionary::new();
        info.insert("CFBundleIdentifier".into(), "com.example.tv".into());
        info.insert("CFBundleName".into(), "Example".into());
        info.insert("CFBundleShortVersionString".into(), "1.2".into());
        info.insert("UIDeviceFamily".into(), plist::Value::Array(vec![family.into()]));
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &info).unwrap();
        zip.start_file("Payload/Example.app/Info.plist", zip::write::SimpleFileOptions::default()).unwrap();
        zip.write_all(&bytes).unwrap();
        zip.finish().unwrap();
        path
    }

    #[test]
    fn detects_tvos() {
        let d = temp("tv");
        let r = inspect_ipa(&make_ipa(&d, 3)).unwrap();
        assert_eq!(r["is_tvos"], true);
        assert_eq!(r["bundle_id"], "com.example.tv");
    }

    #[test]
    fn rejects_ios() {
        let d = temp("ios");
        assert_eq!(inspect_ipa(&make_ipa(&d, 1)).unwrap()["is_tvos"], false);
    }

    #[test]
    fn team_suffix() {
        assert_eq!(team_id_of("com.example.tv.ABCDE12345"), "ABCDE12345");
    }
}

#[cfg(test)]
mod hint_tests {
    #[test]
    fn hints() {
        assert!(super::hint_vi("Apple ID sign-in failed: -22406").contains("mật khẩu"));
        assert!(super::hint_vi("x -80045 y").contains("anisette"));
        assert!(super::hint_vi("Hết thời gian chờ kết nối tới 10.7.0.1").contains("VPN"));
    }
}
