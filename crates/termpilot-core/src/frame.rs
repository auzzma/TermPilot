//! Shared framing limits for worker streams. Reject sizes before allocation.
use crate::connection::CoreError;
use serde_json::Value;
pub const MAX_HEADER: usize = 64 * 1024;
pub const MAX_PAYLOAD: usize = 64 * 1024 * 1024;
pub const DEFAULT_FRAME_RATE: u32 = 60;

/// Old or invalid preferences retain the 60 FPS default; 30 is the other option.
pub fn normalized_frame_rate(value: Option<u64>) -> u32 {
    if value == Some(30) {
        30
    } else {
        DEFAULT_FRAME_RATE
    }
}

pub fn validate_header(header: &[u8]) -> Result<usize, CoreError> {
    let invalid = || CoreError::new("invalidFrame", "Invalid engine frame.");
    if header.is_empty() || header.len() > MAX_HEADER {
        return Err(invalid());
    }
    let value: Value = serde_json::from_slice(header).map_err(|_| invalid())?;
    let length = value["payloadLength"].as_u64().ok_or_else(invalid)?;
    if length > MAX_PAYLOAD as u64 || value["kind"].as_str().is_none() {
        return Err(invalid());
    }
    Ok(length as usize)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn old_and_invalid_frame_rate_preferences_use_safe_default() {
        for value in [None, Some(0), Some(60), Some(120), Some(u64::MAX)] {
            assert_eq!(normalized_frame_rate(value), 60);
        }
        assert_eq!(normalized_frame_rate(Some(30)), 30);
    }
    #[test]
    fn malicious_lengths_rejected_before_allocating() {
        for header in [
            br#"{"kind":"frame","payloadLength":-1}"#.as_slice(),
            br#"{"kind":"frame","payloadLength":18446744073709551615}"#,
            b"null",
        ] {
            assert!(validate_header(header).is_err());
        }
        assert_eq!(
            validate_header(br#"{"kind":"frame","payloadLength":8294400}"#).unwrap(),
            8294400
        );
    }
}
