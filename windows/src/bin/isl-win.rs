//! isl-win: first-time iSideload install over USB on Windows (Apple usbmuxd from Apple Devices/iTunes, TCP 127.0.0.1:27015).
use std::io::Write;
use std::path::PathBuf;
use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::device_type::DeveloperDeviceType;
use isideload::dev::devices::DevicesApi;
use isideload::sideload::builder::{MaxCertsBehavior, SideloaderBuilder};
use isideload::util::fs_storage::FsStorage;
use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection};
use rootcause::Report;

const ANISETTE: &[&str] = &["https://ani.jkcoxson.com", "https://mac-ani.jkcoxson.com", "https://ani.npeg.us", "https://ani.sidestore.io"];

fn prompt(msg: &str) -> String { print!("{msg}"); let _ = std::io::stdout().flush(); let mut s = String::new(); let _ = std::io::stdin().read_line(&mut s); s.trim().to_string() }
fn fail(code: i32, msg: String) -> ! { eprintln!("\nLOI: {msg}"); let _ = prompt("Nhan Enter de thoat..."); std::process::exit(code) }

async fn login(storage: &std::path::Path, id: &str, pw: &str) -> Result<AppleAccount, String> {
    let mut urls: Vec<String> = Vec::new();
    urls.extend(ANISETTE.iter().map(|s| s.to_string()));
    let mut last = String::new();
    for url in urls {
        let dir = storage.join("anisette").join(url.trim_start_matches("https://").replace(['/', ':'], "_"));
        let _ = std::fs::create_dir_all(&dir);
        let provider = match RemoteV3AnisetteProvider::new(&url, Box::new(FsStorage::new(dir)), "0".into()) {
            Ok(p) => p, Err(e) => { last = format!("anisette {url}: {e}"); continue }
        };
        let cb = move |p: TwoFactorCallbackParams| { async move {
            if let Some(e) = p.last_error { println!("(Ma truoc bi loi: {e})") }
            let c = prompt("Nhap ma 2FA 6 so Apple gui ve (hoac go sms): ");
            Ok::<_, Report>(match if c.is_empty() { None } else { Some(c) } {
                Some(c) if c == "sms" => TwoFactorCallbackResponse::SendSms(p.selected_number_id.or(p.numbers.first().map(|n| n.id)).unwrap_or(1)),
                Some(c) => TwoFactorCallbackResponse::SubmitCode(c),
                None => TwoFactorCallbackResponse::Abort,
            })
        }};
        eprintln!("Signing in via anisette {url} ...");
        match AppleAccount::builder(id).anisette_provider(provider).login(pw, cb).await {
            Ok(acc) => return Ok(acc),
            Err(e) => {
                last = format!("{e}");
                eprintln!("  failed: {}", last.lines().take(4).collect::<Vec<_>>().join(" | "));
                let l = last.to_lowercase();
                if l.contains("-22406") || l.contains("abort") || l.contains("2fa") { break }
            }
        }
    }
    Err(last)
}


#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let ipa: PathBuf = std::env::args().nth(1).map(PathBuf::from).unwrap_or_else(|| {
        std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.join("iSideload.ipa"))).unwrap_or("iSideload.ipa".into()) });
    if !ipa.exists() { fail(2, format!("khong thay {}", ipa.display())) }
    let storage = std::env::var("LOCALAPPDATA").map(PathBuf::from).unwrap_or(std::env::temp_dir()).join("iSideload-win");
    let _ = std::fs::create_dir_all(&storage);
    println!("== Tim iPhone qua cap USB (can Apple Devices hoac iTunes) ==");
    let addr = UsbmuxdAddr::from_env_var().unwrap_or_default();
    let mut mux = match UsbmuxdConnection::default().await { Ok(m) => m,
        Err(e) => fail(3, format!("khong ket noi duoc Apple Mobile Device Service ({e}). Cai Apple Devices (Microsoft Store) hoac iTunes.")) };
    let devs = mux.get_devices().await.unwrap_or_else(|e| fail(3, format!("doc danh sach may: {e}")));
    let dev = devs.into_iter().find(|d| matches!(d.connection_type, Connection::Usb)).unwrap_or_else(|| fail(4, "khong thay iPhone qua USB. Cam cap, mo khoa, bam Tin cay may tinh nay.".into()));
    let provider = dev.to_provider(addr, "isl-win");
    let info = isideload::util::device::IdeviceInfo::from_device(&provider).await
        .unwrap_or_else(|e| fail(5, format!("chua ghep noi duoc voi iPhone (mo khoa, bam Tin cay, mo Apple Devices 1 lan): {e}")));
    println!("Thay may: {} (UDID {})", info.name, info.udid);
    let id = prompt("Apple ID (email): ");
    let pw = rpassword::prompt_password("Mat khau Apple ID (an, khong luu): ").unwrap_or_default();
    if id.is_empty() || pw.is_empty() { fail(1, "thieu Apple ID / mat khau".into()) }
    let mut acc = login(&storage, &id, &pw).await.unwrap_or_else(|e| fail(10, format!("dang nhap that bai: {e}")));
    drop(pw);
    println!("Da dang nhap.");
    let dev_s = DeveloperSession::from_account(&mut acc).await.unwrap_or_else(|e| fail(11, format!("developer session: {e}")));
    let mut sl = SideloaderBuilder::<isideload::util::callbacks::MaxCertsCallbackBox>::new(dev_s, id.clone()).storage(Box::new(FsStorage::new(storage.clone())))
        .machine_name("iSideload".into()).max_certs_behavior(MaxCertsBehavior::Revoke).build();
    sl.set_device_type(Some(DeveloperDeviceType::Ios));
    let team = sl.get_team().await.unwrap_or_else(|e| fail(12, format!("khong co team: {e}")));
    println!("Team {}; dang ky thiet bi...", team.team_id);
    if let Err(e) = sl.get_dev_session().ensure_device_registered(&team, &info.name, &info.udid, Some(DeveloperDeviceType::Ios)).await { fail(13, format!("dang ky may: {e}")) }
    let prog = |f: f32| async move { print!("\rKy app {:.0}%   ", f * 100.0); let _ = std::io::stdout().flush(); };
    let (signed, _) = sl.sign_app(ipa, Some(team), false, Some(prog), None, Some(&info.udid)).await.unwrap_or_else(|e| fail(14, format!("ky that bai: {e}")));
    println!("\nDang cai len iPhone qua USB...");
    if let Err(e) = isideload::sideload::install::install_app(&provider, &signed, |p| { print!("\rCai {p}%   "); let _ = std::io::stdout().flush(); }).await { fail(16, format!("cai that bai: {e}")) }
    let _ = std::fs::remove_dir_all(&signed);
    println!("\n\nXONG! Tren iPhone: Cai dat > Cai dat chung > VPN & Quan ly thiet bi > Apple ID cua ban > Tin cay. Roi mo iSideload.");
    let _ = prompt("Nhan Enter de thoat...");
}
