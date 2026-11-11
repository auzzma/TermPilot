use anyhow::{bail, ensure, Result};
use russh::keys::{
    ssh_key::{self, private::RsaKeypair},
    Algorithm, EcdsaCurve, PrivateKey,
};
use serde_json::{json, Value};
pub fn generate(cfg: &Value) -> Result<Value> {
    let mut rng = rand10::rng();
    let mut key = match cfg["keyType"].as_str().unwrap_or("ed25519") {
        "ed25519" => PrivateKey::random(&mut rng, Algorithm::Ed25519)?,
        "ecdsa" => {
            let curve = match cfg["bits"].as_u64().unwrap_or(256) {
                256 => EcdsaCurve::NistP256,
                384 => EcdsaCurve::NistP384,
                521 => EcdsaCurve::NistP521,
                _ => bail!("ECDSA bits must be 256, 384 or 521"),
            };
            PrivateKey::random(&mut rng, Algorithm::Ecdsa { curve })?
        }
        "rsa" => {
            let bits = cfg["bits"].as_u64().unwrap_or(4096);
            ensure!([1024, 2048, 4096].contains(&bits), "Invalid RSA bits");
            PrivateKey::new(RsaKeypair::random(&mut rng, bits as usize)?.into(), "")?
        }
        _ => bail!("Unsupported key type"),
    };
    key.set_comment(cfg["comment"].as_str().unwrap_or("").trim());
    let public = key.public_key().to_openssh()?;
    if let Some(secret) = cfg["passphrase"].as_str().filter(|s| !s.is_empty()) {
        key = key.encrypt(&mut rng, secret)?;
    }
    Ok(json!({"privateKey":key.to_openssh(ssh_key::LineEnding::LF)?.as_str(),"publicKey":public}))
}
