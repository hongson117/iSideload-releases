//! First-install USB tool for macOS. Uses Apple's /var/run/usbmuxd, no Homebrew daemon.
use std::{io::Write, path::{Path, PathBuf}};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{certificates::DevelopmentCertificate, developer_session::DeveloperSession,
          device_type::DeveloperDeviceType, devices::DevicesApi},
    sideload::builder::{MaxCertsBehavior, SideloaderBuilder},
    util::{callbacks::MaxCertsCallbackFuture, fs_storage::FsStorage},
};
use idevice::usbmuxd::{Connection, UsbmuxdAddr};
use rootcause::Report;

const ANISETTE: &[&str] = &["https://ani.jkcoxson.com", "https://mac-ani.jkcoxson.com", "https://ani.npeg.us", "https://ani.sidestore.io"];

fn prompt(message: &str) -> String {
    print!("{message}"); let _ = std::io::stdout().flush();
    let mut line = String::new(); let _ = std::io::stdin().read_line(&mut line);
    line.trim().to_string()
}

fn selection(input: &str, count: usize) -> Option<usize> {
    let value = input.trim().parse::<usize>().ok()?;
    (value > 0 && value <= count).then(|| value - 1)
}

fn storage_path(home: &Path) -> PathBuf {
    home.join("Library/Application Support/iSideload-Installer")
}

fn fail(code: i32, message: impl std::fmt::Display) -> ! {
    eprintln!("\nLỖI: {message}"); std::process::exit(code)
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
        println!("Đang xác thực với Apple qua anisette {url}…");
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
        let certs: Vec<_> = certs.into_iter().filter(|cert| cert.serial_number.as_deref().is_some_and(|serial| !serial.is_empty())).collect();
        if certs.is_empty() {
            eprintln!("Apple không trả về chứng chỉ có serial hợp lệ để chọn; chưa thu hồi chứng chỉ nào.");
            return Ok(None);
        }
        println!("\nApple báo hết chỗ cấp chứng chỉ phát triển.");
        for (index, cert) in certs.iter().enumerate() {
            println!("  {}. {} — {}", index + 1,
                     cert.machine_name.as_deref().or(cert.name.as_deref()).unwrap_or("Không rõ thiết bị"),
                     cert.serial_number.as_deref().unwrap_or(""));
        }
        println!("Thu hồi chứng chỉ có thể khiến các app đã ký bằng nó ngừng mở.");
        let answer = prompt("Chọn đúng MỘT số để thu hồi; Enter để hủy mà không thay đổi: ");
        let Some(index) = selection(&answer, certs.len()) else { return Ok(None); };
        if prompt("Xác nhận thu hồi chứng chỉ đã chọn? Gõ THU HOI: ") != "THU HOI" { return Ok(None); }
        Ok(certs[index].serial_number.clone().map(|serial| vec![serial]))
    })
}

