use crate::connection::CoreError;
use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use rand::{rngs::OsRng, RngCore};
use serde_json::{json, Value};
use sha2::Sha256;
use zeroize::Zeroizing;

pub fn error() -> CoreError {
    CoreError::new(
        "invalidCiphertext",
        "Unable to decrypt data. Check the password and credential key.",
    )
}
pub fn random_key() -> Zeroizing<Vec<u8>> {
    let mut v = Zeroizing::new(vec![0; 32]);
    OsRng.fill_bytes(&mut v);
    v
}
pub fn seal(key: &[u8], input: &[u8], aad: &[u8]) -> Result<Vec<u8>, CoreError> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| error())?;
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let data = cipher
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: input, aad })
        .map_err(|_| error())?;
    Ok([nonce.as_slice(), data.as_slice()].concat())
}
pub fn unseal(key: &[u8], input: &[u8], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>, CoreError> {
    if input.len() < 28 {
        return Err(error());
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| error())?;
    Ok(Zeroizing::new(
        cipher
            .decrypt(
                Nonce::from_slice(&input[..12]),
                Payload {
                    msg: &input[12..],
                    aad,
                },
            )
            .map_err(|_| error())?,
    ))
}
pub fn encrypt_field(key: &[u8], value: &Value) -> Result<Value, CoreError> {
    let Some(text) = value.as_str() else {
        return Ok(Value::Null);
    };
    if text.is_empty() {
        return Ok(value.clone());
    }
    Ok(json!(format!(
        "enc:v1:{}",
        B64.encode(seal(key, text.as_bytes(), b"")?)
    )))
}
pub fn decrypt_field(key: &[u8], value: &Value) -> Result<Value, CoreError> {
    let Some(text) = value.as_str() else {
        return Ok(Value::Null);
    };
    let Some(encoded) = text.strip_prefix("enc:v1:") else {
        return Ok(value.clone());
    };
    let data = B64.decode(encoded).map_err(|_| error())?;
    let decoded = unseal(key, &data, b"")?;
    Ok(json!(std::str::from_utf8(&decoded).map_err(|_| error())?))
}
const AAD: &[u8] = b"TermPilotBackup:v1:PBKDF2-HMAC-SHA256:AES-256-GCM";
fn password_check(password: &str) -> Result<(), CoreError> {
    if password.trim().is_empty() {
        return Err(CoreError::new(
            "missingPassword",
            "Backup password is required.",
        ));
    }
    Ok(())
}
pub fn encrypt_backup(snapshot: &Value, password: &str) -> Result<Vec<u8>, CoreError> {
    password_check(password)?;
    let mut salt = [0u8; 16];
    OsRng.fill_bytes(&mut salt);
    let mut key = Zeroizing::new([0u8; 32]);
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), &salt, 600_000, &mut *key);
    let data = Zeroizing::new(serde_json::to_vec(snapshot).map_err(|_| error())?);
    let payload = seal(&*key, &data, AAD)?;
    serde_json::to_vec(&json!({"magic":"TermPilotBackup","version":1,"kdf":"PBKDF2-HMAC-SHA256","iterations":600_000,"salt":B64.encode(salt),"cipher":"AES-256-GCM","payload":B64.encode(payload)})).map_err(|_|error())
}
pub fn decrypt_backup(data: &[u8], password: &str) -> Result<Value, CoreError> {
    password_check(password)?;
    if data.len() > 100 * 1024 * 1024 {
        return Err(CoreError::new("backupTooLarge", "Backup exceeds 100 MiB."));
    }
    let v: Value = serde_json::from_slice(data).map_err(|_| error())?;
    let iterations = v["iterations"].as_u64().unwrap_or(0);
    if v["magic"] != "TermPilotBackup"
        || v["version"] != 1
        || v["kdf"] != "PBKDF2-HMAC-SHA256"
        || v["cipher"] != "AES-256-GCM"
        || !(100_000..=2_000_000).contains(&iterations)
    {
        return Err(error());
    }
    let salt = B64
        .decode(v["salt"].as_str().unwrap_or(""))
        .map_err(|_| error())?;
    if salt.len() != 16 {
        return Err(error());
    }
    let payload = B64
        .decode(v["payload"].as_str().unwrap_or(""))
        .map_err(|_| error())?;
    let mut key = Zeroizing::new([0u8; 32]);
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), &salt, iterations as u32, &mut *key);
    let data = unseal(&*key, &payload, AAD)?;
    let snapshot: Value = serde_json::from_slice(&data).map_err(|_| error())?;
    if snapshot["schemaVersion"] != 1 {
        return Err(CoreError::new(
            "unsupportedSchema",
            "Unsupported backup schema.",
        ));
    }
    Ok(snapshot)
}
