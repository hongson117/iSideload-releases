//! This iPhone/iPad, reached through a loopback VPN (packets to 10.7.0.1 are
//! reflected back into the device) using a lockdown pairing file made once on a computer.

use std::net::IpAddr;
use std::time::Duration;

use idevice::installation_proxy::InstallationProxyClient;
use idevice::lockdown::LockdownClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::IdeviceService;

pub const DEFAULT_TARGET: &str = "10.7.0.1";

pub fn provider(target: &str, pairing_path: &str) -> Result<TcpProvider, String> {
    let target = if target.trim().is_empty() { DEFAULT_TARGET } else { target.trim() };
    let addr: IpAddr = target.parse().map_err(|_| format!("Địa chỉ VPN không hợp lệ: {target}"))?;
    let pairing_file = PairingFile::read_from_file(pairing_path).map_err(|e| {
        format!("Không đọc được file ghép nối (pairing file): {e}. Hãy nhập lại file .mobiledevicepairing/.plist.")
    })?;
    Ok(TcpProvider { addr, scope_id: None, pairing_file, label: "iSideload".into() })
}

/// Device name + UDID via an authenticated lockdown session. Also proves the VPN + pairing work.
pub async fn info(p: &TcpProvider) -> Result<(String, String, String), String> {
    let fut = async {
        let mut ld = LockdownClient::connect(p).await.map_err(|e| {
            format!("Không kết nối được lockdownd qua VPN ({e}). Bật VPN loopback (LocalDevVPN) rồi thử lại.")
        })?;
        let pf = p.get_pairing_file().await.map_err(|e| e.to_string())?;
        ld.start_session(&pf).await.map_err(|e| {
            format!("Thiết bị từ chối file ghép nối ({e}). File có thể đã cũ hoặc của máy khác — tạo lại trên máy tính.")
        })?;
        let get = |v: Result<plist::Value, idevice::IdeviceError>| {
            v.ok().and_then(|v| v.as_string().map(str::to_string)).unwrap_or_default()
        };
        let name = get(ld.get_value(Some("DeviceName"), None).await);
        let udid = get(ld.get_value(Some("UniqueDeviceID"), None).await);
        let ver = get(ld.get_value(Some("ProductVersion"), None).await);
        if udid.is_empty() {
            return Err("Thiết bị không trả về UDID.".to_string());
        }
        Ok((if name.is_empty() { "iPhone".into() } else { name }, udid, ver))
    };
    tokio::time::timeout(Duration::from_secs(15), fut)
        .await
        .map_err(|_| "Hết thời gian chờ kết nối tới 10.7.0.1. VPN loopback chưa bật?".to_string())?
}

/// User apps signed with a development certificate (i.e. sideloaded).
pub async fn sideloaded_apps(p: &TcpProvider) -> Result<Vec<serde_json::Value>, String> {
    let mut ip = InstallationProxyClient::connect(p)
        .await
        .map_err(|e| format!("Không mở được installation_proxy: {e}"))?;
    let apps = ip.get_apps(Some("User"), None).await.map_err(|e| format!("Không đọc được danh sách app: {e}"))?;
    let mut out = Vec::new();
    for (bid, v) in apps {
        let Some(d) = v.as_dictionary() else { continue };
        let g = |k: &str| d.get(k).and_then(|x| x.as_string()).unwrap_or("").to_string();
        let signer = g("SignerIdentity");
        let dev = signer.contains("Apple Development") || signer.contains("iPhone Developer");
        if !dev {
            continue;
        }
        let name = [g("CFBundleDisplayName"), g("CFBundleName")].into_iter().find(|x| !x.is_empty()).unwrap_or_default();
        out.push(serde_json::json!({
            "bundle_id": bid, "name": name, "version": g("CFBundleShortVersionString"), "signer": signer,
        }));
    }
    Ok(out)
}