#[tokio::main]
async fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        Some("--help") | Some("-h") => {
            println!("iSideload Mac Installer\nUsage: isl-mac [iSideload.ipa]\n       isl-mac --list-devices\n       isl-mac --self-test\nCắm iPhone bằng USB, mở Finder, xác nhận Tin cậy trước khi cài.");
            return;
        }
        Some("--version") => { println!("iSideload Mac Installer 1.2.1 ({})", option_env!("ISL_GIT_SHA").unwrap_or("local")); return; }
        Some("--self-test") => {
            assert_eq!(selection("1", 2), Some(0)); assert_eq!(selection("2", 2), Some(1));
            for text in ["", "0", "3", "-1", "invalid"] { assert_eq!(selection(text, 2), None); }
            assert_eq!(storage_path(Path::new("/Users/test")), PathBuf::from("/Users/test/Library/Application Support/iSideload-Installer"));
            assert!(matches!(UsbmuxdAddr::default(), UsbmuxdAddr::UnixSocket(ref path) if path == "/var/run/usbmuxd"));
            println!("Self-test passed: bounded device/certificate selection; private macOS cache path; native Apple USB socket.");
            return;
        }
        Some(option) if option.starts_with('-') && option != "--list-devices" => fail(2, "Tùy chọn không hợp lệ. Dùng --help để xem hướng dẫn."),
        _ => {}
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    let addr = UsbmuxdAddr::default();
    let mut mux = addr.connect(0).await.unwrap_or_else(|error| fail(3, format!("Không kết nối được dịch vụ USB của macOS ({error}). Mở Finder, cắm cáp dữ liệu và mở khóa iPhone. Không cần cài usbmuxd bằng Homebrew.")));
    let devices: Vec<_> = mux.get_devices().await.unwrap_or_else(|error| fail(3, error))
        .into_iter().filter(|device| matches!(device.connection_type, Connection::Usb)).collect();
    if devices.is_empty() { fail(4, "Không thấy iPhone/iPad qua USB. Kiểm tra cáp dữ liệu, mở Finder, bấm Trust/Tin cậy và mở khóa máy."); }
    for (index, device) in devices.iter().enumerate() { println!("  {}. iPhone/iPad USB — {}", index + 1, device.udid); }
    if arguments.first().map(String::as_str) == Some("--list-devices") { return; }
    let index = if devices.len() == 1 { 0 } else {
        selection(&prompt("Có nhiều máy. Chọn số máy muốn cài: "), devices.len()).unwrap_or_else(|| fail(4, "Chưa chọn máy hợp lệ; chưa cài hay ký app."))
    };
    let provider = devices[index].clone().to_provider(addr, "iSideload-macOS");
    let info = isideload::util::device::IdeviceInfo::from_device(&provider).await
        .unwrap_or_else(|error| fail(5, format!("Chưa có kết nối tin cậy ({error}). Chọn iPhone trong Finder, bấm Trust trên Mac và Tin cậy trên iPhone rồi thử lại.")));
    println!("Máy nhận: {} ({})", info.name, info.udid);
    let ipa = arguments.first().map(PathBuf::from).unwrap_or_else(|| std::env::current_exe().unwrap().parent().unwrap().join("iSideload.ipa"));
    if !ipa.is_file() { fail(2, "Không thấy iSideload.ipa. Giải nén đầy đủ bộ cài, giữ IPA cạnh isl-mac."); }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| fail(2, "Không xác định được thư mục người dùng macOS."));
    let storage = storage_path(&home);
    std::fs::create_dir_all(&storage).unwrap_or_else(|error| fail(2, error));
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&storage, std::fs::Permissions::from_mode(0o700)).unwrap_or_else(|error| fail(2, error));
    let id = prompt("Apple ID dùng để ký và gia hạn trên iPhone (email): ");
    let password = rpassword::prompt_password("Mật khẩu Apple ID (ẩn khi nhập): ").unwrap_or_default();
    if id.is_empty() || password.is_empty() { fail(1, "Thiếu Apple ID hoặc mật khẩu."); }
    let mut account = login(&storage, &id, &password).await.unwrap_or_else(|error| fail(10, format!("Đăng nhập Apple thất bại: {error}")));
    drop(password);
    let developer = DeveloperSession::from_account(&mut account).await.unwrap_or_else(|error| fail(11, error));
    let mut signer = SideloaderBuilder::new(developer, id).storage(Box::new(FsStorage::new(storage)))
        .machine_name("iSideload macOS".into()).max_certs_behavior(MaxCertsBehavior::Prompt(revoke_prompt)).build();
    signer.set_device_type(Some(DeveloperDeviceType::Ios));
    let team = signer.get_team().await.unwrap_or_else(|error| fail(12, format!("Không lấy được nhóm phát triển: {error}. Nếu là tài khoản mới, kiểm tra điều khoản trên developer.apple.com.")));
    signer.get_dev_session().ensure_device_registered(&team, &info.name, &info.udid, Some(DeveloperDeviceType::Ios)).await
        .unwrap_or_else(|error| fail(13, error));
    let progress = |value: f32| async move { print!("\rĐang ký app: {:.0}%   ", value * 100.0); let _ = std::io::stdout().flush(); };
    let (signed, _) = signer.sign_app(ipa, Some(team), false, Some(progress), None, Some(&info.udid)).await.unwrap_or_else(|error| fail(14, error));
    println!("\nĐang cài iSideload lên {} qua USB…", info.name);
    let result = isideload::sideload::install::install_app(&provider, &signed, |value| { print!("\rCài: {value}%   "); let _ = std::io::stdout().flush(); }).await;
    let _ = std::fs::remove_dir_all(&signed);
    if let Err(error) = result { fail(16, format!("Cài chưa hoàn tất: {error}")); }
    println!("\n\nXONG! Trên iPhone: bật Chế độ nhà phát triển, tin cậy tài khoản ở Cài đặt > Cài đặt chung > VPN & Quản lý thiết bị, rồi mở iSideload.");
    println!("Trong iSideload, làm theo Thiết lập lần đầu để tự gia hạn. Có thể rút cáp sau khi hoàn tất.");
}
