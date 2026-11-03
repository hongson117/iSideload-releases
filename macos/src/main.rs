//! Native macOS USB installer and Remote Pairing setup tool.
#[path = "../../installer-common/pairing_setup.rs"]
mod pairing_setup;

use std::{io::Write, path::{Path, PathBuf}, time::Duration};
use idevice::{IdeviceService, amfi::AmfiClient, installation_proxy::InstallationProxyClient,
              provider::UsbmuxdProvider, remote_pairing::RpPairingFile,
              usbmuxd::{Connection, UsbmuxdAddr}};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{certificates::DevelopmentCertificate, developer_session::DeveloperSession,
          device_type::DeveloperDeviceType, devices::DevicesApi},
    sideload::builder::{MaxCertsBehavior, SideloaderBuilder},
    util::{callbacks::MaxCertsCallbackFuture, fs_storage::FsStorage},
};
use rootcause::Report;
use pairing_setup::{app_id_matches, selection};

const ANISETTE: &[&str] = &["https://ani.jkcoxson.com", "https://mac-ani.jkcoxson.com", "https://ani.npeg.us", "https://ani.sidestore.io"];

fn prompt(message: &str) -> String {
    print!("{message}"); let _ = std::io::stdout().flush();
    let mut line = String::new(); let _ = std::io::stdin().read_line(&mut line);
    line.trim().to_string()
}

fn storage_path(user_home: &Path) -> PathBuf {
    user_home.join("Library/Application Support/iSideload-Installer")
}

fn fail(code: i32, message: impl std::fmt::Display) -> ! {
    eprintln!("\nCHƯA HOÀN TẤT: {message}");
    std::process::exit(code)
}

async fn login(storage: &Path, id: &str, password: &str) -> Result<AppleAccount, String> {
    let mut last = String::new();
    for &url in ANISETTE {
        let dir = storage.join("anisette").join(url.trim_start_matches("https://").replace(['/', ':'], "_"));
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let provider = match RemoteV3AnisetteProvider::new(url, Box::new(FsStorage::new(dir)), "0".into()) {
            Ok(provider) => provider,
            Err(error) => { last = error.to_string(); continue; }
        };
        let callback = |params: TwoFactorCallbackParams| async move {
            if let Some(error) = params.last_error { eprintln!("Mã trước bị từ chối: {error}"); }
            let code = prompt("Nhập mã 2FA 6 số (hoặc sms để yêu cầu SMS; Enter để hủy): ");
            Ok::<_, Report>(match code.as_str() {
                "" => TwoFactorCallbackResponse::Abort,
                "sms" => TwoFactorCallbackResponse::SendSms(params.selected_number_id.or(params.numbers.first().map(|n| n.id)).unwrap_or(1)),
                _ => TwoFactorCallbackResponse::SubmitCode(code),
            })
        };
        println!("Đang xác thực Apple ID qua {url}…");
        match AppleAccount::builder(id).anisette_provider(provider).login(password, callback).await {
            Ok(account) => return Ok(account),
            Err(error) => {
                last = error.to_string();
                let lower = last.to_lowercase();
                if ["-22406", "abort", "2fa", "password", "locked"].iter().any(|needle| lower.contains(needle)) { break; }
                eprintln!("Máy chủ chưa xác thực được, thử máy chủ dự phòng…");
            }
        }
    }
    Err(last)
}

fn revoke_prompt(certs: Vec<DevelopmentCertificate>) -> MaxCertsCallbackFuture {
    Box::pin(async move {
        let certs: Vec<_> = certs.into_iter().filter(|cert| cert.serial_number.as_deref().is_some_and(|s| !s.is_empty())).collect();
        if certs.is_empty() { return Ok(None); }
        println!("\nApple báo hết chỗ cấp chứng chỉ phát triển.");
        for (index, cert) in certs.iter().enumerate() {
            println!("  {}. {} — {}", index + 1,
                cert.machine_name.as_deref().or(cert.name.as_deref()).unwrap_or("Không rõ thiết bị"),
                cert.serial_number.as_deref().unwrap_or(""));
        }
        println!("Thu hồi chứng chỉ có thể khiến các app đã ký bằng nó ngừng mở.");
        let Some(index) = selection(&prompt("Chọn MỘT số để thu hồi, hoặc Enter để hủy: "), certs.len()) else { return Ok(None); };
        if prompt("Gõ THU HOI để xác nhận chứng chỉ vừa chọn: ") != "THU HOI" { return Ok(None); }
        Ok(certs[index].serial_number.clone().map(|s| vec![s]))
    })
}

