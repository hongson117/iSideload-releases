use std::time::{Duration, SystemTime, UNIX_EPOCH};
use idevice::{
    IdeviceError, IdeviceService,
    afc::{AfcClient, errors::AfcError, opcode::AfcFopenMode},
    house_arrest::HouseArrestClient,
    lockdown::LockdownClient,
    provider::IdeviceProvider,
    remote_pairing::{RemotePairingLockdownService, RpPairingFile},
};

pub const DIRECTORY: &str = "/Documents/Storage";
pub const TARGET: &str = "/Documents/Storage/pairing.plist";
const MAX_RECORD: usize = 64 * 1024;
const PLATFORM: &str = if cfg!(target_os = "macos") { "macOS" } else { "Windows" };

async fn bounded<T>(operation: impl std::future::Future<Output = Result<T, String>>) -> Result<T, String> {
    tokio::time::timeout(Duration::from_secs(30), operation).await
        .map_err(|_| "Hết thời gian phản hồi USB. Giữ iPhone mở khóa và kiểm tra cáp.".to_string())?
}

pub fn app_id_matches(id: &str) -> bool {
    id == "com.hongson117.isideload" || id.starts_with("com.hongson117.isideload.")
}

pub fn selection(text: &str, count: usize) -> Option<usize> {
    let value = text.trim().parse::<usize>().ok()?;
    (value > 0 && value <= count).then(|| value - 1)
}

fn missing(error: &IdeviceError) -> bool {
    matches!(error, IdeviceError::Afc(AfcError::ObjectNotFound))
}

/// Keep the transfer transaction testable with interrupted USB connections.
trait Files {
    async fn read(&mut self, path: &str) -> Result<Option<Vec<u8>>, String>;
    async fn write(&mut self, path: &str, data: &[u8]) -> Result<(), String>;
    async fn rename(&mut self, from: &str, to: &str) -> Result<(), String>;
    async fn remove(&mut self, path: &str) -> Result<(), String>;
}

impl Files for AfcClient {
    async fn read(&mut self, path: &str) -> Result<Option<Vec<u8>>, String> {
        bounded(async {
        let info = match self.get_file_info(path).await {
            Ok(info) => info,
            Err(error) if missing(&error) => return Ok(None),
            Err(error) => return Err(format!("Không đọc được thông tin file ghép đôi: {error}")),
        };
        if info.size > MAX_RECORD { return Err("File ghép đôi lớn bất thường; chưa thay file trên iPhone.".into()); }
        let mut file = self.open(path, AfcFopenMode::RdOnly).await.map_err(|e| e.to_string())?;
        let data = file.read_n(info.size).await;
        let closed = file.close().await;
        let data = data.map_err(|e| e.to_string())?;
        closed.map_err(|e| e.to_string())?;
        if data.len() != info.size { return Err("Đọc file ghép đôi chưa đủ dữ liệu.".into()); }
        Ok(Some(data))
        }).await
    }
    async fn write(&mut self, path: &str, data: &[u8]) -> Result<(), String> {
        bounded(async {
        let mut file = self.open(path, AfcFopenMode::WrOnly).await.map_err(|e| e.to_string())?;
        let written = file.write_entire(data).await;
        let closed = file.close().await;
        written.map_err(|e| e.to_string())?;
        closed.map_err(|e| e.to_string())
        }).await
    }
    async fn rename(&mut self, from: &str, to: &str) -> Result<(), String> {
        bounded(async { AfcClient::rename(self, from, to).await.map_err(|e| e.to_string()) }).await
    }
    async fn remove(&mut self, path: &str) -> Result<(), String> {
        bounded(async { match AfcClient::remove(self, path).await {
            Ok(()) => Ok(()),
            Err(error) if missing(&error) => Ok(()),
            Err(error) => Err(error.to_string()),
        } }).await
    }
}

