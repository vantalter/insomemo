use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString, c_char, c_int};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Layout {
    pub id: String,
    pub name: String,
    pub code: String,
}

unsafe extern "C" {
    pub fn native_run(event_fd: c_int) -> c_int;
    pub fn native_set_layout(id: *const c_char) -> c_int;
    fn native_layouts() -> *mut c_char;
    fn native_free(value: *mut c_char);
    pub fn native_update(
        context: *const c_char,
        paused: c_int,
        error: *const c_char,
        layouts_json: *const c_char,
        menu_json: *const c_char,
    );
    pub fn native_schedule_save();
    pub fn native_indicate_switch();
    pub fn native_stop();
    fn native_hash(text: *const c_char, output: *mut c_char);
    #[cfg(target_os = "macos")]
    pub fn native_alert(message: *const c_char);
}

pub fn cstring(value: &str) -> CString {
    CString::new(value.replace('\0', "")).unwrap()
}

pub fn title_hash(title: &str) -> String {
    let input = cstring(title);
    let mut output = [0 as c_char; 17];
    unsafe {
        native_hash(input.as_ptr(), output.as_mut_ptr());
        CStr::from_ptr(output.as_ptr())
            .to_string_lossy()
            .into_owned()
    }
}

pub fn layouts() -> Result<Vec<Layout>, String> {
    unsafe {
        let pointer = native_layouts();
        if pointer.is_null() {
            return Err("Unable to enumerate keyboard layouts".into());
        }
        let result =
            serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()).map_err(|e| e.to_string());
        native_free(pointer);
        result
    }
}