async fn usb_devices(addr: &UsbmuxdAddr) -> Result<Vec<idevice::usbmuxd::UsbmuxdDevice>, String> {
    let mut mux = addr.connect(0).await.map_err(|e| format!("Không kết nối được dịch vụ USB của macOS: {e}. Mở Finder, cắm cáp và kiểm tra iPhone đã được nhận. Không cần cài usbmuxd bằng Homebrew."))?;
    Ok(mux.get_devices().await.map_err(|e| e.to_string())?.into_iter()
        .filter(|device| matches!(device.connection_type, Connection::Usb)).collect())
}

async fn reconnect(addr: &UsbmuxdAddr, udid: &str) -> Result<UsbmuxdProvider, String> {
    for _ in 0..90 {
        if let Ok(Ok(devices)) = tokio::time::timeout(Duration::from_secs(3), usb_devices(addr)).await {
            if let Some(device) = devices.into_iter().find(|d| d.udid == udid) {
                return Ok(device.to_provider(addr.clone(), "iSideload-macOS"));
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Err("Chưa thấy lại đúng iPhone qua USB. Mở khóa, bấm Tin cậy, kiểm tra cáp rồi chạy chế độ 2.".into())
}

async fn developer_ready(addr: &UsbmuxdAddr, udid: &str) -> Result<UsbmuxdProvider, String> {
    for _ in 0..3 {
        let provider = reconnect(addr, udid).await?;
        let mut amfi = AmfiClient::connect(&provider).await.map_err(|e| format!("Không kiểm tra được Chế độ nhà phát triển: {e}. Giữ iPhone mở khóa."))?;
        if amfi.get_developer_mode_status().await.map_err(|e| e.to_string())? { return Ok(provider); }
        let _ = amfi.reveal_developer_mode_option_in_ui().await;
        drop(amfi);
        println!("\nTrên iPhone: Cài đặt > Quyền riêng tư & Bảo mật > Chế độ nhà phát triển > Bật.");
        println!("Nếu iPhone yêu cầu khởi động lại, giữ cáp, chờ máy lên, mở khóa và xác nhận Bật.");
        if prompt("Xong bước trên, nhấn Enter để tiếp tục (gõ HUY để dừng): ").eq_ignore_ascii_case("HUY") {
            return Err("Đã dừng. Có thể chạy lại chế độ 2 khi sẵn sàng, không cần cài lại app.".into());
        }
    }
    Err("Chế độ nhà phát triển vẫn chưa bật; chưa tạo file ghép đôi. Bật xong chạy lại chế độ 2.".into())
}

async fn choose_installed_app(provider: &UsbmuxdProvider) -> Result<String, String> {
    let apps = InstallationProxyClient::connect(provider).await.map_err(|e| e.to_string())?
        .get_apps(Some("User"), None).await.map_err(|e| e.to_string())?;
    let mut ids: Vec<_> = apps.keys().filter(|id| app_id_matches(id)).cloned().collect();
    ids.sort();
    if ids.is_empty() { return Err("Không thấy iSideload đã cài. Chọn chế độ 1 để cài từ đầu. Nếu đã tự đổi bundle ID trong Sideloadly, dùng lại bundle ID iSideload chính thức.".into()); }
    if ids.len() == 1 { return Ok(ids.remove(0)); }
    println!("Có nhiều bản iSideload:");
    for (i, id) in ids.iter().enumerate() { println!("  {}. {id}", i + 1); }
    let index = selection(&prompt("Chọn bản muốn thiết lập ghép đôi: "), ids.len()).ok_or("Chưa chọn ứng dụng hợp lệ.")?;
    Ok(ids.remove(index))
}

fn signed_bundle_id(path: &Path) -> Result<String, String> {
    let info = plist::Value::from_file(path.join("Info.plist")).map_err(|e| e.to_string())?;
    let id = info.as_dictionary().and_then(|d| d.get("CFBundleIdentifier")).and_then(|v| v.as_string()).ok_or("IPA không có bundle ID.")?;
    if !app_id_matches(id) { return Err("Bộ cài chỉ hỗ trợ IPA iSideload chính thức.".into()); }
    Ok(id.to_string())
}

fn cleanup_signed(path: &Path) {
    if let (Ok(path), Ok(temp)) = (path.canonicalize(), std::env::temp_dir().canonicalize()) {
        if path != temp && path.starts_with(&temp) { let _ = std::fs::remove_dir_all(path); }
    }
}

#[tokio::main]
async fn main() {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        Some("--help") | Some("-h") => {
            println!("iSideload Mac Installer\n  isl-mac [iSideload.ipa] : cài app và thiết lập Remote Pairing\n  isl-mac --pair-only     : chỉ thiết lập/sửa ghép đôi cho app đã cài\n  isl-mac --list-devices\n  isl-mac --self-test\nCần macOS 11+, iOS 17.4+, cáp dữ liệu và Tin cậy trong Finder. Không cần Homebrew/Xcode/Python."); return;
        }
        Some("--version") => { println!("iSideload Mac Installer {} ({})", env!("CARGO_PKG_VERSION"), option_env!("ISL_GIT_SHA").unwrap_or("local")); return; }
        Some("--self-test") => {
            let record = RpPairingFile::generate("installer-offline-test");
            let loaded = RpPairingFile::from_bytes(&record.to_bytes()).expect("RP round-trip");
            assert_eq!(record.public_key_bytes(), loaded.public_key_bytes());
            assert_eq!(record.identifier(), loaded.identifier());
            assert!(app_id_matches("com.hongson117.isideload.TESTTEAM01"));
            assert!(!app_id_matches("com.hongson117.isideload2"));
            assert_eq!(selection("2", 2), Some(1)); assert_eq!(selection("0", 2), None);
            assert_eq!(storage_path(Path::new("/Users/test")), PathBuf::from("/Users/test/Library/Application Support/iSideload-Installer"));
            #[cfg(target_os = "macos")]
            assert!(matches!(UsbmuxdAddr::default(), UsbmuxdAddr::UnixSocket(ref path) if path == "/var/run/usbmuxd"));
            println!("Self-test passed: RP keys/identifier round-trip, bundle family, bounded device selection, native Apple USB socket and private macOS cache path."); return;
        }
        Some(flag) if flag.starts_with('-') && !["--pair-only", "--list-devices"].contains(&flag) => fail(2, "Tùy chọn không hợp lệ; dùng --help."),
        _ => (),
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    let addr = UsbmuxdAddr::default();
    let devices = usb_devices(&addr).await.unwrap_or_else(|e| fail(3, e));
    if devices.is_empty() { fail(4, "Không thấy iPhone qua USB. Cắm cáp dữ liệu, mở khóa và bấm Tin cậy máy tính."); }
    for (i, device) in devices.iter().enumerate() { println!("  {}. iPhone/iPad USB — {}", i + 1, device.udid); }
    if arguments.first().map(String::as_str) == Some("--list-devices") { return; }
    let index = if devices.len() == 1 { 0 } else {
        selection(&prompt("Chọn số iPhone muốn thiết lập: "), devices.len()).unwrap_or_else(|| fail(4, "Chưa chọn đúng thiết bị."))
    };
    let provider = devices[index].clone().to_provider(addr.clone(), "iSideload-macOS");
    let info = isideload::util::device::IdeviceInfo::from_device(&provider).await
        .unwrap_or_else(|e| fail(5, format!("Chưa có kết nối USB tin cậy: {e}. Mở Finder, chọn iPhone, bấm Trust trên Mac và Tin cậy trên iPhone.")));
    println!("Máy nhận: {} ({})", info.name, info.udid);
    let repair = arguments.first().map(String::as_str) == Some("--pair-only");
    let bundle_id = if repair {
        choose_installed_app(&provider).await.unwrap_or_else(|e| fail(6, e))
    } else {
        let ipa = arguments.first().map(PathBuf::from).unwrap_or_else(|| std::env::current_exe().unwrap().parent().unwrap().join("iSideload.ipa"));
        if !ipa.is_file() { fail(2, "Không thấy iSideload.ipa; giải nén đầy đủ gói ZIP."); }
        let user_home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| fail(2, "Không xác định được thư mục người dùng macOS."));
        let storage = storage_path(&user_home);
        std::fs::create_dir_all(&storage).unwrap_or_else(|e| fail(2, e));
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&storage, std::fs::Permissions::from_mode(0o700)).unwrap_or_else(|e| fail(2, e));
        }
        let id = prompt("Apple ID sẽ dùng để ký và gia hạn trên iPhone (email): ");
        let password = rpassword::prompt_password("Mật khẩu Apple ID (ẩn khi nhập): ").unwrap_or_default();
        if id.is_empty() || password.is_empty() { fail(1, "Thiếu Apple ID hoặc mật khẩu."); }
        let mut account = login(&storage, &id, &password).await.unwrap_or_else(|e| fail(10, e));
        drop(password);
        let developer = DeveloperSession::from_account(&mut account).await.unwrap_or_else(|e| fail(11, e));
        let mut signer = SideloaderBuilder::new(developer, id).storage(Box::new(FsStorage::new(storage)))
            .machine_name("iSideload macOS".into()).max_certs_behavior(MaxCertsBehavior::Prompt(revoke_prompt)).build();
        signer.set_device_type(Some(DeveloperDeviceType::Ios));
        let team = signer.get_team().await.unwrap_or_else(|e| fail(12, e));
        signer.get_dev_session().ensure_device_registered(&team, &info.name, &info.udid, Some(DeveloperDeviceType::Ios)).await.unwrap_or_else(|e| fail(13, e));
        let progress = |value: f32| async move { print!("\rĐang ký app: {:.0}%   ", value * 100.0); let _ = std::io::stdout().flush(); };
        let (signed, _) = signer.sign_app(ipa, Some(team), false, Some(progress), None, Some(&info.udid)).await.unwrap_or_else(|e| fail(14, e));
        let id = signed_bundle_id(&signed).unwrap_or_else(|e| fail(14, e));
        println!("\nĐang cài iSideload qua USB…");
        let result = isideload::sideload::install::install_app(&provider, &signed, |p| { print!("\rCài: {p}%   "); let _ = std::io::stdout().flush(); }).await;
        cleanup_signed(&signed);
        if let Err(error) = result { fail(16, error); }
        println!("\nApp đã cài. Đang tiếp tục thiết lập ghép đôi; chưa rút cáp.");
        id
    };
    println!("Đóng hẳn iSideload trên iPhone trong lúc công cụ thiết lập file ghép đôi.");
    let provider = developer_ready(&addr, &info.udid).await.unwrap_or_else(|e| fail(20, e));
    // Do not cancel the whole file transaction: each transport operation has its
    // own deadline so interrupted transfers can still run their rollback.
    if let Err(error) = pairing_setup::setup(&provider, &bundle_id, &info.udid).await {
        fail(21, format!("{error}\nApp đã cài được giữ lại. Chạy lại chế độ 2 để sửa ghép đôi, không cần ký lại."));
    }
    println!("\nXONG: iSideload đã có file Remote Pairing, đã đọc lại và xác minh với đúng iPhone qua USB.");
    println!("Trên iPhone: tin cậy tài khoản ở Cài đặt > Cài đặt chung > VPN & Quản lý thiết bị nếu được yêu cầu.");
    println!("Mở lại iSideload, đăng nhập cùng Apple ID để gia hạn. Cài/bật LocalDevVPN rồi bấm Thiết bị > Kiểm tra kết nối thiết bị.");
    println!("Không cần xuất hay nhập file ghép đôi bằng tay. Kiểm tra LocalDevVPN thành công rồi thử Làm mới iSideload.");
}
