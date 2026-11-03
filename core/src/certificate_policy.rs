//! One quota-recovery policy for installation, renewal and certificate export.
use std::{collections::HashSet,path::Path,time::{SystemTime,UNIX_EPOCH}};
use isideload::{dev::certificates::DevelopmentCertificate,sideload::builder::MaxCertsBehavior,util::callbacks::{MaxCertsCallbackBox,MaxCertsCallbackFuture}};
use serde_json::{Value,json};
use x509_cert::{Certificate,der::Decode};
use rootcause::prelude::*;
use crate::{bridge::Ui,ops::s};

pub fn normalize(serial:&str)->String {serial.trim().trim_start_matches('0').to_ascii_uppercase()}
fn protected(req:&Value,team:&str)->HashSet<String>{
    let path=Path::new(s(req,"host_path")).join("embedded.mobileprovision");
    let Some(profile)=std::fs::read(path).ok().and_then(|b|apple_codesign_quick::ProvisioningProfile::parse(&b).ok()) else{return HashSet::new();};
    if !profile.team_id().eq_ignore_ascii_case(team){return HashSet::new();}
    profile.plist().get("DeveloperCertificates").and_then(plist::Value::as_array).into_iter().flatten()
        .filter_map(plist::Value::as_data).filter_map(|b|Certificate::from_der(b).ok())
        .map(|c|normalize(&c.tbs_certificate.serial_number.as_bytes().iter().map(|b|format!("{b:02X}")).collect::<String>())).collect()
}
fn selection(answer:&str,rows:&[Value])->Result<Vec<String>,String>{
    let v:Value=serde_json::from_str(answer).map_err(|_|"Lựa chọn chứng chỉ không hợp lệ.")?;
    let selected=v["serials"].as_array().ok_or("Chưa chọn chứng chỉ.")?;
    let allow=v["allow_current"].as_bool().unwrap_or(false);
    let mut result=Vec::new();
    for item in selected{
        let wanted=item.as_str().ok_or("Serial không hợp lệ.")?;
        let row=rows.iter().find(|r|r["serial"].as_str().is_some_and(|s|normalize(s)==normalize(wanted))).ok_or("Chứng chỉ không nằm trong danh sách vừa tải.")?;
        if row["protected"].as_bool()==Some(true) && !allow{return Err("Chưa xác nhận thu hồi chứng chỉ đang dùng cho bản app hiện tại.".into());}
        let serial=row["serial"].as_str().unwrap().to_string();if !result.contains(&serial){result.push(serial);}
    }
    if result.is_empty(){return Err("Chưa chọn chứng chỉ cần thu hồi.".into());}Ok(result)
}
pub fn behavior(req:&Value,ui:Ui,team:&str)->MaxCertsBehavior<MaxCertsCallbackBox>{
    let protected=protected(req,team);let account=s(req,"apple_id").to_string();let team=team.to_string();
    MaxCertsBehavior::Prompt(Box::new(move |certs:Vec<DevelopmentCertificate>|->MaxCertsCallbackFuture{
        let protected=protected.clone();let account=account.clone();let team=team.clone();
        Box::pin(async move{
            let now=SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
            let rows:Vec<Value>=certs.iter().filter(|c|c.serial_number.as_ref().is_some_and(|s|!s.is_empty())).map(|c|{
                let mut row=crate::ops::cert_json(c);
                let serial=c.serial_number.as_deref().unwrap();row["protected"]=json!(protected.contains(&normalize(serial)));
                row["expired"]=json!(row["expires"].as_u64().is_some_and(|t|t>0 && t<=now));row
            }).collect();
            // Expired, non-current certificates are no longer usable and can
            // be reclaimed automatically. Live certificates require selection.
            let expired:Vec<String>=rows.iter().filter(|r|r["expired"]==true && r["protected"]!=true).filter_map(|r|r["serial"].as_str().map(str::to_string)).collect();
            if !expired.is_empty(){ui.progress("Đang thu hồi chứng chỉ đã hết hạn để tiếp tục ký…",None);return Ok(Some(expired));}
            if rows.is_empty(){return Err(report!("Apple báo đầy chứng chỉ nhưng không trả về chứng chỉ có thể thu hồi. Hãy thử tải lại danh sách trong Tài khoản."));}
            ui.progress("Apple đã đủ chứng chỉ. Chọn chứng chỉ cũ để thu hồi rồi tiếp tục ký.",None);
            let answer=ui.ask(json!({"kind":"revoke","certs":rows,"account":account,"team_id":team})).await
                .ok_or_else(||report!("Đã hủy thu hồi chứng chỉ; chưa thu hồi thêm chứng chỉ nào."))?;
            let chosen=selection(&answer,&rows).map_err(|e|report!(e))?;
            ui.progress("Đang thu hồi chứng chỉ đã chọn và tiếp tục ký…",None);
            Ok(Some(chosen))
        })
    }))
}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn only_certificates_in_the_live_list_can_be_selected(){
        let rows=vec![json!({"serial":"001ABC","protected":false})];
        assert_eq!(selection(r#"{"serials":["1abc"]}"#,&rows).unwrap(),vec!["001ABC"]);
        assert!(selection(r#"{"serials":["OTHER"]}"#,&rows).is_err());
    }
    #[test]fn current_certificate_requires_a_separate_confirmation(){
        let rows=vec![json!({"serial":"ABC","protected":true})];
        assert!(selection(r#"{"serials":["ABC"]}"#,&rows).is_err());
        assert!(selection(r#"{"serials":["ABC"],"allow_current":true}"#,&rows).is_ok());
        assert!(selection(r#"{"serials":[]}"#,&rows).is_err());
    }
    fn certificate(serial:&str)->DevelopmentCertificate{
        serde_json::from_value(json!({"serialNumber":serial,"machineName":"Old installer"})).unwrap()
    }
    #[tokio::test]async fn quota_routes_to_the_ui_and_returns_the_approved_serial(){
        unsafe extern "C" fn prompt(_ctx:*mut std::ffi::c_void,question:*const std::ffi::c_char,out:*mut std::ffi::c_char,cap:usize)->i32{
            let question=std::ffi::CStr::from_ptr(question).to_str().unwrap();
            let q:Value=serde_json::from_str(question).unwrap();
            assert_eq!(q["kind"],"revoke");assert_eq!(q["account"],"owner@example.com");
            assert!(q["certs"][0].get("cert_content").is_none());
            let answer=b"{\"serials\":[\"ABC\"],\"allow_current\":false}\0";
            assert!(cap>=answer.len());std::ptr::copy_nonoverlapping(answer.as_ptr().cast(),out,answer.len());0
        }
        let ui=Ui::new(None,Some(prompt),std::ptr::null_mut());
        let policy=behavior(&json!({"apple_id":"owner@example.com"}),ui,"TEAM123456");
        let MaxCertsBehavior::Prompt(callback)=policy else{panic!("quota policy must prompt")};
        assert_eq!(callback(vec![certificate("ABC")]).await.unwrap(),Some(vec!["ABC".into()]));
    }
    #[tokio::test]async fn expired_certificates_are_reclaimed_without_prompting_for_live_ones(){
        let mut expired=certificate("EXPIRED");expired.expiration_date=Some((UNIX_EPOCH+std::time::Duration::from_secs(10)).into());
        let policy=behavior(&json!({"apple_id":"owner@example.com"}),Ui::new(None,None,std::ptr::null_mut()),"TEAM123456");
        let MaxCertsBehavior::Prompt(callback)=policy else{panic!("quota policy must support recovery")};
        assert_eq!(callback(vec![certificate("LIVE"),expired]).await.unwrap(),Some(vec!["EXPIRED".into()]));
    }
}
