//! iContainer's bounded arm64 loader preparation. Written for this project;
//! no LiveContainer loader or ZSign sources are used here.

fn u32le(b: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(b.get(at..at + 4).ok_or("Truncated Mach-O")?.try_into().unwrap()))
}
fn u64le(b: &[u8], at: usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(b.get(at..at + 8).ok_or("Truncated Mach-O")?.try_into().unwrap()))
}
fn set32(b: &mut [u8], at: usize, n: u32) { b[at..at + 4].copy_from_slice(&n.to_le_bytes()); }

pub fn thin_arm64(bytes: &[u8]) -> Result<Vec<u8>, String> {
    if bytes.starts_with(&[0xcf, 0xfa, 0xed, 0xfe]) {
        if u32le(bytes, 4)? != 0x0100000c { return Err("IPA không dành cho arm64.".into()); }
        // arm64e binaries require a separate pointer-authentication implementation.
        if u32le(bytes, 8)? & 0x00ffffff != 0 { return Err("Bản thử chưa hỗ trợ arm64e.".into()); }
        return Ok(bytes.to_vec());
    }
    let wide = bytes.starts_with(&[0xca, 0xfe, 0xba, 0xbf]);
    if !wide && !bytes.starts_with(&[0xca, 0xfe, 0xba, 0xbe]) { return Err("Không phải Mach-O arm64.".into()); }
    let be32 = |at| -> Result<u32, String> { Ok(u32::from_be_bytes(bytes.get(at..at+4).ok_or("Truncated fat header")?.try_into().unwrap())) };
    let be64 = |at| -> Result<u64, String> { Ok(u64::from_be_bytes(bytes.get(at..at+8).ok_or("Truncated fat header")?.try_into().unwrap())) };
    let count = be32(4)? as usize;
    if count == 0 || count > 32 { return Err("Invalid fat architecture count".into()); }
    for i in 0..count {
        let at = 8 + i * if wide { 32 } else { 20 };
        if be32(at)? == 0x0100000c && be32(at+4)? & 0x00ffffff == 0 {
            let (offset, size) = if wide { (be64(at+8)?, be64(at+16)?) } else { (be32(at+8)? as u64, be32(at+12)? as u64) };
            let end = offset.checked_add(size).ok_or("Fat offset overflow")?;
            if end > bytes.len() as u64 { return Err("Fat slice outside file".into()); }
            return thin_arm64(&bytes[offset as usize..end as usize]);
        }
    }
    Err("Không có slice arm64 thường trong IPA.".into())
}

pub fn commands(b: &[u8]) -> Result<Vec<(u32, usize, usize)>, String> {
    if b.len() < 32 { return Err("Truncated Mach-O header".into()); }
    let end = 32usize.checked_add(u32le(b, 20)? as usize).ok_or("Command overflow")?;
    if end > b.len() { return Err("Load commands outside file".into()); }
    let count = u32le(b, 16)? as usize;
    if count > 65536 { return Err("Too many load commands".into()); }
    let mut at = 32;
    let mut out = Vec::new();
    for _ in 0..count {
        let cmd = u32le(b, at)?;
        let size = u32le(b, at+4)? as usize;
        if size < 8 || size % 8 != 0 || at.checked_add(size).filter(|n| *n <= end).is_none() { return Err("Malformed load command".into()); }
        out.push((cmd, at, size)); at += size;
    }
    if at != end { return Err("Load command size mismatch".into()); }
    Ok(out)
}

