#[path = "../core/src/container_macho.rs"]
mod container_macho;
fn main() {
    let args:Vec<_>=std::env::args().collect();
    let path=std::path::Path::new(&args[1]);
    let b=std::fs::read(path).unwrap();
    let (out,entry)=container_macho::prepare(&b,true).expect("prepare actual Xcode-built arm64 demo");
    assert!(entry.is_some());
    let mut seen=std::collections::HashSet::new();
    for (cmd,at,size) in container_macho::commands(&out).unwrap() {
        if cmd==0x8000001c {
            let offset=u32::from_le_bytes(out[at+8..at+12].try_into().unwrap()) as usize;
            let value=out[at+offset..at+size].split(|b|*b==0).next().unwrap();
            assert!(seen.insert(value.to_vec()),"Duplicate RPATH survived preparation");
        }
    }
    assert!(seen.contains(b"@loader_path/Frameworks".as_slice()));
    std::fs::write(&args[2],out).unwrap();
    println!("Prepared real iOS demo; original entry offset {}",entry.unwrap());
}
