//! iSideload core. MIT License.
//!
//! One C entry point, `isl_call`, takes a JSON request and answers with JSON.
//! Long operations report progress through an event callback and ask the
//! user things (2FA code, certificate to revoke) through a prompt callback.

mod bridge;
mod device;
mod license;
mod ops;
mod imported;
mod peer;
mod container;
mod container_macho;
mod self_refresh;

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::OnceLock;

pub use bridge::{EventFn, PromptFn};

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let _ = isideload::init();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// # Safety
/// `request_json` must be a valid NUL-terminated string. Callbacks may be null.
#[no_mangle]
pub unsafe extern "C" fn isl_call(
    request_json: *const c_char,
    event: Option<EventFn>,
    prompt: Option<PromptFn>,
    ctx: *mut c_void,
) -> *mut c_char {
    let reply = if request_json.is_null() {
        serde_json::json!({"ok": false, "error": "No request."})
    } else {
        let text = CStr::from_ptr(request_json).to_string_lossy().into_owned();
        let ui = bridge::Ui::new(event, prompt, ctx);
        match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(req) => runtime().block_on(ops::dispatch(req, ui)),
            Err(e) => serde_json::json!({"ok": false, "error": format!("Bad request: {e}")}),
        }
    };
    CString::new(reply.to_string()).unwrap_or_default().into_raw()
}

/// # Safety
/// `s` must come from `isl_call`.
#[no_mangle]
pub unsafe extern "C" fn isl_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