pub fn signature_contains(b: &[u8], certificate: &[u8]) -> Result<bool, String> {
    let b = thin_arm64(b)?;
    for (cmd, at, size) in commands(&b)? {
        if cmd == 0x1d && size >= 16 {
            let off = u32le(&b, at+8)? as usize;
            let len = u32le(&b, at+12)? as usize;
            let end = off.checked_add(len).ok_or("Signature overflow")?;
            let sig = b.get(off..end).ok_or("Signature outside file")?;
            // Restrict the comparison to the CMS wrapper, not resources/profile.
            if sig.len() < 12 || sig[..4] != [0xfa,0xde,0x0c,0xc0] { return Ok(false); }
            let n = u32::from_be_bytes(sig[8..12].try_into().unwrap()) as usize;
            if n > 128 || 12 + n*8 > sig.len() { return Err("Malformed signature index".into()); }
            for i in 0..n {
                let slot = 12+i*8;
                if u32::from_be_bytes(sig[slot..slot+4].try_into().unwrap()) != 0x10000 { continue; }
                let p = u32::from_be_bytes(sig[slot+4..slot+8].try_into().unwrap()) as usize;
                let hdr = sig.get(p..p+8).ok_or("Truncated CMS wrapper")?;
                if hdr[..4] != [0xfa,0xde,0x0b,0x01] { return Ok(false); }
                let size = u32::from_be_bytes(hdr[4..8].try_into().unwrap()) as usize;
                if size < 8 { return Err("Invalid CMS length".into()); }
                let cms = sig.get(p+8..p.checked_add(size).ok_or("CMS overflow")?).ok_or("CMS outside signature")?;
                return Ok(!certificate.is_empty() && cms.windows(certificate.len()).any(|w| w == certificate));
            }
        }
    }
    Ok(false)
}

fn string_command(cmd: u32, prefix: usize, value: &str) -> Vec<u8> {
    let size = (prefix + value.len() + 1 + 7) & !7;
    let mut c = vec![0u8; size];
    set32(&mut c, 0, cmd); set32(&mut c, 4, size as u32); set32(&mut c, 8, prefix as u32);
    c[prefix..prefix+value.len()].copy_from_slice(value.as_bytes()); c
}

