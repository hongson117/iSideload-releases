//! Activation check enforced inside the core (not just the UI).
//!
//! The license server (app id "isideload", codes "ISL-…") returns a signed token:
//!   base64url(payload_json) "." base64url(ed25519_signature(payload_bytes))
//! payload: {"app":"isideload","device":"<id>","exp":<unix secs>,…}
//! Only the server's PUBLIC key is in the binary, XOR-masked so it is not a plain
//! byte string. No secret lives in the IPA. Key = the LicenseKit iSideload key (XOR of its shares), re-masked here.

use serde_json::Value;

const APP_ID: &str = "isideload";
const GRACE_DAYS: f64 = 7.0;
// Ed25519 public key XOR MASK. Set PUBKEY_MASKED = key ^ MASK when the server key exists.
const MASK: [u8; 32] = [
    0x5a, 0x13, 0xc7, 0x88, 0x21, 0x9e, 0x44, 0x07, 0xb2, 0x6d, 0xf1, 0x3c, 0x90, 0x0b, 0xe5, 0x72,
    0x18, 0xaf, 0x63, 0xd4, 0x09, 0xbe, 0x57, 0x2a, 0xc1, 0x7e, 0x34, 0x99, 0x0f, 0xd8, 0x6b, 0xe3,
];
const PUBKEY_MASKED: [u8; 32] = [
    0x8b, 0x3e, 0xd2, 0x9e, 0x40, 0xec, 0xeb, 0x44, 0xf0, 0x05, 0x7b, 0x22, 0xab, 0xf4, 0x79, 0x52,
    0x1c, 0x1e, 0xce, 0xd6, 0xe4, 0x38, 0xb5, 0x87, 0x11, 0x5e, 0xad, 0x98, 0xb9, 0xde, 0x3f, 0xcf,
];

fn pubkey() -> [u8; 32] {
    let mut k = [0u8; 32];
    for i in 0..32 {
        k[i] = std::hint::black_box(PUBKEY_MASKED[i]) ^ MASK[i];
    }
    k
}

fn configured() -> bool {
    pubkey().iter().any(|b| *b != 0)
}

fn b64url(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let (mut buf, mut bits) = (0u32, 0);
    for c in s.trim_end_matches('=').bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            _ => return None,
        } as u32;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    Some(out)
}

fn verify_with(token: &str, key: &[u8; 32], device: &str, now: u64) -> Result<(), String> {
    let (p, s) = token.trim().split_once('.').ok_or("Mã kích hoạt không hợp lệ.")?;
    let (payload, sig) = (b64url(p).ok_or("Mã kích hoạt hỏng.")?, b64url(s).ok_or("Mã kích hoạt hỏng.")?);
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
        .verify(&payload, &sig)
        .map_err(|_| "Chữ ký kích hoạt không hợp lệ.".to_string())?;
    let v: Value = serde_json::from_slice(&payload).map_err(|_| "Mã kích hoạt hỏng.")?;
    if v.get("app").and_then(Value::as_str) != Some(APP_ID) {
        return Err("Mã kích hoạt không dành cho iSideload.".into());
    }
    // LicenseKit payload: {"app","device_id","exp"(ms, 0 = never),"issued_at"(ms)}
    if v.get("device_id").and_then(Value::as_str) != Some(device) || device.is_empty() {
        return Err("Giấy phép không thuộc thiết bị này.".into());
    }
    let now_ms = now as f64 * 1000.0;
    let exp = v.get("exp").and_then(Value::as_f64).unwrap_or(0.0);
    if exp > 0.0 && now_ms > exp {
        return Err("Mã kích hoạt đã hết hạn.".into());
    }
    let issued = v.get("issued_at").and_then(Value::as_f64).unwrap_or(0.0);
    if now_ms - issued > GRACE_DAYS * 86_400_000.0 {
        return Err("Cần kết nối mạng để xác minh lại giấy phép.".into());
    }
    Ok(())
}

/// Called by every sensitive op (sign-in, device, install/refresh, certs, revoke).
pub fn require(req: &Value) -> Result<(), String> {
    integrity(req)?;
    if !configured() {
        return Ok(());
    }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let token = req.get("license").and_then(Value::as_str).unwrap_or("");
    if token.is_empty() {
        return Err("iSideload chưa được kích hoạt. Nhập mã ISL-… để tiếp tục.".into());
    }
    verify_with(token, &pubkey(), req.get("device_id").and_then(Value::as_str).unwrap_or(""), now)
}

/// Integrity: the app's Info.plist ISLGitSHA must match the commit the core was built
/// from (CI sets ISL_GIT_SHA). Catches a swapped/patched core or app bundle mix.
/// (Code-signature checks are impossible: every user re-signs the IPA with their own ID.)
fn integrity(req: &Value) -> Result<(), String> {
    match option_env!("ISL_GIT_SHA") {
        Some(sha) if !sha.is_empty() => {
            let got = req.get("build_sha").and_then(Value::as_str).unwrap_or("");
            if got != sha {
                return Err("Ứng dụng đã bị chỉnh sửa (kiểm tra toàn vẹn thất bại). Hãy cài lại bản gốc.".into());
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

pub fn status() -> Value {
    serde_json::json!({"ok": true, "configured": configured(), "app": APP_ID})
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    fn enc(b: &[u8]) -> String {
        const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut s = String::new();
        for ch in b.chunks(3) {
            let n = ch.iter().enumerate().fold(0u32, |a, (i, x)| a | (*x as u32) << (16 - 8 * i));
            for i in 0..=ch.len() {
                s.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
            }
        }
        s
    }

    #[test]
    fn verifies() {
        let rng = ring::rand::SystemRandom::new();
        let kp = Ed25519KeyPair::from_pkcs8(Ed25519KeyPair::generate_pkcs8(&rng).unwrap().as_ref()).unwrap();
        let key: [u8; 32] = kp.public_key().as_ref().try_into().unwrap();
        let payload = br#"{"app":"isideload","device_id":"D1","exp":2000000000000,"issued_at":1000}"#;
        let tok = format!("{}.{}", enc(payload), enc(kp.sign(payload).as_ref()));
        assert!(verify_with(&tok, &key, "D1", 2).is_ok());
        assert!(verify_with(&tok, &key, "D2", 2).is_err());
        assert!(verify_with(&tok, &key, "D1", 1_000_000).is_err()); // beyond 7-day grace
        let bad = format!("{}.{}", enc(br#"{"app":"isideload","exp":9999999999}"#), enc(kp.sign(payload).as_ref()));
        assert!(verify_with(&bad, &key, "", 1).is_err());
        assert!(configured());
        let k = pubkey();
        assert_eq!(&k[..2], &[0xd1, 0x2d]);
    }
}
