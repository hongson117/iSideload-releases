//! DER-complete signatures for Mach-O guests loaded into iContainer.
//! The signer library currently emits XML-only entitlements for MH_DYLIB.
//! Keep the actual Mach-O type and layout; explicitly seal both entitlement
//! representations in the final CodeDirectories before generating their CMS.
use apple_codesign_quick::{sign_macho_data, MachOSigningConfig, CmsSigner, signature::{
    CodeDirectoryParams, ExecutableSegment, empty_requirements_blob,
    entitlements_xml, entitlements_blob, der_entitlements_blob, encode_embedded_signature,
}};
use std::path::Path;

fn read32(bytes:&[u8], at:usize, big:bool)->Result<usize,String>{
    let value: [u8;4]=bytes.get(at..at.checked_add(4).ok_or("Signature offset overflow")?).ok_or("Truncated signature field")?.try_into().unwrap();
    Ok(if big {u32::from_be_bytes(value)} else {u32::from_le_bytes(value)} as usize)
}
fn read64(bytes:&[u8], at:usize)->Result<u64,String>{
    Ok(u64::from_be_bytes(bytes.get(at..at.checked_add(8).ok_or("Signature offset overflow")?).ok_or("Truncated executable segment")?.try_into().unwrap()))
}
fn region_and_segment(data:&[u8])->Result<(usize,usize,ExecutableSegment),String>{
    if data.get(..4)!=Some(&[0xcf,0xfa,0xed,0xfe]) || ![6,8].contains(&read32(data,12,false)?){return Err("Expected a prepared 64-bit guest library".into());}
    let mut region=None;
    for (cmd,at,size) in crate::container_macho::commands(data)? {
        if cmd==0x1d {
            if size<16{return Err("Truncated code signature command".into());}
            if region.is_some(){return Err("Duplicate code signature command".into());}
            region=Some((read32(data,at+8,false)?,read32(data,at+12,false)?));
        }
    }
    let (offset,capacity)=region.ok_or("Missing guest code signature")?;
    let signature=data.get(offset..offset.checked_add(capacity).ok_or("Signature range overflow")?).ok_or("Guest signature outside file")?;
    if read32(signature,0,true)?!=0xfade0cc0{return Err("Invalid guest signature superblob".into());}
    let length=read32(signature,4,true)?;let count=read32(signature,8,true)?;
    if length>capacity || count>128 || 12+count*8>length{return Err("Invalid guest signature index".into());}
    for index in 0..count {
        let pos=12+index*8;
        if read32(signature,pos,true)?!=0{continue;}
        let cd_at=read32(signature,pos+4,true)?;
        let cd=signature.get(cd_at..length).ok_or("Invalid CodeDirectory offset")?;
        if read32(cd,0,true)?!=0xfade0c02 || read32(cd,4,true)?<88 || read32(cd,4,true)?>cd.len() || read32(cd,8,true)?<0x20400 || read32(cd,32,true)?!=offset {
            return Err("Unsupported guest CodeDirectory layout".into());
        }
        return Ok((offset,capacity,ExecutableSegment{base:read64(cd,64)?,limit:read64(cd,72)?,flags:read64(cd,80)?}));
    }
    Err("Missing primary CodeDirectory".into())
}

