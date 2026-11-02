//! Pair another iPhone on the LAN without touching this phone's own identity.
use std::{collections::HashMap, net::IpAddr, path::PathBuf, sync::{Mutex, OnceLock}, time::Duration};
use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use serde_json::{json, Value};
use tokio::sync::watch;
use crate::{bridge::Ui, ops::s};

type Sessions = Mutex<HashMap<String, watch::Sender<bool>>>;
fn sessions() -> &'static Sessions {
    static SESSIONS: OnceLock<Sessions> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn session_id(req: &Value) -> Result<&str, String> {
    let id = s(req, "session_id");
    if !(16..=64).contains(&id.len()) || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err("Phiên ghép nối không hợp lệ.".into());
    }
    Ok(id)
}

pub fn pairing_path(req: &Value) -> Result<PathBuf, String> {
    Ok(PathBuf::from(s(req, "storage_dir")).join("peer-pairings").join(format!("{}.plist", session_id(req)?)))
}

fn local_target(ip: IpAddr) -> Result<IpAddr, String> {
    match ip {
        IpAddr::V4(v) if v.is_private() || v.is_link_local() => Ok(ip),
        _ => Err("Máy nhận phải ở cùng mạng Wi-Fi, dùng địa chỉ IPv4 cục bộ.".into()),
    }
}

struct SessionGuard(String);
impl Drop for SessionGuard {
    fn drop(&mut self) {
        if let Ok(mut map) = sessions().lock() { map.remove(&self.0); }
    }
}

pub fn cancel(req: &Value) -> Result<Value, String> {
    let id = session_id(req)?.to_string();
    let mut map = sessions().lock().map_err(|_| "Không mở được phiên ghép nối.")?;
    if let Some(sender) = map.get(&id) {
        sender.send_replace(true);
    } else {
        // Cancellation may arrive before the background call has registered.
        if map.len() >= 32 { return Err("Quá nhiều phiên ghép nối.".into()); }
        map.insert(id, watch::channel(true).0);
    }
    Ok(json!({"ok": true}))
}

pub async fn pair(req: &Value, ui: Ui) -> Result<Value, String> {
    let id = session_id(req)?.to_string();
    let path = pairing_path(req)?;
    let mut cancelled = {
        let mut map = sessions().lock().map_err(|_| "Không mở được phiên ghép nối.")?;
        if map.len() >= 32 && !map.contains_key(&id) { return Err("Quá nhiều phiên ghép nối.".into()); }
        map.entry(id.clone()).or_insert_with(|| watch::channel(false).0).subscribe()
    };
    let _guard = SessionGuard(id.clone());
    let work = async {
        let listener = tokio::net::TcpListener::bind(("0.0.0.0", 0)).await.map_err(|e| e.to_string())?;
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();
        // Unique host identity; never the name used by host_pairing for this phone.
        let host_name = format!("iSideload - Cai may khac {}", &id[..8]);
        let mut identity = RpPairingFile::generate(&host_name);
        let info = PairableHostInfo::generate(&host_name, "Mac17,7");
        let service = identity.identifier().to_string();
        let txt: serde_json::Map<String, Value> = info.mdns_txt_records(&service)
            .into_iter().map(|(k, v)| (k, Value::String(v))).collect();
        ui.event(json!({"advertise": {"port": port, "name": service, "host_name": host_name, "txt": txt}}));
        ui.progress("Trên máy nhận: mở Chế độ nhà phát triển, chọn tên ghép nối bên dưới.", None);
        let (stream, addr) = listener.accept().await.map_err(|e| e.to_string())?;
        let ip = local_target(addr.ip())?;
        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info);
        let peer = host.accept(&mut identity, |pin| async move { ui.event(json!({"pin": pin})); })
            .await.map_err(|e| format!("Ghép nối máy nhận thất bại: {e}"))?;
        if !peer.model.starts_with("iPhone") && !peer.model.starts_with("iPad") {
            return Err("Thiết bị nhận không phải iPhone/iPad.".into());
        }
        if peer.remotepairing_udid.is_empty() { return Err("Máy nhận không trả về UDID.".into()); }
        std::fs::create_dir_all(path.parent().ok_or("Thiếu thư mục ghép nối.")?).map_err(|e| e.to_string())?;
        identity.write_to_file(&path).await.map_err(|e| e.to_string())?;
        Ok(json!({"ok": true, "ip": ip.to_string(), "udid": peer.remotepairing_udid,
                  "name": peer.name, "model": peer.model}))
    };
    tokio::select! {
        biased;
        _ = cancelled.wait_for(|v| *v) => Err("Đã hủy ghép nối máy nhận.".into()),
        result = tokio::time::timeout(Duration::from_secs(300), work) => {
            result.map_err(|_| "Hết 5 phút chờ máy nhận. Bắt đầu lại để nhận mã mới.".to_string())?
        }
    }
}

