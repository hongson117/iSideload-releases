#[path = "../core/src/container_macho.rs"]
mod container_macho;
fn main() {
    let args:Vec<_>=std::env::args().collect();
    let path=std::path::Path::new(&args[1]);
    let b=std::fs::read(path).unwrap();
    let (out,entry)=container_macho::prepare(&b,true).expect("prepare actual Xcode-built arm64 demo");
    assert!(entry.is_some());
    std::fs::write(&args[2],out).unwrap();
    println!("Prepared real iOS demo; original entry offset {}",entry.unwrap());
}