pub fn sign_guest(path:&Path, patched:&[u8], identifier:&str, team:&str, signer:&dyn CmsSigner)->Result<Vec<u8>,String>{
    if patched.get(..4)!=Some(&[0xcf,0xfa,0xed,0xfe]) || ![6,8].contains(&read32(patched,12,false)?){return Err("Expected a prepared 64-bit guest library".into());}
    let entitlements=plist::Dictionary::new();
    let mut layout=MachOSigningConfig::new(identifier,team,&entitlements,Some(signer));
    // Reserve room for DER and its special-slot hashes without changing any
    // load command after hashing. Final CMS retains the normal reservation.
    layout.cms_blob_reservation+=4096;
    let mut signed=sign_macho_data(path,patched,&layout).map_err(|e|e.to_string())?;
    let (offset,capacity,segment)=region_and_segment(&signed)?;
    let requirements=empty_requirements_blob();
    let xml=entitlements_blob(&entitlements_xml(&entitlements).map_err(|e|e.to_string())?);
    let der=der_entitlements_blob(&entitlements).map_err(|e|e.to_string())?;
    let params=CodeDirectoryParams{identifier,team_id:team,macho_data:&signed,code_limit:offset,executable_segment:segment,
        // In this API the boolean selects seven special slots, including DER.
        // It does not change the Mach-O header or set executable-segment flags.
        is_executable:true,requirements_blob:&requirements,entitlements_blob:&xml,der_entitlements_blob:Some(&der),info_plist:None,code_resources:None};
    let signature=encode_embedded_signature(&params,Some(signer),layout.cms_blob_reservation-4096).map_err(|e|e.to_string())?;
    if signature.len()>capacity{return Err("DER-complete guest signature exceeds reserved capacity".into());}
    signed[offset..offset+capacity].fill(0);
    signed[offset..offset+signature.len()].copy_from_slice(&signature);
    Ok(signed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use apple_codesign_quick::{CmsSigningRequest, HashAlgorithm};

    struct DigestWitness;
    impl CmsSigner for DigestWitness {
        fn sign(&self, request:CmsSigningRequest<'_>)->apple_codesign_quick::Result<Vec<u8>> {
            // Test witness only: checks that the CMS callback receives exactly
            // the final CodeDirectories, after the DER hashes have been sealed.
            Ok(request.code_directories.iter().flat_map(|d|HashAlgorithm::Sha256.digest(d.bytes)).collect())
        }
    }
    fn set32(b:&mut[u8],at:usize,n:u32){b[at..at+4].copy_from_slice(&n.to_le_bytes());}
    fn set64(b:&mut[u8],at:usize,n:u64){b[at..at+8].copy_from_slice(&n.to_le_bytes());}
    fn fixture(kind:u32)->Vec<u8>{
        let mut b=vec![0u8;8192];
        for (at,n) in [(0,0xfeedfacf),(4,0x0100000c),(12,kind),(16,2),(20,224),(32,0x19),(36,152),(88,7),(92,5),(96,1),(184,0x19),(188,72)]{set32(&mut b,at,n);}
        b[40..46].copy_from_slice(b"__TEXT");set64(&mut b,64,8192);set64(&mut b,80,8192);
        b[104..110].copy_from_slice(b"__text");set64(&mut b,136,4096);set64(&mut b,144,4096);set32(&mut b,152,4096);
        b[192..202].copy_from_slice(b"__LINKEDIT");set64(&mut b,208,8192);set64(&mut b,224,8192);
        for (index,byte) in b[4096..].iter_mut().enumerate(){*byte=(index%251) as u8;}
        b
    }
    fn blob<'a>(signature:&'a[u8],slot:usize)->&'a[u8]{
        for i in 0..read32(signature,8,true).unwrap(){
            if read32(signature,12+i*8,true).unwrap()==slot{
                let start=read32(signature,16+i*8,true).unwrap();let length=read32(signature,start+4,true).unwrap();
                return &signature[start..start+length];
            }
        }panic!("missing signature slot {slot}")
    }
    #[test]
    fn seals_der_and_code_pages_before_final_cms_without_changing_library_type(){
        for kind in [6,8]{
            let input=fixture(kind);let signed=sign_guest(Path::new("Guest"),&input,"example.host","TESTTEAM01",&DigestWitness).unwrap();
            assert_eq!(read32(&signed,12,false).unwrap(),kind as usize);
            assert_eq!(&signed[4096..8192],&input[4096..8192]);
            let (offset,capacity,segment)=region_and_segment(&signed).unwrap();
            assert_eq!(segment.flags,0,"A library must not claim main-executable privileges");
            let signature=&signed[offset..offset+capacity];let der=blob(signature,7);let xml=blob(signature,5);
            assert_eq!(der,der_entitlements_blob(&plist::Dictionary::new()).unwrap());
            let mut witness=Vec::new();
            for (slot,algorithm) in [(0,HashAlgorithm::Sha1),(4096,HashAlgorithm::Sha256)]{
                let cd=blob(signature,slot);let hashes=read32(cd,16,true).unwrap();let size=cd[36] as usize;
                assert_eq!(read32(cd,24,true).unwrap(),7);
                assert_eq!(&cd[hashes-7*size..hashes-6*size],algorithm.digest(der));
                assert_eq!(&cd[hashes-5*size..hashes-4*size],algorithm.digest(xml));
                for (page,bytes) in signed[..offset].chunks(4096).enumerate(){
                    assert_eq!(&cd[hashes+page*size..hashes+(page+1)*size],algorithm.digest(bytes));
                }
                witness.extend(HashAlgorithm::Sha256.digest(cd));
            }
            assert_eq!(&blob(signature,65536)[8..],witness);
        }
    }
    #[test]
    fn malformed_signatures_and_unprepared_executables_are_rejected(){
        assert!(sign_guest(Path::new("Guest"),&fixture(2),"example.host","TESTTEAM01",&DigestWitness).is_err());
        for length in [0,3,16,31]{assert!(region_and_segment(&fixture(6)[..length]).is_err());}
        let signed=sign_guest(Path::new("Guest"),&fixture(6),"example.host","TESTTEAM01",&DigestWitness).unwrap();
        let (offset,_,_)=region_and_segment(&signed).unwrap();
        let mut bad=signed.clone();bad[offset+4..offset+8].copy_from_slice(&u32::MAX.to_be_bytes());assert!(region_and_segment(&bad).is_err());
        let mut bad=signed.clone();bad[offset+16..offset+20].copy_from_slice(&u32::MAX.to_be_bytes());assert!(region_and_segment(&bad).is_err());
        let mut bad=signed;let at=crate::container_macho::commands(&bad).unwrap().into_iter().find(|x|x.0==0x1d).unwrap().1;
        set32(&mut bad,at+12,u32::MAX);assert!(region_and_segment(&bad).is_err());
    }
}