/// Lock the install to both the record and UDID approved on the pairing screen.
pub fn install_request(req: &Value) -> Result<Value, String> {
    let path = pairing_path(req)?;
    if !path.is_file() { return Err("Chưa ghép nối máy nhận. Hãy ghép nối trước.".into()); }
    let ip = s(req, "target").parse::<IpAddr>().map_err(|_| "Địa chỉ máy nhận không hợp lệ.")?;
    local_target(ip)?;
    if s(req, "expected_udid").is_empty() { return Err("Thiếu UDID của máy nhận.".into()); }
    let mut request = req.clone();
    request["pairing_path"] = json!(path.to_string_lossy());
    request["use_imported_cert"] = json!(false);
    request["ota"] = json!(false);
    Ok(request)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn peer_records_cannot_overwrite_self_or_escape_storage() {
        let req = json!({"storage_dir": "/tmp/isl", "session_id": "01234567-89ab-cdef"});
        assert_eq!(pairing_path(&req).unwrap(), PathBuf::from("/tmp/isl/peer-pairings/01234567-89ab-cdef.plist"));
        for id in ["../../pairing", "0123456789abcdef/../../pairing", ""] {
            assert!(pairing_path(&json!({"storage_dir": "/tmp/isl", "session_id": id})).is_err());
        }
    }
    #[test]
    fn peer_target_excludes_loopback_and_internet() {
        for ip in ["192.168.1.42", "10.0.0.2", "172.16.0.5", "169.254.1.2"] {
            assert!(local_target(ip.parse().unwrap()).is_ok());
        }
        for ip in ["127.0.0.1", "8.8.8.8", "0.0.0.0", "224.0.0.251", "::1"] {
            assert!(local_target(ip.parse().unwrap()).is_err());
        }
    }
    #[tokio::test]
    async fn cancellation_before_pair_starts_stops_without_touching_self_record() {
        let req = json!({"storage_dir": "/unused", "session_id": "cancel-before-start-1234"});
        cancel(&req).unwrap();
        let error = pair(&req, Ui::new(None, None, std::ptr::null_mut())).await.unwrap_err();
        assert!(error.contains("hủy"));
        assert!(!sessions().lock().unwrap().contains_key("cancel-before-start-1234"));
    }

    #[tokio::test]
    async fn cancel_closes_a_waiting_listener_and_allows_a_new_session() {
        let req = json!({"storage_dir": "/unused", "session_id": "cancel-waiting-session-1234"});
        let job_req = req.clone();
        let job = tokio::spawn(async move { pair(&job_req, Ui::new(None, None, std::ptr::null_mut())).await });
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if sessions().lock().unwrap().contains_key("cancel-waiting-session-1234") { break; }
                tokio::task::yield_now().await;
            }
        }).await.unwrap();
        cancel(&req).unwrap();
        let result = tokio::time::timeout(Duration::from_secs(2), job).await.unwrap().unwrap();
        assert!(result.unwrap_err().contains("hủy"));
        assert!(!sessions().lock().unwrap().contains_key("cancel-waiting-session-1234"));
    }
}
