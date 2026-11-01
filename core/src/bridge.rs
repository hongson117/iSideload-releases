//! Callbacks into the app.

use std::ffi::{c_char, c_void, CStr, CString};

pub type EventFn = unsafe extern "C" fn(*mut c_void, *const c_char);
pub type PromptFn = unsafe extern "C" fn(*mut c_void, *const c_char, *mut c_char, usize) -> i32;

#[derive(Clone, Copy)]
pub struct Ui {
    event: Option<EventFn>,
    prompt: Option<PromptFn>,
    ctx: usize,
}

// The app guarantees ctx stays valid and callbacks are thread-safe for the call.
unsafe impl Send for Ui {}
unsafe impl Sync for Ui {}

impl Ui {
    pub fn new(event: Option<EventFn>, prompt: Option<PromptFn>, ctx: *mut c_void) -> Self {
        Ui { event, prompt, ctx: ctx as usize }
    }

    pub fn progress(&self, stage: &str, fraction: Option<f64>) {
        let Some(f) = self.event else { return };
        let json = serde_json::json!({"stage": stage, "progress": fraction}).to_string();
        if let Ok(c) = CString::new(json) {
            unsafe { f(self.ctx as *mut c_void, c.as_ptr()) }
        }
    }

    /// Asks the app a question and blocks this thread until it answers. None = cancelled.
    pub fn ask_blocking(&self, question: serde_json::Value) -> Option<String> {
        let f = self.prompt?;
        let c = CString::new(question.to_string()).ok()?;
        let mut buf = vec![0 as c_char; 4096];
        let rc = unsafe { f(self.ctx as *mut c_void, c.as_ptr(), buf.as_mut_ptr(), buf.len()) };
        if rc != 0 {
            return None;
        }
        let last = buf.len() - 1;
        buf[last] = 0;
        let s = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().trim().to_string();
        Some(s)
    }

    /// Same as `ask_blocking`, from async code.
    pub async fn ask(&self, question: serde_json::Value) -> Option<String> {
        let ui = *self;
        tokio::task::spawn_blocking(move || ui.ask_blocking(question))
            .await
            .ok()
            .flatten()
    }
}
