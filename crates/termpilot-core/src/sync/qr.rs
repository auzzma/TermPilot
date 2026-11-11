//! Pure QR codec: native adapters own camera access and provide bounded greyscale frames.
use super::{err, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};

pub(super) fn encode(code: &str) -> Value {
    match qrcode::QrCode::with_error_correction_level(code, qrcode::EcLevel::M) {
        Ok(qr) => {
            json!({"width":qr.width(),"modules":qr.to_colors().iter().map(|b|if *b == qrcode::Color::Dark {'1'}else{'0'}).collect::<String>()})
        }
        Err(_) => Value::Null, // Never truncate a credential-bearing configuration.
    }
}

pub(super) fn decode(request: &Value) -> Result<Value> {
    let w = request["width"].as_u64().unwrap_or(0);
    let h = request["height"].as_u64().unwrap_or(0);
    if !(16..=1600).contains(&w) || !(16..=1600).contains(&h) || w * h > 700_000 {
        return Err(err("syncQRSize", "扫码画面尺寸无效。"));
    }
    let encoded = request["pixels"].as_str().unwrap_or("");
    if encoded.len() > 940_000 {
        return Err(err("syncQRSize", "扫码画面过大。"));
    }
    let pixels = STANDARD
        .decode(encoded)
        .map_err(|_| err("syncQRSize", "扫码画面无效。"))?;
    if pixels.len() != (w * h) as usize {
        return Err(err("syncQRSize", "扫码画面不完整。"));
    }
    let mut decoder = quircs::Quirc::default();
    for grid in decoder.identify(w as usize, h as usize, &pixels).flatten() {
        if let Ok(decoded) = grid.decode() {
            if let Ok(code) = String::from_utf8(decoded.payload) {
                if code.starts_with(super::invite::PREFIX) && code.len() <= super::invite::MAX_CODE
                {
                    return Ok(json!({"code":code}));
                }
            }
        }
    }
    Ok(json!({"code":null}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn qr_camera_frame_roundtrip_and_limits() {
        let code = format!("{}{}", super::super::invite::PREFIX, "abc123".repeat(100));
        let qr = encode(&code);
        let width = qr["width"].as_u64().unwrap() as usize;
        let modules = qr["modules"].as_str().unwrap().as_bytes();
        let size = (width + 8) * 4;
        let mut pixels = vec![255; size * size];
        for y in 0..width {
            for x in 0..width {
                if modules[y * width + x] == b'1' {
                    for dy in 0..4 {
                        for dx in 0..4 {
                            pixels[((y + 4) * 4 + dy) * size + (x + 4) * 4 + dx] = 0;
                        }
                    }
                }
            }
        }
        assert_eq!(
            decode(&json!({"width":size,"height":size,"pixels":STANDARD.encode(pixels)})).unwrap()
                ["code"],
            code
        );
        assert!(encode(&"x".repeat(5000)).is_null());
        assert!(decode(&json!({"width":u64::MAX,"height":100})).is_err());
        assert!(decode(&json!({"width":100,"height":100,"pixels":"AA=="})).is_err());
    }
}