async fn replace_record(files: &mut impl Files, data: &[u8], nonce: &str) -> Result<(), String> {
    let old = files.read(TARGET).await?;
    if old.as_deref() == Some(data) { return Ok(()); }
    let temporary = format!("{DIRECTORY}/pairing-installer-{nonce}.tmp");
    let backup = format!("{DIRECTORY}/pairing-before-installer-{nonce}.plist");
    files.write(&temporary, data).await?;
    if files.read(&temporary).await?.as_deref() != Some(data) {
        let _ = files.remove(&temporary).await;
        return Err("Bản chép thử không khớp; file ghép đôi cũ chưa bị thay.".into());
    }
    if old.is_some() { files.rename(TARGET, &backup).await?; }
    if let Err(error) = files.rename(&temporary, TARGET).await {
        if old.is_some() && files.rename(&backup, TARGET).await.is_err() {
            return Err(format!("USB bị ngắt khi thay file. Giữ bản sao trong {backup}; kết nối lại và chạy chế độ sửa ghép đôi. {error}"));
        }
        return Err(format!("Chưa thay được file ghép đôi; đã giữ bản cũ. {error}"));
    }
    let readback = files.read(TARGET).await;
    if !matches!(readback, Ok(Some(ref bytes)) if bytes == data) {
        let removed = files.remove(TARGET).await;
        let restored = if old.is_some() { files.rename(&backup, TARGET).await } else { removed };
        if restored.is_err() {
            return Err(format!("Không kiểm chứng được file mới. Giữ bản sao cũ trong {backup}; kết nối lại USB để sửa ghép đôi."));
        }
        return Err("File mới đọc lại không khớp; đã khôi phục trạng thái trước đó.".into());
    }
    if old.is_some() {
        files.remove(&backup).await.map_err(|_| format!("File mới đã được chép, nhưng chưa dọn được bản sao trong {backup}. Kết nối lại để kiểm tra."))?;
    }
    Ok(())
}

async fn verify_device(provider: &impl IdeviceProvider, expected: &str) -> Result<(), String> {
    bounded(async {
    let info = isideload::util::device::IdeviceInfo::from_device(provider).await.map_err(|e| e.to_string())?;
    if info.udid != expected { return Err("Thiết bị USB đã thay đổi. Chưa chép file ghép đôi.".into()); }
    Ok(())
    }).await
}

async fn verify_record(provider: &impl IdeviceProvider, record: &mut RpPairingFile) -> Result<(), String> {
    bounded(async {
    let service = RemotePairingLockdownService::connect(provider).await.map_err(|e| e.to_string())?;
    let mut client = service.into_client(&format!("iSideload {PLATFORM}")).map_err(|e| e.to_string())?;
    client.attempt_pair_verify().await.map_err(|e| e.to_string())?;
    client.validate_pairing(record).await.map_err(|e| e.to_string())
    }).await
}

/// Prepare the daemon's network listener through the already-trusted USB session.
/// Creating a record over USB alone does not check this independent device setting.
async fn prepare_wireless(provider: &impl IdeviceProvider, expected: &str) -> Result<(), String> {
    bounded(async {
        let mut lockdown = LockdownClient::connect(provider).await.map_err(|e| e.to_string())?;
        let pairing = provider.get_pairing_file().await.map_err(|e| e.to_string())?;
        lockdown.start_session(&pairing).await.map_err(|e| e.to_string())?;
        let udid = lockdown.get_value(Some("UniqueDeviceID"), None).await.map_err(|e| e.to_string())?;
        if udid.as_string() != Some(expected) { return Err("Thiết bị USB đã thay đổi; chưa sửa cấu hình kết nối.".into()); }
        let domain = Some("com.apple.mobile.wireless_lockdown");
        let current = lockdown.get_value(Some("EnableWifiDebugging"), domain).await.ok();
        if current.as_ref().and_then(|v| v.as_boolean()) != Some(true) {
            println!("Đang chuẩn bị kết nối phát triển qua Wi-Fi cho iPhone đã Tin cậy…");
            lockdown.set_value("EnableWifiDebugging", plist::Value::Boolean(true), domain)
                .await.map_err(|e| format!("Chưa bật được kết nối phát triển qua Wi-Fi: {e}"))?;
        }
        let confirmed = lockdown.get_value(Some("EnableWifiDebugging"), domain).await
            .map_err(|e| format!("Không xác nhận được cấu hình Wi-Fi: {e}"))?;
        if confirmed.as_boolean() != Some(true) {
            return Err("iPhone chưa xác nhận cho phép kết nối phát triển qua Wi-Fi; chưa báo hoàn tất ghép đôi.".into());
        }
        Ok(())
    }).await
}