/// Return the original LC_MAIN entry offset. Preserve file/VM layout; refuse
/// insufficient header padding instead of shifting executable sections.
pub fn prepare(bytes: &[u8], main: bool) -> Result<(Vec<u8>, Option<u64>), String> {
    let mut b = thin_arm64(bytes)?;
    let cmds = commands(&b)?;
    let mut capacity = b.len();
    let mut entry = None;
    let mut out = Vec::new();
    for &(cmd, at, size) in &cmds {
        if cmd == 0x2c {
            if size < 24 { return Err("Truncated encryption command".into()); }
            if u32le(&b, at+16)? != 0 { return Err("IPA còn mã hóa App Store. Cần IPA không mã hóa do bạn có quyền sử dụng.".into()); }
        }
        if cmd == 0x32 && (size < 24 || u32le(&b, at+8)? != 2) { return Err("Mach-O không dành cho thiết bị iOS.".into()); }
        if [0x24, 0x2f, 0x30].contains(&cmd) { return Err("Mach-O dành cho nền tảng khác.".into()); }
        if cmd == 0x19 {
            if size < 72 { return Err("Truncated segment".into()); }
            let nsects = u32le(&b, at+64)? as usize;
            if 72 + nsects*80 > size { return Err("Truncated sections".into()); }
            for n in 0..nsects {
                let section = at+72+n*80;
                let off = u32le(&b, section+48)? as usize;
                if off != 0 { capacity = capacity.min(off); }
            }
            let fileoff = u64le(&b, at+40)?;
            if fileoff > 0 { capacity = capacity.min(fileoff as usize); }
        }
        if cmd == 0x80000028 {
            if size < 24 { return Err("Truncated LC_MAIN".into()); }
            entry = Some(u64le(&b, at+8)?);
            if main { continue; }
        }
        if main && [0xe, 0x27, 0xd].contains(&cmd) { continue; }
        let mut c = b[at..at+size].to_vec();
        if main && cmd == 0x19 && c.get(8..18) == Some(b"__PAGEZERO") {
            // A dylib must not reserve the executable's 4 GiB page-zero range.
            c[24..40].fill(0);
        }
        if [0xc, 0x18|0x80000000, 0x1f|0x80000000, 0x20, 0x23|0x80000000, 0x8000001c].contains(&cmd) {
            let prefix = if cmd == 0x8000001c { 12 } else { 24 };
            let p = u32le(&c, 8)? as usize;
            let raw = c.get(p..).ok_or("Invalid dylib path offset")?;
            let name = std::str::from_utf8(raw.split(|v| *v==0).next().unwrap_or_default()).map_err(|_| "Invalid dylib path")?;
            if let Some(tail) = name.strip_prefix("@executable_path/") {
                if main {
                    let rewritten = string_command(cmd, prefix, &format!("@loader_path/{tail}"));
                    let version_fields=c[12..prefix].to_vec();
                    c=rewritten;c[12..prefix].copy_from_slice(&version_fields);
                }
            }
        }
        out.push(c);
    }
    if main {
        if u32le(&b, 12)? != 2 || entry.filter(|e| *e >= capacity as u64 && *e < b.len() as u64).is_none() { return Err("Không tìm được entry point iOS hợp lệ.".into()); }
        out.push(string_command(0xd, 24, "@rpath/iContainerGuest.dylib"));
        out.push(string_command(0x8000001c, 12, "@loader_path/Frameworks"));
    } else if ![6,8].contains(&u32le(&b, 12)?) { return Err("Unsupported nested Mach-O type".into()); }
    let len: usize = out.iter().map(Vec::len).sum();
    let old = u32le(&b, 20)? as usize;
    if capacity > b.len() || 32+len.max(old) > capacity { return Err("Mach-O không đủ header padding cho bản thử iContainer.".into()); }
    b[32..32+old.max(len)].fill(0);
    let mut pos = 32;
    for c in &out { b[pos..pos+c.len()].copy_from_slice(c); pos += c.len(); }
    set32(&mut b, 16, out.len() as u32); set32(&mut b, 20, len as u32);
    if main { set32(&mut b, 12, 6); let flags = u32le(&b,24)? & !0x00200000; set32(&mut b,24,flags); }
    Ok((b, entry))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample() -> Vec<u8> {
        let mut b=vec![0u8;8192]; set32(&mut b,0,0xfeedfacf); set32(&mut b,4,0x0100000c); set32(&mut b,12,2);
        set32(&mut b,16,2); set32(&mut b,20,176); set32(&mut b,32,0x19); set32(&mut b,36,152);
        set32(&mut b,96,1); set32(&mut b,32+72+48,4096);
        set32(&mut b,184,0x80000028); set32(&mut b,188,24); b[192..200].copy_from_slice(&4096u64.to_le_bytes()); b
    }
    #[test] fn converts_without_moving_code() { let b=sample(); let (out,entry)=prepare(&b,true).unwrap(); assert_eq!(entry,Some(4096)); assert_eq!(u32le(&out,12).unwrap(),6); assert_eq!(&b[4096..],&out[4096..]); assert!(commands(&out).unwrap().iter().any(|x| x.0==0xd)); }
    #[test] fn rejects_bad_command_and_entry() { let mut b=sample(); set32(&mut b,36,u32::MAX); assert!(prepare(&b,true).is_err()); let mut b=sample(); b[192..200].fill(0xff); assert!(prepare(&b,true).is_err()); }
    #[test] fn rejects_encryption_before_modification() { let mut b=sample(); set32(&mut b,184,0x2c); set32(&mut b,200,1); assert!(prepare(&b,true).unwrap_err().contains("mã hóa")); }
    #[test] fn rejects_arm64e_and_truncated_fat() { let mut b=sample(); set32(&mut b,8,2); assert!(thin_arm64(&b).is_err()); assert!(thin_arm64(&[0xca,0xfe,0xba,0xbe]).is_err()); }
    #[test] fn certificate_must_be_in_the_cms_slot() {
        let mut b=sample();set32(&mut b,184,0x1d);set32(&mut b,188,24);set32(&mut b,192,5000);set32(&mut b,196,40);
        let sig=&mut b[5000..5040];sig[..4].copy_from_slice(&[0xfa,0xde,0x0c,0xc0]);sig[4..8].copy_from_slice(&40u32.to_be_bytes());sig[8..12].copy_from_slice(&1u32.to_be_bytes());sig[12..16].copy_from_slice(&0x10000u32.to_be_bytes());sig[16..20].copy_from_slice(&20u32.to_be_bytes());sig[20..24].copy_from_slice(&[0xfa,0xde,0x0b,0x01]);sig[24..28].copy_from_slice(&20u32.to_be_bytes());sig[28..32].copy_from_slice(b"CERT");
        assert!(signature_contains(&b,b"CERT").unwrap());b[6000..6005].copy_from_slice(b"OTHER");assert!(!signature_contains(&b,b"OTHER").unwrap());
        b[5024..5028].copy_from_slice(&u32::MAX.to_be_bytes());assert!(signature_contains(&b,b"CERT").is_err());
    }
}
