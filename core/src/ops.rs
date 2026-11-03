//! Requests: sign_in, device, apps, install (also refresh), certs, revoke_cert, inspect.

use std::path::PathBuf;

use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::certificates::{CertificatesApi, DevelopmentCertificate};
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::device_type::DeveloperDeviceType;
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::TeamsApi;
use isideload::sideload::builder::SideloaderBuilder;
use isideload::sideload::cert_identity::CertificateIdentity;
use isideload::dev::teams::DeveloperTeam;
use base64::Engine as _;
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
pub(crate) const HOST_NAME: &str = "iContainer";

pub(crate) fn s<'a>(req: &'a Value, key: &str) -> &'a str {
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
    } else if l.contains("maximum number of apps") || l.contains("3 active")
        || (l.contains("maximum number") && l.contains("apps") && l.contains("free developer profile")) {
        "Thiết bị đã từ chối cài do giới hạn ứng dụng của profile/tài khoản ký. Xem lỗi gốc để xác định giới hạn; có thể chọn nguồn ký phù hợp khác hoặc gỡ app không cần dùng. Đây không phải lỗi file ghép nối."
    } else if l.contains("app id") && (l.contains("limit") || l.contains("maximum") || l.contains("10")) {
        "Apple ID miễn phí chỉ tạo được 10 App ID mỗi 7 ngày. Đợi hết hạn hoặc dùng lại app đã cài (Làm mới)."
    } else if l.contains("certificate") && (l.contains("maximum") || l.contains("too many")) {
        "Đã đủ số chứng chỉ phát triển. Thu hồi chứng chỉ cũ trong Cài đặt → Chứng chỉ."
    } else if l.contains("10.7.0.1") || l.contains("lockdownd") || l.contains("vpn") {
        "Không thấy chính thiết bị qua VPN. Mở LocalDevVPN, bật VPN, rồi quay lại iSideload."
    } else if l.contains("socket io failed") || l.contains("broken pipe") || l.contains("connection reset") {
        "Kết nối thiết bị bị ngắt khi truyền hoặc cài app. Vào Thiết bị › Kiểm tra kết nối thiết bị. Nếu chỉ lỗi khi tự gia hạn, mở lại iSideload và kiểm tra ngày hết hạn trước khi thử lại."
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
pub(crate) fn explain(context: &str, e: &Report) -> String {
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
    let op = s(&req, "op");
    // Activation-code gate removed: every op runs without an ISL- license.
    let result = match op {
        "license_status" => Ok(crate::license::status()),
        "sign_in" => sign_in_only(&req, ui).await,
        "device" => device_info(&req).await,
        "apps" => apps(&req).await,
        "uninstall" => uninstall(&req).await,
        "install" => install(&req, ui).await,
        "prepare_owner_install" => match crate::owner_setup::request(&req) {
            Ok(r)=>install(&r,ui).await,
            Err(e)=>Err(e),
        },
        "peer_pair" => crate::peer::pair(&req, ui).await,
        "peer_cancel" => crate::peer::cancel(&req),
        "peer_install" => match crate::peer::install_request(&req) {
            Ok(r) => install(&r, ui).await,
            Err(e) => Err(e),
        },
        "certs" => certs(&req, ui).await,
        "revoke_cert" => revoke(&req, ui).await,
        "export_cert" if req.get("use_imported_cert").and_then(Value::as_bool).unwrap_or(false) => crate::imported::lc_cert(&req),
        "export_cert" => export_cert(&req, ui).await,
        "import_cert" => crate::imported::import(&req),
        "imported_cert" => crate::imported::info(&req),
        "clear_imported_cert" => crate::imported::clear(&req),
        "inspect" => inspect(&req),
        "pack_self" => pack_self(&req),
        "prepare_self_update" => crate::self_update::prepare(&req),
        "container_import" => crate::container::import(&req),
        "container_prepare" => crate::container::prepare(&req),
        "container_remove" => crate::container::remove(&req),
        "pair_host" => device::host_pairing(s(&req, "pairing_path"), ui)
            .await
            .map(|udid| json!({"ok": true, "udid": udid})),
        "version" => Ok(json!({"ok": true, "version": env!("CARGO_PKG_VERSION")})),
        other => Err(format!("Unknown op '{other}'.")),
    };
    result.unwrap_or_else(fail)
}

async fn device_info(req: &Value) -> Result<Value, String> {
    if device::is_rp_pairing(s(req, "pairing_path")) {
        let (_a, hs) = device::rp_tunnel(s(req, "target"), s(req, "pairing_path")).await?;
        return Ok(json!({"ok": true, "name": "iPhone", "udid": device::rsd_prop(&hs, "UniqueDeviceID"),
                         "ios": device::rsd_prop(&hs, "OSVersion"), "mode": "remote_pairing"}));
    }
    let p = device::provider(s(req, "target"), s(req, "pairing_path"))?;
    let (name, udid, ios) = device::info(&p).await?;
    Ok(json!({"ok": true, "name": name, "udid": udid, "ios": ios}))
}

async fn uninstall(req: &Value) -> Result<Value, String> {
    let p = device::provider(s(req, "target"), s(req, "pairing_path"))?;
    device::uninstall(&p, s(req, "bundle_id")).await?;
    Ok(json!({"ok": true}))
}

async fn apps(req: &Value) -> Result<Value, String> {
    let p = device::provider(s(req, "target"), s(req, "pairing_path"))?;
    Ok(json!({"ok": true, "apps": device::sideloaded_apps(&p).await?}))
}

async fn sign_in_only(req: &Value, ui: Ui) -> Result<Value, String> {
    let (_a, mut dev) = sign_in(req, ui).await?;
    let teams = dev.list_teams().await.map_err(|e| explain("No developer team", &e))?;
    let team = teams.first().ok_or("This Apple ID has no developer team.")?;
    Ok(json!({"ok": true, "team": team.team_id, "team_name": team.name,
        "teams": teams.iter().map(|t|json!({"team_id":t.team_id,"name":t.name})).collect::<Vec<_>>() }))
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

pub(crate) fn storage(req: &Value) -> FsStorage {
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

pub(crate) fn cert_json(c: &DevelopmentCertificate) -> Value {
    json!({
        "name": c.name,
        "serial": c.serial_number,
        "machine": c.machine_name,
        "expires": c.expiration_date.map(|d| std::time::SystemTime::from(d)
            .duration_since(std::time::UNIX_EPOCH).map(|x| x.as_secs()).unwrap_or(0)),
    })
}

// ---- Certificates ----

fn certificate_team(req:&Value,teams:&[DeveloperTeam])->Result<DeveloperTeam,String>{
    let explicit=s(req,"certificate_team_id");
    if !explicit.is_empty(){return crate::self_refresh::select_team(teams,explicit,s(req,"apple_id"));}
    crate::owner_setup::choose_team(teams,&crate::certificate_policy::current_team(req).unwrap_or_default())
}
async fn certs(req: &Value, ui: Ui) -> Result<Value, String> {
    let (_a, mut dev) = sign_in(req, ui).await?;
    let teams=dev.list_teams().await.map_err(|e|explain("Không lấy được Team",&e))?;
    let team=certificate_team(req,&teams)?;
    let list = dev.list_ios_certs(&team).await.map_err(|e| explain("Không tải được chứng chỉ", &e))?;
    let rows=crate::certificate_policy::rows(req,&team.team_id,&list);
    Ok(json!({"ok":true,"team":team.team_id,"apple_id":s(req,"apple_id"),"certs":rows,
        "teams":teams.iter().map(|t|json!({"id":t.team_id,"name":t.name.clone().unwrap_or_else(||t.team_id.clone())})).collect::<Vec<_>>()}))
}

async fn revoke(req: &Value, ui: Ui) -> Result<Value, String> {
    let (_a, mut dev) = sign_in(req, ui).await?;
    let teams=dev.list_teams().await.map_err(|e|explain("Không kiểm tra được Team",&e))?;
    if s(req,"certificate_team_id").is_empty(){return Err("Tải lại danh sách chứng chỉ và chọn đúng Team trước khi thu hồi.".into());}
    let team=certificate_team(req,&teams)?;
    let list=dev.list_ios_certs(&team).await.map_err(|e|explain("Không kiểm tra được chứng chỉ",&e))?;
    let rows=crate::certificate_policy::rows(req,&team.team_id,&list);
    let answer=json!({"serials":[s(req,"serial")],"allow_current":req["allow_current"].as_bool().unwrap_or(false)}).to_string();
    let serial=crate::certificate_policy::selection(&answer,&rows)?.remove(0);
    dev.revoke_development_cert(&team,&serial,DeveloperDeviceType::Ios)
        .await.map_err(|e|explain("Thu hồi chứng chỉ thất bại",&e))?;
    Ok(json!({"ok":true,"serial":serial,"team":team.team_id}))
}

// ---- LiveContainer certificate export ----

/// Loads the development certificate iSideload signs with (private key kept in storage)
/// and encodes it as a password-protected PKCS#12 for LiveContainer's
/// `livecontainer://certificate?cert=<base64>&password=<pw>` import.
/// Reuses a matching identity. If quota recovery is needed, it uses the same
/// explicit revocation policy as installation and renewal.
async fn lc_cert_json(dev: &mut DeveloperSession, team: &DeveloperTeam, req: &Value, ui: Ui) -> Result<Value, String> {
    let recovery = crate::certificate_policy::behavior(req, ui, &team.team_id);
    let id = CertificateIdentity::retrieve(
        HOST_NAME,
        s(req, "apple_id"),
        dev,
        team,
        &storage(req),
        &recovery,
    )
    .await
    .map_err(|e| explain("Không lấy được chứng chỉ", &e))?;
    let password = if id.machine_id.is_empty() { "isideload".to_string() } else { id.machine_id.clone() };
    let p12 = id.as_p12(&password).await.map_err(|e| explain("Không xuất được file .p12", &e))?;
    Ok(json!({
        "p12_base64": base64::engine::general_purpose::STANDARD.encode(&p12),
        "password": password,
        "serial": id.get_serial_number(),
        "team_id": team.team_id,
    }))
}

async fn export_cert(req: &Value, ui: Ui) -> Result<Value, String> {
    let (_a, mut dev) = sign_in(req, ui).await?;
    let teams=dev.list_teams().await.map_err(|e| explain("No developer team", &e))?;
    let team=if !s(req,"expected_team_id").is_empty(){
        crate::self_refresh::select_team(&teams,s(req,"expected_team_id"),s(req,"apple_id"))?
    }else{teams.into_iter().next().ok_or("This Apple ID has no developer team.")?};
    ui.progress("Đang xuất chứng chỉ…", None);
    let mut v = lc_cert_json(&mut dev, &team, req, ui).await?;
    v["ok"] = json!(true);
    Ok(v)
}

// ---- Install / refresh ----

/// Reads ExpirationDate from the signed bundle's embedded.mobileprovision.
pub(crate) fn profile_expiry(app: &std::path::Path) -> Option<u64> {
    let bytes = std::fs::read(app.join("embedded.mobileprovision")).ok()?;
    let start = bytes.windows(6).position(|w| w == b"<?xml ")?;
    let end = bytes.windows(8).rposition(|w| w == b"</plist>")? + 8;
    let dict: plist::Dictionary = plist::from_bytes(&bytes[start..end]).ok()?;
    let date = dict.get("ExpirationDate")?.as_date()?;
    std::time::SystemTime::from(date).duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_secs())
}

pub(crate) fn bundle_info(app: &std::path::Path) -> (String, String, String) {
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
    let self_refresh = req.get("self_refresh").and_then(Value::as_bool).unwrap_or(false);
    let sign_only=req.get("sign_only").and_then(Value::as_bool).unwrap_or(false);
    let owner_setup=req.get("owner_setup").and_then(Value::as_bool).unwrap_or(false);
    if sign_only && !owner_setup {return Err("Chỉ xuất bản cài cá nhân từ luồng thiết lập iContainer.".into());}
    let installed_team = if self_refresh { Some(crate::self_refresh::installed_team(&ipa)?) } else { None };
    if self_refresh {
        let installed_id = s(req, "installed_bundle_id");
        let actual = inspect_ipa(&ipa)?;
        if !crate::owner_setup::own_id(installed_id)
            || actual["bundle_id"].as_str() != Some(installed_id) {
            return Err("Bản đóng gói không khớp iSideload đang chạy. Hãy mở lại app rồi thử làm mới.".into());
        }
    }
    if req.get("use_imported_cert").and_then(Value::as_bool).unwrap_or(false) {
        return crate::imported::install(req, ui).await;
    }

    // 1. Reach this device through the loopback VPN first.
    let rp = device::is_rp_pairing(s(req, "pairing_path"));
    if !sign_only {ui.progress("Đang kết nối thiết bị qua VPN…", None);}
    let (provider, mut tunnel, dev_name, udid) = if sign_only {
        let id=s(req,"udid");
        if id.is_empty() || id.len()>64 || !id.bytes().all(|c|c.is_ascii_hexdigit() || c==b'-') {return Err("Chưa xác định được iPhone. Hãy kiểm tra kết nối thiết bị trước khi thiết lập.".into());}
        (None,None,"iPhone".to_string(),id.to_string())
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

    let expected = s(req, "expected_udid");
    if !expected.is_empty() && !expected.eq_ignore_ascii_case(&udid) {
        return Err("Địa chỉ Wi-Fi hiện thuộc máy khác. Hãy ghép nối lại đúng máy nhận trước khi cài.".into());
    }

    // 2. Apple ID + developer session; certificate is reused from storage when valid.
    let (_account, mut dev) = sign_in(req, ui).await?;
    // Validate the selected account before creating certificates, registering
    // devices or attempting to claim an App ID already owned by another team.
    let refresh_team = if let Some(expected) = installed_team.as_deref() {
        let teams=dev.list_teams().await.map_err(|e|explain("Không kiểm tra được Team của Apple ID",&e))?;
        Some(crate::self_refresh::select_team(&teams,expected,s(req,"apple_id"))?)
    } else if !s(req,"preferred_team_id").is_empty() {
        let teams=dev.list_teams().await.map_err(|e|explain("Không kiểm tra được Team của máy nhận",&e))?;
        Some(crate::self_refresh::select_team(&teams,s(req,"preferred_team_id"),s(req,"apple_id"))?)
    } else if owner_setup {
        let teams=dev.list_teams().await.map_err(|e|explain("Không lấy được Team của tài khoản người dùng",&e))?;
        Some(crate::owner_setup::choose_team(&teams,s(req,"owner_source_team"))?)
    } else { None };
    let signing_team=if let Some(team)=refresh_team{team}else{
        dev.list_teams().await.map_err(|e|explain("No developer team",&e))?.into_iter().next().ok_or("This Apple ID has no developer team.")?
    };
    let recovery = crate::certificate_policy::behavior(req, ui, &signing_team.team_id);
    let mut sideloader = SideloaderBuilder::new(dev, s(req, "apple_id").to_string())
        .storage(Box::new(storage(req)))
        .machine_name(HOST_NAME.to_string())
        .max_certs_behavior(recovery)
        .build();
    sideloader.set_device_type(Some(DeveloperDeviceType::Ios));
    sideloader.set_preserve_bundle_id(self_refresh);

    // 3. Register this iPhone/iPad as a development device.
    ui.progress("Đang đăng ký thiết bị…", None);
    let team = signing_team;
    sideloader
        .get_dev_session()
        .ensure_device_registered(&team, &dev_name, &udid, Some(DeveloperDeviceType::Ios))
        .await
        .map_err(|e| explain("Couldn't register this device", &e))?;

    // 4. Fresh profile + signature.
    ui.progress("Đang ký app…", Some(0.0));
    let progress = move |f: f32| async move { ui.progress("Đang ký app…", Some(f as f64)) };
    let (signed, _) = sideloader
        .sign_app(ipa, Some(team.clone()), false, Some(progress), None, Some(&udid))
        .await
        .map_err(|e| explain("Signing failed", &e))?;
    let (bundle_id, name, version) = bundle_info(&signed);
    let expires = profile_expiry(&signed);
    if sign_only {
        let result=crate::owner_setup::write_result(req,&signed,&team.team_id,&udid);
        let _=std::fs::remove_dir_all(&signed);
        return result;
    }

    // 5. Upload (AFC) + install (installation_proxy) on this same device.
    let label = if upgrade { "Đang làm mới app…" } else { "Đang cài app…" };
    ui.progress(label, Some(0.0));
    let cb = move |p: u64| ui.progress(label, Some((p as f64 / 100.0).clamp(0.0, 1.0)));
    if let Some((adapter, hs)) = tunnel.as_mut() {
        isideload::sideload::install::install_app_rsd_mode(adapter, hs, &signed, upgrade, cb)
            .await
            .map_err(|e| explain("Install failed", &e))?;
    } else if let Some(p) = provider.as_ref() {
        isideload::sideload::install::install_app(p, &signed, cb)
            .await
            .map_err(|e| explain("Install failed", &e))?;
    }
    let setup = if crate::owner_setup::own_id(&bundle_id) && !self_refresh {
        use idevice::{IdeviceService,RsdService,house_arrest::HouseArrestClient};
        ui.progress("Đang thiết lập khóa ký và ghép nối cho người nhận…",None);
        let result=async {
            let files=crate::receiver_setup::prepare(req,&signed,&team.team_id,&udid)?;
            let house=if let Some((adapter,hs))=tunnel.as_mut(){
                HouseArrestClient::connect_rsd(adapter,hs).await.map_err(|e|e.to_string())?
            }else if let Some(provider)=provider.as_ref(){
                HouseArrestClient::connect(provider).await.map_err(|e|e.to_string())?
            }else{return Err("Không còn kết nối tới máy nhận.".to_string());};
            let mut afc=house.vend_documents(&bundle_id).await.map_err(|e|e.to_string())?;
            crate::receiver_setup::deliver(&mut afc,&files).await
        }.await;
        Some(result)
    }else{None};
    let _ = std::fs::remove_dir_all(&signed);

    // LiveContainer needs the signing certificate for JIT-less mode: hand it back so the app can pass it on.
    let lc_cert = if bundle_id.starts_with("com.kdt.livecontainer") {
        lc_cert_json(sideloader.get_dev_session(), &team, req, ui).await.ok()
    } else { None };

    Ok(json!({
        "lc_cert": lc_cert,
        "recipient_setup_verified": setup.as_ref().map(|r|r.is_ok()),
        "recipient_setup_error": setup.as_ref().and_then(|r|r.as_ref().err()),
        "ok": true,
        "bundle_id": bundle_id,
        "name": name,
        "version": version,
        "team_id": team.team_id,
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

/// Packs the running app bundle (.app dir) into an IPA so iSideload can re-sign and
/// re-install itself on-device. Existing signature files are dropped by the signer anyway.
fn pack_self(req: &Value) -> Result<Value, String> {
    use std::io::Write;
    let app = PathBuf::from(s(req, "app_path"));
    let out = PathBuf::from(s(req, "out_path"));
    let name = app.file_name().and_then(|n| n.to_str()).ok_or("Bad app path")?.to_string();
    let f = std::fs::File::create(&out).map_err(|e| format!("Can't create IPA: {e}"))?;
    let mut z = zip::ZipWriter::new(f);
    let opt = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    let mut stack = vec![app.clone()];
    while let Some(dir) = stack.pop() {
        for e in std::fs::read_dir(&dir).map_err(|e| e.to_string())? {
            let e = e.map_err(|e| e.to_string())?;
            let path = e.path();
            let rel = path.strip_prefix(&app).map_err(|e| e.to_string())?.to_string_lossy().replace('\\', "/");
            let entry = format!("Payload/{name}/{rel}");
            let ft = e.file_type().map_err(|e| e.to_string())?;
            if ft.is_dir() {
                z.add_directory(format!("{entry}/"), opt).map_err(|e| e.to_string())?;
                stack.push(path);
            } else if ft.is_file() {
                let mode = {
                    use std::os::unix::fs::PermissionsExt;
                    e.metadata().map(|m| m.permissions().mode()).unwrap_or(0o644)
                };
                z.start_file(entry, opt.unix_permissions(mode)).map_err(|e| e.to_string())?;
                let mut data = std::fs::read(&path).map_err(|e| e.to_string())?;
                if rel == "Info.plist" && req.get("peer_bootstrap").and_then(Value::as_bool).unwrap_or(false) {
                    let mut info: plist::Dictionary = plist::from_bytes(&data).map_err(|e| e.to_string())?;
                    let old = info.get("CFBundleIdentifier").and_then(plist::Value::as_string).unwrap_or("");
                    let family = crate::owner_setup::family(old)
                        .ok_or("Chỉ đóng gói ứng dụng của chính dự án để cài cho máy khác.")?;
                    // Drop the source phone's team suffix before signing for the receiving phone.
                    info.insert("CFBundleIdentifier".into(), plist::Value::String(family.into()));
                    let product=if family=="com.hongson117.sicontainer.runner1"{"SIContainer Phụ 1"}else if family=="com.hongson117.sicontainer.runner2"{"SIContainer Phụ 2"}else if family=="com.hongson117.sicontainer"{"SIContainer"}else if family=="com.hongson117.icontainer"{"iContainer"}else{"iSideload"};
                    let label=if req.get("personal_setup").and_then(Value::as_bool).unwrap_or(false){format!("{product} Cá nhân")}else{product.to_string()};
                    info.insert("CFBundleDisplayName".into(),plist::Value::String(label));
                    data.clear();
                    plist::to_writer_xml(&mut data, &info).map_err(|e| e.to_string())?;
                }
                z.write_all(&data).map_err(|e| e.to_string())?;
            }
        }
    }
    z.finish().map_err(|e| e.to_string())?;
    Ok(json!({"ok": true, "ipa_path": out.to_string_lossy()}))
}

fn inspect(req: &Value) -> Result<Value, String> {
    let path = std::path::Path::new(s(req, "ipa_path"));
    let mut v = inspect_ipa(path)?;
    let out = s(req, "icon_out");
    if !out.is_empty() {
        if let Some(bytes) = extract_icon(path) {
            if std::fs::write(out, bytes).is_ok() { v["icon_path"] = json!(out); }
        }
    }
    Ok(v)
}

/// Largest top-level icon PNG of Payload/*.app (CFBundleIcons / CFBundleIconFiles / AppIcon*).
/// Bytes may be CgBI-crushed; UIImage decodes those natively on iOS.
fn extract_icon(path: &std::path::Path) -> Option<Vec<u8>> {
    use std::io::Read;
    let mut zip = zip::ZipArchive::new(std::fs::File::open(path).ok()?).ok()?;
    let names: Vec<String> = (0..zip.len()).filter_map(|i| zip.by_index(i).ok().map(|f| f.name().to_string())).collect();
    let info = names.iter().find(|n| { let p: Vec<&str> = n.split('/').collect(); p.len() == 3 && p[0] == "Payload" && p[1].ends_with(".app") && p[2] == "Info.plist" })?.clone();
    let app_dir = info.trim_end_matches("Info.plist").to_string();
    let mut data = Vec::new();
    zip.by_name(&info).ok()?.read_to_end(&mut data).ok()?;
    let dict: plist::Dictionary = plist::from_bytes(&data).ok()?;
    let mut prefixes: Vec<String> = Vec::new();
    for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
        if let Some(files) = dict.get(key).and_then(|v| v.as_dictionary()).and_then(|d| d.get("CFBundlePrimaryIcon"))
            .and_then(|v| v.as_dictionary()).and_then(|d| d.get("CFBundleIconFiles")).and_then(|v| v.as_array()) {
            prefixes.extend(files.iter().filter_map(|x| x.as_string().map(|s| s.trim_end_matches(".png").to_string())));
        }
    }
    if let Some(files) = dict.get("CFBundleIconFiles").and_then(|v| v.as_array()) {
        prefixes.extend(files.iter().filter_map(|x| x.as_string().map(|s| s.trim_end_matches(".png").to_string())));
    }
    if let Some(f) = dict.get("CFBundleIconFile").and_then(|v| v.as_string()) { prefixes.push(f.trim_end_matches(".png").to_string()); }
    prefixes.push("AppIcon".into()); prefixes.push("Icon".into());
    let mut best: Option<(u64, String)> = None;
    for i in 0..zip.len() {
        let Ok(f) = zip.by_index(i) else { continue };
        let n = f.name().to_string();
        let Some(rest) = n.strip_prefix(&app_dir) else { continue };
        if rest.contains('/') || !rest.to_lowercase().ends_with(".png") { continue }
        if !prefixes.iter().any(|p| !p.is_empty() && rest.starts_with(p.as_str())) { continue }
        let sz = f.size();
        if best.as_ref().map_or(true, |b| sz > b.0) { best = Some((sz, n)); }
    }
    let (_, n) = best?;
    let mut out = Vec::new();
    zip.by_name(&n).ok()?.read_to_end(&mut out).ok()?;
    Some(out)
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

    #[test]
    fn repeated_signing_keeps_a_stable_bundle_identity() {
        use isideload::sideload::sideloader::signing_bundle_id;
        let original = "com.hongson117.isideload";
        let signed = signing_bundle_id(original, "ABCDE12345", false);
        assert_eq!(signed, "com.hongson117.isideload.ABCDE12345");
        assert_eq!(signing_bundle_id(&signed, "ABCDE12345", false), signed);
        assert_eq!(signing_bundle_id(&signed, "NEWTEAM123", true), signed);
        assert_eq!(signing_bundle_id(&signed, "ABCDE12345", true), signed);
    }

    #[test]
    fn peer_bootstrap_normalizes_only_exported_bundle_and_never_packs_account_data() {
        use std::io::Read;
        for (app_name, family) in [("iSideload.app", "com.hongson117.isideload"), ("iContainer.app", "com.hongson117.icontainer")] {
        let root = temp("peer-pack");
        let app = root.join(app_name);
        std::fs::create_dir(&app).unwrap();
        let mut info = plist::Dictionary::new();
        info.insert("CFBundleIdentifier".into(), format!("{family}.OLDTEAM123.OLDTEAM123").into());
        info.insert("CFBundleVersion".into(), "42".into());
        plist::to_file_xml(app.join("Info.plist"), &info).unwrap();
        std::fs::write(root.join("private-account-data"), b"must not travel").unwrap();
        let original = std::fs::read(app.join("Info.plist")).unwrap();
        let out = root.join("peer.ipa");
        pack_self(&json!({"app_path": app, "out_path": out, "peer_bootstrap": true})).unwrap();
        assert_eq!(std::fs::read(app.join("Info.plist")).unwrap(), original);
        let mut zip = zip::ZipArchive::new(std::fs::File::open(out).unwrap()).unwrap();
        assert_eq!(zip.len(), 1);
        let mut bytes = Vec::new();
        zip.by_name(&format!("Payload/{app_name}/Info.plist")).unwrap().read_to_end(&mut bytes).unwrap();
        let exported: plist::Dictionary = plist::from_bytes(&bytes).unwrap();
        assert_eq!(exported["CFBundleIdentifier"].as_string(), Some(family));
        assert_eq!(exported["CFBundleVersion"].as_string(), Some("42"));
        }
    }
}

#[cfg(test)]
mod hint_tests {
    #[test]
    fn hints() {
        assert!(super::hint_vi("Apple ID sign-in failed: -22406").contains("mật khẩu"));
        assert!(super::hint_vi("x -80045 y").contains("anisette"));
        let full = "Install failed: Lỗi khi chờ iOS cài ứng dụng (Remote Pairing) — Application verification failed: This device has reached the maximum number of installed apps using a free developer profile";
        let message = super::hint_vi(full);
        assert!(message.contains("Thiết bị đã từ chối"));
        assert!(!message.contains("3 app"));
        assert!(!message.contains("chung giới hạn"));
        let app_id = super::hint_vi("app limit: You may only register 10 App IDs every 7 days");
        assert!(app_id.contains("10 App ID"));
        assert!(!app_id.contains("Thiết bị đã từ chối"));
        assert!(!message.contains("File ghép nối không hợp lệ"));
        assert!(super::hint_vi("Hết thời gian chờ kết nối tới 10.7.0.1").contains("VPN"));
    }
}
#[cfg(test)]mod certificate_manager_tests {
    use super::*;
    fn team(id:&str)->DeveloperTeam{DeveloperTeam{name:None,team_id:id.into(),r#type:None,status:None}}
    #[test]fn manual_management_uses_selected_team_instead_of_first_membership(){
        let teams=vec![team("FIRST12345"),team("OTHER12345")];
        let req=json!({"apple_id":"owner@example.com","certificate_team_id":"OTHER12345"});
        assert_eq!(certificate_team(&req,&teams).unwrap().team_id,"OTHER12345");
        assert!(certificate_team(&req,&[team("FIRST12345")]).is_err());
    }
}