pub async fn setup(provider: &impl IdeviceProvider, bundle_id: &str, udid: &str) -> Result<(), String> {
    if !app_id_matches(bundle_id) { return Err("Ứng dụng nhận không phải iSideload.".into()); }
    verify_device(provider, udid).await?;
    prepare_wireless(provider, udid).await?;
    let mut afc = bounded(async {
        HouseArrestClient::connect(provider).await.map_err(|e| format!("Không mở được thư mục iSideload qua USB: {e}"))?
            .vend_documents(bundle_id).await.map_err(|e| format!("Không truy cập được iSideload vừa cài: {e}. Giữ máy mở khóa và đóng hẳn iSideload rồi chạy lại chế độ sửa ghép đôi."))
    }).await?;
    bounded(async { match afc.get_file_info(DIRECTORY).await {
        Ok(info) if info.st_ifmt == "S_IFDIR" => (),
        Ok(_) => return Err("Storage của iSideload không phải thư mục; chưa thay dữ liệu.".into()),
        Err(error) if missing(&error) => afc.mk_dir(DIRECTORY).await.map_err(|e| e.to_string())?,
        Err(error) => return Err(format!("Không mở được Storage của iSideload: {error}")),
    } Ok(()) }).await?;
    let old = Files::read(&mut afc, TARGET).await?;
    let mut record = if let Some(mut candidate) = old.as_deref().and_then(|bytes| RpPairingFile::from_bytes(bytes).ok()) {
        if tokio::time::timeout(Duration::from_secs(20), verify_record(provider, &mut candidate)).await.is_ok_and(|r| r.is_ok()) {
            println!("Bản ghi hiện có vẫn được iPhone chấp nhận; dùng lại quyền này.");
            Some(candidate)
        } else { None }
    } else { None };
    if record.is_none() {
        println!("Đang tạo Remote Pairing qua kết nối USB đã được Tin cậy…");
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?.as_nanos();
        let host = format!("iSideload {PLATFORM} {nonce:x}");
        let mut created = RpPairingFile::generate(&host);
        // A second fresh control connection commits/reuses the saved identity,
        // matching upstream idevice_pair's USB onboarding flow.
        for _ in 0..2 {
            bounded(async {
            let service = RemotePairingLockdownService::connect(provider).await.map_err(|e| format!("Không mở được Remote Pairing qua USB: {e}"))?;
            let mut client = service.into_client(&host).map_err(|e| e.to_string())?;
            client.connect(&mut created, || async { "000000".to_string() }).await.map_err(|e| format!("Chưa tạo được Remote Pairing: {e}"))?;
            Ok(())
            }).await?;
        }
        record = Some(created);
    }
    let mut record = record.ok_or("Chưa tạo được bản ghi ghép đôi.")?;
    verify_record(provider, &mut record).await.map_err(|e| format!("iPhone chưa chấp nhận bản ghi mới: {e}. Chưa thay file cũ trong app."))?;
    verify_device(provider, udid).await?;
    let bytes = record.to_bytes();
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?.as_nanos();
    println!("Đang chép file ghép đôi vào iSideload và đọc lại để kiểm chứng…");
    replace_record(&mut afc, &bytes, &format!("{nonce:x}")).await?;
    // Verify the exact bytes read back from the app, on a fresh USB control connection.
    let readback = Files::read(&mut afc, TARGET).await?.ok_or("Không thấy file ghép đôi sau khi chép.")?;
    let mut received = RpPairingFile::from_bytes(&readback).map_err(|_| "File ghép đôi đọc lại không hợp lệ.")?;
    verify_record(provider, &mut received).await.map_err(|e| format!("File đã chép nhưng bước xác minh cuối chưa thành công: {e}. Chạy lại chế độ sửa ghép đôi."))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct FakeFiles { files: HashMap<String, Vec<u8>>, fail_commit: bool, corrupt_stage: bool, corrupt_final: bool }
    impl Files for FakeFiles {
        async fn read(&mut self, path: &str) -> Result<Option<Vec<u8>>, String> { Ok(self.files.get(path).cloned()) }
        async fn write(&mut self, path: &str, bytes: &[u8]) -> Result<(), String> {
            self.files.insert(path.into(), if self.corrupt_stage { b"truncated".to_vec() } else { bytes.to_vec() }); Ok(())
        }
        async fn rename(&mut self, from: &str, to: &str) -> Result<(), String> {
            if self.fail_commit && from.ends_with(".tmp") { return Err("simulated USB disconnect".into()); }
            let mut data = self.files.remove(from).ok_or("missing source")?;
            if self.corrupt_final && from.ends_with(".tmp") { data = b"wrong".to_vec(); }
            self.files.insert(to.into(), data); Ok(())
        }
        async fn remove(&mut self, path: &str) -> Result<(), String> { self.files.remove(path); Ok(()) }
    }
    #[tokio::test]
    async fn verified_transfer_and_repair_keep_other_app_data() {
        let mut fs = FakeFiles::default();
        fs.files.insert("/Documents/Storage/apps.json".into(), b"apps".to_vec());
        replace_record(&mut fs, b"new", "test").await.unwrap();
        assert_eq!(fs.files[TARGET], b"new");
        replace_record(&mut fs, b"newer", "again").await.unwrap();
        assert_eq!(fs.files[TARGET], b"newer");
        assert_eq!(fs.files["/Documents/Storage/apps.json"], b"apps");
        assert_eq!(fs.files.len(), 2);
    }
    #[tokio::test]
    async fn corrupted_staging_never_replaces_existing_record() {
        let mut fs = FakeFiles { corrupt_stage: true, ..Default::default() };
        fs.files.insert(TARGET.into(), b"old".to_vec());
        assert!(replace_record(&mut fs, b"new", "test").await.is_err());
        assert_eq!(fs.files[TARGET], b"old");
    }
    #[tokio::test]
    async fn interrupted_commit_restores_old_record() {
        let mut fs = FakeFiles { fail_commit: true, ..Default::default() };
        fs.files.insert(TARGET.into(), b"old".to_vec());
        assert!(replace_record(&mut fs, b"new", "test").await.is_err());
        assert_eq!(fs.files[TARGET], b"old");
    }
    #[tokio::test]
    async fn failed_final_readback_restores_old_record() {
        let mut fs = FakeFiles { corrupt_final: true, ..Default::default() };
        fs.files.insert(TARGET.into(), b"old".to_vec());
        assert!(replace_record(&mut fs, b"new", "test").await.is_err());
        assert_eq!(fs.files[TARGET], b"old");
    }
    #[test]
    fn app_selection_never_accepts_similar_names_or_paths() {
        assert!(app_id_matches("com.hongson117.isideload"));
        assert!(app_id_matches("com.hongson117.isideload.TESTTEAM01"));
        for id in ["com.hongson117.isideload2", "com.example.other", "../../Storage", ""] { assert!(!app_id_matches(id)); }
        assert_eq!(selection("2", 2), Some(1));
        for input in ["0", "3", "-1", "", "invalid"] { assert_eq!(selection(input, 2), None); }
    }
}
