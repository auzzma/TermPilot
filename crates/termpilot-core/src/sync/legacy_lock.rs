//! Explicit, backed-up recovery of abandoned v2 sync locks. Never bypass a lease.
use super::{
    control::{self, Head, Lock, Namespace},
    db_error, err,
    lease::{self, Lease},
    maintenance, progress, runtime,
    store::{Config, Store},
    transport::Objects,
    Result,
};
use crate::vault::Vault;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
};

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn changed() -> super::CoreError {
    err(
        "syncRecoveryChanged",
        "云端状态已变化，未接管同步锁。请重新检查后确认。",
    )
}
fn candidate(store: &Store<'_>, cloud: &mut dyn Objects) -> Result<(Config, Head, Vec<u8>)> {
    if super::rekey::active(store)? {
        return Err(err("syncPasswordBusy", "请先完成本机修改 Key 任务。"));
    }
    let config = store.config()?;
    let (head, bytes) = control::read(cloud, &config.library)?.ok_or_else(|| {
        err(
            "syncRecoveryUnavailable",
            "云端没有需要恢复的旧锁，请使用立即同步。",
        )
    })?;
    head.verify(&config)?;
    if head.generation != config.generation || head.sequence != config.generation_sequence {
        return Err(err(
            "syncRecoveryVersion",
            "本机与云端数据版本不同，不能直接恢复旧锁，请先核对同步 Key 和数据版本。",
        ));
    }
    if head.version != 2 || head.lock.as_ref().is_none_or(|l| l.expires_at.is_some()) {
        return Err(err(
            "syncRecoveryUnavailable",
            "仅支持恢复旧版无到期时间的同步锁。没有旧锁时请使用立即同步；新版锁请等待超时。",
        ));
    }
    if head.lock.as_ref().is_none_or(|l| l.kind != "sync") {
        return Err(err(
            "syncRecoveryMigration",
            "此锁属于修改 Key 等任务，不能作为普通同步锁接管，请先检查迁移状态。",
        ));
    }
    Ok((config, head, bytes))
}
pub(super) fn inspect(store: &Store<'_>, cloud: &mut dyn Objects) -> Result<Value> {
    let (config, _, bytes) = candidate(store, cloud)?;
    Ok(
        json!({"expectedHead":digest(&bytes),"library":config.library,
        "message":"确认其他所有设备已停止同步？将先备份本机数据库及当前云端密文，校验通过后恢复旧锁并同步。若云端状态变化则停止。完成后请先升级其他客户端，再重新开启同步。"}),
    )
}
fn inventory(cloud: &mut dyn Objects, config: &Config) -> Result<BTreeMap<String, String>> {
    let prefix = if config.generation.is_empty() {
        format!("tp1-{}-", config.library)
    } else {
        format!("tp1-{}-g-{}-", config.library, config.generation)
    };
    let mut names = BTreeMap::new();
    for physical in cloud.list()? {
        if let Some(suffix) = physical.strip_prefix(&prefix) {
            if ["chunk-", "batch-", "snapshot-", "receipt-"]
                .iter()
                .any(|k| suffix.starts_with(k))
            {
                if physical.len() > 300
                    || !physical
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.')
                    || !maintenance::content_object(&physical)
                {
                    return Err(err(
                        "syncRecoveryIntegrity",
                        "旧目录存在无法识别的数据对象，已停止恢复。",
                    ));
                }
                names.insert(format!("tp1-{}-{suffix}", config.library), physical);
            }
        }
    }
    Ok(names)
}
fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|_| err("syncBackup", "无法创建旧锁恢复备份，云端保持不变。"))?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| err("syncBackup", "旧锁恢复备份未完整写入，云端保持不变。"))
}
fn backup_folder(vault: &Vault) -> Result<PathBuf> {
    let path = vault
        .directory
        .join(format!("sync-lock-recovery-{}", uuid::Uuid::new_v4()));
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder
        .create(&path)
        .map_err(|_| err("syncBackup", "无法创建旧锁恢复备份目录。"))?;
    Ok(path)
}
pub(super) fn recover(
    vault: &Vault,
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    request: &Value,
) -> Result<Lease> {
    if request["confirmed"] != true || request["otherDevicesStopped"] != true {
        return Err(err(
            "syncConfirmation",
            "恢复旧锁前，请确认其他所有设备已停止同步。",
        ));
    }
    let (config, mut head, previous) = candidate(store, cloud)?;
    if request["expectedHead"].as_str() != Some(digest(&previous).as_str()) {
        return Err(changed());
    }
    lease::timeout(
        &json!({"lockTimeoutMinutes":config.lock_timeout_minutes}),
        60,
    )?;
    let _ = lease::cloud_time(cloud)?;
    let names = inventory(cloud, &config)?;
    let backup = backup_folder(vault)?;
    write_private(
        &backup.join("control.encrypted"),
        &store.encode(&json!({"control":previous,"config":config,"objects":names}))?,
    )?;
    let database = backup.join("vault.sqlite");
    write_private(&database, &[])?;
    store
        .db
        .backup(rusqlite::DatabaseName::Main, &database, None)
        .map_err(db_error)?;
    progress::stage("verifying", 0, Some(names.len()));
    for (index, physical) in names.values().enumerate() {
        let bytes = cloud
            .get(physical)?
            .ok_or_else(|| err("syncMissing", "旧目录数据缺失，已停止恢复。"))?;
        if !physical.ends_with(&format!("-{}.tps", digest(&bytes))) {
            return Err(err("syncIntegrity", "旧目录数据校验失败，已停止恢复。"));
        }
        write_private(&backup.join(physical), &bytes)?;
        progress::bytes("downloadedBytes", bytes.len());
        progress::bytes("verifiedBytes", bytes.len());
        progress::stage("verifying", index + 1, Some(names.len()));
    }
    // Verify manifests and every referenced chunk for locally available scope keys.
    // Disabled/unavailable scopes remain opaque and are retained byte-for-byte.
    {
        let mut ns = Namespace {
            cloud,
            library: config.library.clone(),
            generation: config.generation.clone(),
            guard: None,
        };
        for name in names.keys() {
            if let Some(scope) = config.scope_keys.keys().find(|scope| {
                ["batch", "snapshot", "receipt"].iter().any(|kind| {
                    name.starts_with(&format!("tp1-{}-{kind}-{scope}-", config.library))
                })
            }) {
                let (manifest, _, _) =
                    runtime::open_document_with(&config, &mut ns, name, scope, None)?;
                if manifest
                    .chunks
                    .iter()
                    .any(|chunk| !names.contains_key(chunk))
                {
                    return Err(err(
                        "syncMissing",
                        "旧目录仍有未完整发布的分块，已停止恢复。",
                    ));
                }
            }
        }
    }
    if inventory(cloud, &config)? != names
        || cloud.get(&control::name(&config.library))?.as_deref() != Some(&previous)
    {
        return Err(changed());
    }
    cloud.check_conditionals(&config.library)?;
    head.catalog = Some(lease::catalog_build(
        cloud,
        &config.library,
        &config.generation,
        names.keys().cloned().collect(),
    )?);
    // Check the legacy inventory once more after staging the catalog. User confirmation
    // that legacy writers are stopped is required because v2 did not fence data PUTs.
    if inventory(cloud, &config)? != names {
        return Err(changed());
    }
    cloud.get(&control::name(&config.library))?;
    let now = lease::cloud_time(cloud)?;
    let token = uuid::Uuid::new_v4().to_string();
    head.version = 4;
    head.lock = Some(Lock {
        device: config.device.clone(),
        token: token.clone(),
        kind: "sync".into(),
        expires_at: Some(now + i64::from(config.lock_timeout_minutes) * 60),
        timeout_minutes: Some(config.lock_timeout_minutes),
    });
    let next = head.signed(&config)?;
    store.put("cloudLockPending", &token)?;
    store.put(
        "lockRecoveryBackup",
        &json!({"directory":backup,"at":now,"phase":"prepared"}),
    )?;
    match cloud.compare_exchange(&control::name(&config.library), Some(&previous), &next) {
        Ok(true) => {}
        Ok(false) => return Err(changed()),
        Err(error) => {
            if cloud.get(&control::name(&config.library))?.as_deref() != Some(&next) {
                return Err(error);
            }
        }
    }
    // Persist the ownership token even when a successful CAS reply was lost.
    store.put("cloudLockToken", &token)?;
    store.remove("cloudLockPending")?;
    store.put("remoteSyncBusy", &Value::Null)?;
    store.put(
        "lockRecoveryBackup",
        &json!({"directory":backup,"at":now,"phase":"recovered"}),
    )?;
    Lease::start(config, head, next, cloud)
}
