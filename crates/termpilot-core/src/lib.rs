//! Framework-independent connection policy, worker launch contract and framed IPC.
//! No Tauri, AppKit or WinUI dependency. Both native applications call this API.
pub mod batch;
pub mod connection;
pub mod frame;
pub mod launch;
pub mod resolve;
pub mod server_tools;
pub mod sync;
pub mod terminal;
pub mod vault;

use serde_json::{json, Value};
use std::ffi::{c_char, CString};
use zeroize::Zeroize;

pub const API_VERSION: u32 = 1;
// Editor snapshots can contain multiple 128 KiB scripts; retain a bounded IPC envelope.
pub const MAX_REQUEST: usize = 16 * 1024 * 1024;

pub fn dispatch(request: &Value) -> Result<Value, connection::CoreError> {
    use connection::CoreError;
    if request.get("apiVersion").and_then(Value::as_u64) != Some(API_VERSION.into()) {
        return Err(CoreError::new(
            "apiVersion",
            "Unsupported core API version.",
        ));
    }
    match request.get("method").and_then(Value::as_str) {
        Some("info") => Ok(json!({
            "apiVersion": API_VERSION, "version": env!("CARGO_PKG_VERSION"),
            "implementation": "termpilot-core", "platform": std::env::consts::OS,
            "highPerformanceProxy": false, "rdpImplemented": false
        })),
        Some("validateConnection") => {
            let connection: connection::Connection =
                serde_json::from_value(request["connection"].clone()).map_err(|_| {
                    CoreError::new("invalidRequest", "Invalid connection configuration.")
                })?;
            connection.validate()?;
            // Never return credentials or the supplied input in error/success output.
            Ok(json!({"valid": true, "protocol": connection.protocol, "port": connection.port}))
        }
        Some("validateEndpoint") => {
            connection::validate_endpoint(
                request["host"].as_str().unwrap_or(""),
                request["port"].as_u64().unwrap_or(0),
            )?;
            Ok(json!({"valid": true}))
        }
        Some("engineLaunch") => launch::plan(request),
        Some("serverTool") => server_tools::plan(request),
        Some("resolveConnection") => resolve::resolve(request),
        Some(method) if method.starts_with("batch.") => batch::dispatch(request),
        Some(method) if method.starts_with("vault.") => vault::dispatch(request),
        Some(method) if method.starts_with("sync.") => sync::dispatch(request, None),
        Some(method) if method.starts_with("terminal.") => terminal::dispatch(request),
        Some("validateFrame") => {
            let header = serde_json::to_vec(&request["header"])
                .map_err(|_| CoreError::new("invalidFrame", "Invalid engine frame."))?;
            Ok(json!({"payloadLength": frame::validate_header(&header)?}))
        }
        _ => Err(CoreError::new("unknownMethod", "Unknown core operation.")),
    }
}

pub fn call(bytes: &[u8]) -> String {
    let response = if bytes.len() > MAX_REQUEST {
        Err(connection::CoreError::new(
            "requestTooLarge",
            "Core request exceeds its size limit.",
        ))
    } else {
        serde_json::from_slice::<Value>(bytes)
            .map_err(|_| connection::CoreError::new("invalidRequest", "Invalid core request."))
            .and_then(|request| dispatch(&request))
    };
    match response {
        Ok(value) => json!({"ok": true, "value": value}).to_string(),
        Err(error) => json!({"ok": false, "error": error}).to_string(),
    }
}

/// # Safety
/// `data` must point to `length` readable bytes for the duration of the call.
/// The returned string is owned by this library; release it with tp_core_free.
#[no_mangle]
pub unsafe extern "C" fn tp_core_call(data: *const u8, length: usize) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if data.is_null() || length > MAX_REQUEST {
            return json!({"ok":false,"error":{"code":"invalidRequest","message":"Invalid core request."}}).to_string();
        }
        call(unsafe { std::slice::from_raw_parts(data, length) })
    }).unwrap_or_else(|_| json!({"ok":false,"error":{"code":"internalError","message":"Core operation failed."}}).to_string());
    CString::new(result)
        .expect("JSON cannot contain literal NUL")
        .into_raw()
}

/// # Safety
/// `value` must be null or a live pointer returned by tp_core_call, freed once.
#[no_mangle]
pub unsafe extern "C" fn tp_core_free(value: *mut c_char) {
    if !value.is_null() {
        let mut bytes = unsafe { CString::from_raw(value) }.into_bytes_with_nul();
        bytes.zeroize();
    }
}

#[no_mangle]
pub extern "C" fn tp_core_api_version() -> u32 {
    API_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn errors_do_not_echo_secret_bearing_input() {
        for input in [
            br#"{"password":"secret-marker","apiVersion":90}"#.as_slice(),
            b"secret-marker",
            &[0xff],
        ] {
            let result = call(input);
            assert!(!result.contains("secret-marker"));
            assert_eq!(serde_json::from_str::<Value>(&result).unwrap()["ok"], false);
        }
    }
    #[test]
    fn c_abi_ownership_and_null_input() {
        for _ in 0..100 {
            let request = br#"{"apiVersion":1,"method":"info"}"#;
            unsafe {
                let pointer = tp_core_call(request.as_ptr(), request.len());
                assert!(std::ffi::CStr::from_ptr(pointer)
                    .to_str()
                    .unwrap()
                    .contains("termpilot-core"));
                tp_core_free(pointer);
                let invalid = tp_core_call(std::ptr::null(), 0);
                assert!(std::ffi::CStr::from_ptr(invalid)
                    .to_str()
                    .unwrap()
                    .contains("invalidRequest"));
                tp_core_free(invalid);
                tp_core_free(std::ptr::null_mut());
            }
        }
    }
}
