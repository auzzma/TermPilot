//! Encrypted onboarding, independent of cloud data keys and local replica state.
use super::{
    control, err, profiles, runtime,
    store::{Config, Store},
    transport::{Backend, Objects, Provider},
    Result,
};
use crate::vault::{crypto, Vault};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use zeroize::Zeroizing;

pub(super) const PREFIX: &str = "TP-SYNC:1:";
pub(super) const MAX_CODE: usize = 24_000;
const AAD: &[u8] = b"TermPilot:sync:invite:1:PBKDF2-SHA256:600000:AES256GCM";

// An explicit allowlist prevents future Config fields leaking local state or keys.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Invite {
    title: String,
    library: String,
    provider: Provider,
}
fn invalid() -> crate::connection::CoreError {
    err("syncInvite", "配置码无效、已损坏或同步 Key 不正确。")
}
fn password(value: &Value) -> Result<&str> {
    let text = value["passphrase"].as_str().unwrap_or("");
    if !(12..=1024).contains(&text.chars().count()) {
        return Err(err("syncPassword", "请输入 12–1024 个字符的同步 Key。"));
    }
    Ok(text)
}
fn derive(password: &str, salt: &[u8]) -> Zeroizing<[u8; 32]> {
    let mut key = Zeroizing::new([0; 32]);
    let mut domain = AAD.to_vec();
    domain.extend_from_slice(salt);
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), &domain, 600_000, &mut *key);
    key
}
fn validate(invite: &Invite) -> Result<()> {
    if invite.title.trim().is_empty()
        || invite.title.chars().count() > 100
        || uuid::Uuid::parse_str(&invite.library).is_err()
    {
        return Err(invalid());
    }
    if !matches!(
        invite.provider,
        Provider::Webdav { .. } | Provider::S3 { .. } | Provider::R2 { .. }
    ) {
        return Err(invalid());
    }
    let _ = Backend::new(invite.provider.clone(), &invite.library)?;
    Ok(())
}
fn encode(invite: &Invite, password: &str) -> Result<String> {
    validate(invite)?;
    let clear = Zeroizing::new(serde_json::to_vec(invite).map_err(|_| invalid())?);
    if clear.len() > 16_000 {
        return Err(err(
            "syncInviteSize",
            "云服务配置过大，请缩短名称或配置字段。",
        ));
    }
    let mut salt = [0; 16];
    OsRng.fill_bytes(&mut salt);
    let key = derive(password, &salt);
    let cipher = crypto::seal(&*key, &clear, AAD)?;
    Ok(format!(
        "{PREFIX}{}",
        URL_SAFE_NO_PAD.encode([salt.as_slice(), cipher.as_slice()].concat())
    ))
}
fn decode(code: &str, password: &str) -> Result<Invite> {
    let code = code.trim();
    if code.len() > MAX_CODE {
        return Err(invalid());
    }
    let encoded = code.strip_prefix(PREFIX).ok_or_else(invalid)?;
    let bytes = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| invalid())?;
    if bytes.len() < 44 {
        return Err(invalid());
    }
    let key = derive(password, &bytes[..16]);
    let clear = crypto::unseal(&*key, &bytes[16..], AAD).map_err(|_| invalid())?;
    let invite: Invite = serde_json::from_slice(&clear).map_err(|_| invalid())?;
    validate(&invite)?;
    Ok(invite)
}
fn public(invite: &Invite) -> Value {
    json!({"title":invite.title,"library":invite.library,"provider":invite.provider.public()})
}
fn destination(provider: &Provider) -> Value {
    let mut v = provider.public();
    // Authentication and display names do not create a second replica of a destination.
    if let Some(endpoint) = v["endpoint"].as_str() {
        if let Ok(mut url) = reqwest::Url::parse(endpoint) {
            let path = url.path().trim_end_matches('/').to_owned();
            url.set_path(&path);
            v["endpoint"] = json!(url.as_str().trim_end_matches('/'));
        }
    }
    if let Some(prefix) = v["prefix"].as_str() {
        v["prefix"] = json!(prefix.trim_matches('/'));
    }
    if let Some(o) = v.as_object_mut() {
        o.remove("auth_type");
        o.remove("region");
    }
    if v["kind"] == "r2" {
        v["kind"] = json!("s3");
    }
    v
}
fn preflight(config: &mut Config, cloud: &mut dyn Objects) -> Result<()> {
    let (head, _) = control::read(cloud, &config.library)?.ok_or_else(|| {
        err(
            "syncInviteMissing",
            "未找到此同步库。请在原设备完成一次同步后重新生成配置码。",
        )
    })?;
    head.verify(config)?;
    if head.lock.is_some() {
        return Err(err(
            "syncCloudBusy",
            "同步库正在同步或修改 Key，请稍后再导入。",
        ));
    }
    if head.sequence < config.generation_sequence {
        return Err(err("syncRollback", "云端 Key 版本回退，已停止导入。"));
    }
    config.generation = head.generation;
    config.generation_sequence = head.sequence;
    Ok(())
}
pub(super) fn dispatch(
    vault: &Vault,
    store: &Store<'_>,
    request: &Value,
    supplied_key: Option<&[u8]>,
) -> Result<Value> {
    let secret = password(request)?;
    if request["method"] == "sync.invite.export" {
        let id = request["id"].as_str().unwrap_or("");
        profiles::blocked(store, id)?;
        let mut config = profiles::config(store, id)?;
        // Cloud authentication proves this is the current Key, including inactive profiles.
        config.scope_keys = runtime::derive_keys(secret, &config.library)?;
        let mut cloud = Backend::new(config.provider.clone(), &config.library)?;
        preflight(&mut config, &mut cloud)?;
        let profile = profiles::list(store)?
            .into_iter()
            .find(|p| p["id"] == id)
            .ok_or_else(invalid)?;
        let invite = Invite {
            title: profile["title"].as_str().unwrap_or("云服务").into(),
            library: config.library,
            provider: config.provider,
        };
        let code = encode(&invite, secret)?;
        return Ok(json!({"qr":super::qr::encode(&code),"code":code}));
    }
    let invite = decode(request["code"].as_str().unwrap_or(""), secret)?;
    if request["method"] == "sync.invite.preview" {
        return Ok(public(&invite));
    }
    if request["method"] != "sync.invite.import" {
        return Err(invalid());
    }
    if request["confirmed"] != true {
        return Err(err("syncConfirmation", "请确认导入并合并所选本机数据。"));
    }
    let scopes = runtime::parse_scopes(&request["scopes"])?;
    let mut keys = runtime::derive_keys(secret, &invite.library)?;
    keys.retain(|scope, _| scopes.contains(scope));
    let mut config = Config {
        library: invite.library.clone(),
        generation: String::new(),
        generation_sequence: 0,
        device: String::new(),
        name: request["name"]
            .as_str()
            .filter(|n| !n.trim().is_empty())
            .unwrap_or("TermPilot")
            .chars()
            .take(100)
            .collect(),
        auto: true,
        scopes,
        lock_timeout_minutes: super::lease::default_timeout(),
        retention_days: Some(30),
        scope_keys: keys,
        provider: invite.provider.clone(),
    };
    let existing = profiles::list(store)?.into_iter().find(|p| {
        p["library"] == invite.library
            && profiles::config(store, p["id"].as_str().unwrap_or(""))
                .is_ok_and(|c| destination(&c.provider) == destination(&invite.provider))
    });
    if let Some(id) = profiles::active(store)? {
        profiles::blocked(store, &id)?;
    }
    if let Some(p) = &existing {
        let id = p["id"].as_str().unwrap_or("");
        profiles::blocked(store, id)?;
        config.generation_sequence = profiles::config(store, id)?.generation_sequence;
    }
    let mut cloud = Backend::new(config.provider.clone(), &config.library)?;
    preflight(&mut config, &mut cloud)?; // No profile, replica, or business-data mutation before validation.
    let reused = existing.is_some();
    let id = if let Some(p) = existing {
        p["id"].as_str().ok_or_else(invalid)?.to_owned()
    } else {
        profiles::add_imported(store, invite.title.clone(), config)?
    };
    // Once installed, failures are returned as a resumable result, never as a misleading rollback.
    let finish = (|| -> Result<Value> {
        profiles::dispatch(
            vault,
            store,
            &json!({"method":"sync.profile.use","id":id,"confirmed":true}),
        )?;
        if reused {
            super::rekey::unlock(store, &mut cloud, secret)?;
            let current = store.config()?;
            let profile = profiles::list(store)?
                .into_iter()
                .find(|p| p["id"] == id)
                .ok_or_else(invalid)?;
            // Re-import retains existing scopes and all pending operations. Scope changes remain in Edit.
            profiles::dispatch(
                vault,
                store,
                &json!({"method":"sync.profile.update","id":id,"title":profile["title"],"provider":invite.provider,
                "name":current.name,"scopes":current.scopes,"auto":true,"confirmed":true}),
            )?;
        }
        let mut run = request.clone();
        run["method"] = json!("sync.run");
        runtime::dispatch(&run, supplied_key)
    })();
    match finish {
        Ok(status) => {
            Ok(json!({"installed":true,"synced":true,"reused":reused,"id":id,"status":status}))
        }
        Err(e) => {
            if profiles::active(store)?.as_deref() == Some(id.as_str()) {
                store.put(
                    "lastError",
                    &json!({"message":e.message,"at":chrono::Utc::now().to_rfc3339()}),
                )?;
            }
            Ok(json!({"installed":true,"synced":false,"reused":reused,"id":id,"error":e.message}))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encrypted_invite_roundtrip_wrong_key_tampering_and_allowlist() {
        let invite = Invite {
            title: "家用同步".into(),
            library: uuid::Uuid::new_v4().to_string(),
            provider: Provider::S3 {
                endpoint: "https://s3.example.org".into(),
                bucket: "private".into(),
                region: "auto".into(),
                access_key: "secret-id".into(),
                secret_key: "secret-value".into(),
                session_token: String::new(),
                prefix: "TermPilot".into(),
            },
        };
        let code = encode(&invite, "test-sync-key-123").unwrap();
        assert!(!code.contains("secret"));
        assert_ne!(code, encode(&invite, "test-sync-key-123").unwrap());
        assert_eq!(
            decode(&code, "test-sync-key-123")
                .unwrap()
                .provider
                .public(),
            invite.provider.public()
        );
        assert!(decode(&code, "wrong-sync-key-123").is_err());
        let mut raw = URL_SAFE_NO_PAD
            .decode(code.strip_prefix(PREFIX).unwrap())
            .unwrap();
        raw[30] ^= 1;
        assert!(decode(
            &format!("{PREFIX}{}", URL_SAFE_NO_PAD.encode(raw)),
            "test-sync-key-123"
        )
        .is_err());
        assert!(decode(
            &code.replace("TP-SYNC:1:", "TP-SYNC:2:"),
            "test-sync-key-123"
        )
        .is_err());
        let clear = serde_json::to_value(&invite).unwrap();
        assert!(clear.get("device").is_none() && clear.get("scope_keys").is_none());
        assert!(public(&invite)["provider"].get("secret_key").is_none());
        let blocked = Invite {
            provider: Provider::Folder {
                path: "/tmp/unsafe".into(),
            },
            ..invite
        };
        assert!(encode(&blocked, "test-sync-key-123").is_err());
    }
}
