//! Resumable full re-encryption. Passwords and plaintext never enter the cloud;
//! only derived keys are checkpointed, encrypted with the existing device key.
use super::{
    control::{self, Namespace},
    db_error, err, policy, runtime,
    store::{Config, Store},
    transport::Objects,
    Result,
};
use crate::vault::Vault;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Serialize, Deserialize)]
struct Job {
    id: String,
    phase: String,
    source_generation: String,
    source_sequence: u64,
    target_generation: String,
    old_keys: BTreeMap<String, Vec<u8>>,
    new_keys: BTreeMap<String, Vec<u8>>,
    #[serde(default)]
    inventory: Vec<String>,
}
fn tables(store: &Store<'_>) -> Result<()> {
    store.db.execute_batch("CREATE TABLE IF NOT EXISTS tp_sync_rekey_source(name TEXT PRIMARY KEY,payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS tp_sync_rekey_docs(source TEXT PRIMARY KEY,target TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS tp_sync_rekey_objects(name TEXT PRIMARY KEY,payload BLOB NOT NULL,verified INTEGER NOT NULL DEFAULT 0);").map_err(db_error)
}
pub(super) fn active(store: &Store<'_>) -> Result<bool> {
    Ok(store.get::<Job>("passwordJob")?.is_some())
}
pub(super) fn progress(store: &Store<'_>) -> Result<Value> {
    Ok(store
        .get::<Value>("passwordProgress")?
        .unwrap_or(Value::Null))
}
fn update(
    store: &Store<'_>,
    phase: &str,
    percent: u64,
    done: u64,
    total: u64,
    bytes: u64,
) -> Result<()> {
    store.put("passwordProgress",&json!({"active":true,"phase":phase,"percent":percent.min(99),"completed":done,"total":total,"verifiedBytes":bytes,"error":Value::Null}))
}
pub(super) fn failed(store: &Store<'_>, error: &super::CoreError) -> Result<()> {
    if !active(store)? {
        return Ok(());
    }
    if error.code == "syncPasswordChanged" {
        store.remove("passwordJob")?;
        store.put(
            "passwordProgress",
            &json!({"active":false,"phase":"failed","error":error.message}),
        )?;
        return Ok(());
    }
    let mut value = progress(store)?;
    value["error"] = json!(error.message);
    value["active"] = json!(true);
    value["canResume"] = json!(true);
    store.put("passwordProgress", &value)
}
fn backup(vault: &Vault, store: &Store<'_>) -> Result<()> {
    let id = uuid::Uuid::new_v4();
    for (name, db) in [("vault", Some(&vault.db)), ("ai", None)] {
        let ai;
        let db = if let Some(db) = db {
            db
        } else {
            let path = vault.directory.join("ai.sqlite");
            if !path.exists() {
                continue;
            }
            ai = rusqlite::Connection::open(path).map_err(db_error)?;
            &ai
        };
        let path = vault
            .directory
            .join(format!("{name}.before-sync-password-{id}.sqlite"));
        db.backup(rusqlite::DatabaseName::Main, &path, None)
            .map_err(db_error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| err("syncBackup", "无法保护修改 Key 备份。"))?;
        }
    }
    store.put("passwordBackup", &id.to_string())
}
pub(super) fn validate(
    store: &Store<'_>,
    request: &Value,
) -> Result<(Config, BTreeMap<String, Vec<u8>>, BTreeMap<String, Vec<u8>>)> {
    if active(store)? {
        return Err(err(
            "syncPasswordBusy",
            "上次修改 Key 尚未完成，请继续该任务。",
        ));
    }
    if request["confirmed"] != true || request["clientsUpdated"] != true {
        return Err(err(
            "syncConfirmation",
            "请确认所有同步设备已升级，并在修改 Key 完成前保持本页面打开。",
        ));
    }
    let old = request["oldPassphrase"].as_str().unwrap_or("");
    let new = request["newPassphrase"].as_str().unwrap_or("");
    if new != request["confirmPassphrase"].as_str().unwrap_or("") {
        return Err(err("syncPassword", "两次新 Key 输入不一致。"));
    }
    if old == new {
        return Err(err("syncPassword", "新 Key 不能与原 Key 相同。"));
    }
    let config = store.config()?;
    let old_keys = runtime::derive_keys(old, &config.library)?;
    if old_keys.get("configuration") != config.scope_keys.get("configuration") {
        return Err(err(
            "syncPassword",
            "原同步 Key 不正确，尚未修改任何云端数据。",
        ));
    }
    let new_keys = runtime::derive_keys(new, &config.library)?;
    Ok((config, old_keys, new_keys))
}
pub(super) fn begin(vault: &Vault, store: &Store<'_>, request: &Value) -> Result<Value> {
    let (config, old_keys, new_keys) = validate(store, request)?;
    backup(vault, store)?;
    tables(store)?;
    let job = Job {
        id: uuid::Uuid::new_v4().to_string(),
        phase: "preparing".into(),
        source_generation: config.generation.clone(),
        source_sequence: config.generation_sequence,
        target_generation: uuid::Uuid::new_v4().to_string(),
        old_keys,
        new_keys,
        inventory: Vec::new(),
    };
    store.transaction(||{
        store.db.execute_batch("DELETE FROM tp_sync_rekey_docs; DELETE FROM tp_sync_rekey_objects; DELETE FROM tp_sync_rekey_source;").map_err(db_error)?;
        store.put("passwordJob",&job)?;update(store,"preparing",1,0,0,0)
    })?;
    progress(store)
}
fn configs(store: &Store<'_>, job: &Job) -> Result<(Config, Config)> {
    let mut old = store.config()?;
    old.generation = job.source_generation.clone();
    old.generation_sequence = job.source_sequence;
    old.scope_keys = job.old_keys.clone();
    let mut new = old.clone();
    new.generation = job.target_generation.clone();
    new.generation_sequence = job
        .source_sequence
        .checked_add(1)
        .ok_or_else(|| err("syncVersion", "同步密钥版本超出范围。"))?;
    new.scope_keys = job.new_keys.clone();
    Ok((old, new))
}
fn object_kind<'a>(library: &str, name: &'a str) -> Option<(&'a str, &'a str)> {
    let suffix = name.strip_prefix(&format!("tp1-{library}-"))?;
    for kind in ["batch", "snapshot", "receipt"] {
        let rest = suffix.strip_prefix(&format!("{kind}-"));
        if let Some(rest) = rest {
            for scope in policy::SCOPES {
                if rest.starts_with(&format!("{scope}-")) {
                    return Some((kind, *scope));
                }
            }
        }
    }
    None
}
fn inventory(cloud: &mut dyn Objects) -> Result<Vec<String>> {
    let mut names = cloud.list()?;
    names.sort();
    names.dedup();
    Ok(names)
}
/// Re-encrypt only unpublished work; acknowledged history already exists in the
/// new generation. Republishing every peer's history would multiply cloud data.
/// This deliberately keeps operation IDs, causal clocks, tombstones and local
/// journals: an offline peer's unsent work must not be replaced by a snapshot.
pub(super) fn switch_local(store: &Store<'_>, mut config: Config) -> Result<()> {
    let previous = store.config()?;
    config.scopes = previous.scopes.clone();
    config.auto = previous.auto;
    config
        .scope_keys
        .retain(|scope, _| config.scopes.contains(scope));
    let catalog = store.get::<Vec<Value>>("snapshots")?.unwrap_or_default();
    let mut pending = store
        .db
        .prepare("SELECT name FROM tp_sync_objects WHERE kind='snapshot' AND published=0")
        .map_err(db_error)?;
    let pending = pending
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<rusqlite::Result<BTreeSet<_>>>()
        .map_err(db_error)?;
    store.transaction(||{
        store.put("config",&config)?;
        store.db.execute_batch("DELETE FROM tp_sync_received; DELETE FROM tp_sync_objects; DELETE FROM tp_sync_object_ops;").map_err(db_error)?;
        store.put("snapshots",&Vec::<Value>::new())?;
        for snapshot in &catalog {
            for object in snapshot["objects"].as_array().into_iter().flatten() {
                let Some(scope)=object["scope"].as_str().filter(|scope|config.scopes.iter().any(|s|s==scope)) else{continue};
                let Some(name)=object["name"].as_str() else{continue};
                if !pending.contains(name) {continue;}
                if let Some(state)=store.get::<super::model::State>(&format!("snapshot:{name}"))? {
                    let value=json!({"id":snapshot["id"],"at":snapshot["at"],"scopes":snapshot["scopes"],"state":state});
                    let (_,objects)=runtime::encode_document(&config,scope,"snapshot",&value)?;
                    for (name,payload,kind,scope) in objects {store.db.execute("INSERT OR IGNORE INTO tp_sync_objects(name,payload,kind,scope) VALUES(?1,?2,?3,?4)",params![name,payload,kind,scope]).map_err(db_error)?;}
                }
            }
        }
        // A newly joining replica has no published history to preserve yet.
        // Publishing an empty checkpoint here would clutter cloud history before
        // the verified generation has even been downloaded.
        if config.scopes.iter().any(|scope| store.published_state(scope).map(|state| !state.frontier.is_empty()).unwrap_or(true)) {
            runtime::maybe_snapshot(store,true)?;
        }
        store.put("passwordRequired",&false)?;store.put("lastError",&Value::Null)?;
        store.put("nextAttempt",&0i64)?;
        Ok(())
    })
}
pub(super) fn adopt_matching(store: &Store<'_>, cloud: &mut dyn Objects) -> Result<()> {
    let mut config = store.config()?;
    let Some((head, _)) = control::read(cloud, &config.library)? else {
        return Ok(());
    };
    if head.generation == config.generation && head.sequence == config.generation_sequence {
        return Ok(());
    }
    if head.sequence < config.generation_sequence || head.verify(&config).is_err() {
        return Ok(());
    }
    if head.lock.as_ref().is_some_and(|lock| {
        head.version < 3
            || lock
                .expires_at
                .is_none_or(|expiry| cloud.server_time().is_none_or(|now| now < expiry))
    }) {
        return Err(err("syncCloudBusy", "其它设备尚未完成同步，请稍后重试。"));
    }
    config.generation = head.generation;
    config.generation_sequence = head.sequence;
    switch_local(store, config)
}
pub(super) fn unlock(store: &Store<'_>, cloud: &mut dyn Objects, password: &str) -> Result<()> {
    if active(store)? {
        return Err(err("syncPasswordBusy", "请先完成当前设备的修改 Key 任务。"));
    }
    let mut config = store.config()?;
    config.scope_keys = runtime::derive_keys(password, &config.library)?;
    let (head, _) = control::read(cloud, &config.library)?.ok_or_else(|| {
        err(
            "syncControl",
            "云端尚无可验证的 Key 版本，请先在原设备完成同步。",
        )
    })?;
    head.verify(&config)?;
    if head.sequence < config.generation_sequence {
        return Err(err("syncRollback", "云端 Key 版本回退，已停止同步。"));
    }
    if head.lock.as_ref().is_some_and(|lock| {
        head.version < 3
            || lock
                .expires_at
                .is_none_or(|expiry| cloud.server_time().is_none_or(|now| now < expiry))
    }) {
        return Err(err(
            "syncCloudBusy",
            "其它设备尚未完成同步或修改 Key，请稍后重试。",
        ));
    }
    if head.sequence == config.generation_sequence
        && head.generation == config.generation
        && config.scope_keys.get("configuration") == store.config()?.scope_keys.get("configuration")
    {
        store.put("passwordRequired", &false)?;
        return Ok(());
    }
    config.generation = head.generation;
    config.generation_sequence = head.sequence;
    switch_local(store, config)
}
pub(super) fn resume(vault: &Vault, store: &Store<'_>, cloud: &mut dyn Objects) -> Result<Value> {
    tables(store)?;
    let mut job = store
        .get::<Job>("passwordJob")?
        .ok_or_else(|| err("syncPasswordBusy", "没有待继续的修改 Key 任务。"))?;
    let (old, new) = configs(store, &job)?;
    // A lost response after cloud commit must not re-encrypt again or revert it.
    if let Some((head, _)) = control::read(cloud, &old.library)? {
        if head.generation == new.generation && head.sequence == new.generation_sequence {
            head.verify(&new)?;
            return finish(vault, store, cloud, new);
        }
    }
    update(store, "locking", 3, 0, 0, 0)?;
    let lease = control::acquire(store, cloud, "password")?;
    if lease.head()?.bundles.is_some() {
        let ai = runtime::ai_database(vault)?;
        runtime::drain(store, ai.as_ref())?;
        super::bundle::run(vault, store, cloud, &lease)?;
        super::bundle::rotate(store, cloud, &lease, &old, &new)?;
        drop(lease);
        return finish(vault, store, cloud, new);
    }
    let guard = Some(&lease);
    if job.phase == "preparing" {
        update(store, "synchronizing", 8, 0, 0, 0)?;
        let ai = runtime::ai_database(vault)?;
        runtime::drain(store, ai.as_ref())?;
        let mut source = Namespace {
            cloud,
            library: old.library.clone(),
            generation: old.generation.clone(),
            guard: guard.clone(),
        };
        runtime::exchange(store, &mut source)?;
        runtime::exchange(store, &mut source)?;
        job.inventory = inventory(&mut source)?;
        job.phase = "migrating".into();
        store.put("passwordJob", &job)?;
    }
    if job.phase == "migrating" {
        let mut source = Namespace {
            cloud,
            library: old.library.clone(),
            generation: old.generation.clone(),
            guard: guard.clone(),
        };
        let current = inventory(&mut source)?;
        if job.inventory.iter().any(|name| !current.contains(name)) {
            return Err(err(
                "syncRollback",
                "迁移源对象缺失，请恢复云端数据后继续。",
            ));
        }
        if current != job.inventory {
            job.inventory = current;
            store.put("passwordJob", &job)?;
        }
    }
    // A newer client may introduce a scope we cannot understand. Never switch
    // to a generation that silently omits those manifests.
    for name in &job.inventory {
        if !name.starts_with(&format!("tp1-{}-chunk-", old.library))
            && object_kind(&old.library, name).is_none()
        {
            return Err(err(
                "syncVersion",
                "云端包含此版本无法迁移的数据范围，请升级应用后继续修改 Key。",
            ));
        }
    }
    // Finish downloading ALL old ciphertext before any re-encryption or upload.
    // The same inventory is retained across restarts; no decrypted document is
    // written into the migration cache.
    for (index, name) in job.inventory.iter().enumerate() {
        let cached: bool = store
            .db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM tp_sync_rekey_source WHERE name=?1)",
                [name],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        update(
            store,
            "downloading",
            10 + 25 * index as u64 / (job.inventory.len() as u64).max(1),
            index as u64,
            job.inventory.len() as u64,
            0,
        )?;
        if cached {
            continue;
        }
        let mut source = Namespace {
            cloud,
            library: old.library.clone(),
            generation: old.generation.clone(),
            guard: guard.clone(),
        };
        source.check()?;
        let bytes = source
            .get(name)?
            .ok_or_else(|| err("syncMissing", "旧密文尚未完整下载，请重试。"))?;
        use sha2::{Digest, Sha256};
        if !name.ends_with(&format!("-{}.tps", hex::encode(Sha256::digest(&bytes)))) {
            return Err(err("syncIntegrity", "旧密文校验失败，已停止修改 Key。"));
        }
        store
            .db
            .execute(
                "INSERT INTO tp_sync_rekey_source VALUES(?1,?2)",
                params![name, bytes],
            )
            .map_err(db_error)?;
    }
    let mut docs: Vec<String> = job
        .inventory
        .iter()
        .filter(|name| object_kind(&old.library, name).is_some())
        .cloned()
        .collect();
    docs.sort_by_key(|name| (name.contains("-receipt-"), name.clone()));
    let total = docs.len() as u64;
    for (index, name) in docs.iter().enumerate() {
        let done: bool = store
            .db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM tp_sync_rekey_docs WHERE source=?1)",
                [name],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if done {
            continue;
        }
        update(
            store,
            "reencrypting",
            35 + 20 * index as u64 / total.max(1),
            index as u64,
            total,
            0,
        )?;
        let (_, scope) = object_kind(&old.library, name).unwrap();
        let mut source = Downloaded { store };
        let (manifest, mut value, _) =
            runtime::open_document_with(&old, &mut source, name, scope, None)?;
        if manifest.kind == "receipt" {
            let reference = value["source"]
                .as_str()
                .ok_or_else(|| err("syncReceipt", "确认记录缺少增量来源。"))?;
            let mapped: Option<String> = store
                .db
                .query_row(
                    "SELECT target FROM tp_sync_rekey_docs WHERE source=?1",
                    [reference],
                    |r| r.get(0),
                )
                .optional()
                .map_err(db_error)?;
            value["source"] = json!(mapped.ok_or_else(|| err(
                "syncReceipt",
                "确认记录指向缺失的增量批次，修改 Key 已暂停。"
            ))?);
        }
        if manifest.kind == "snapshot" && value.get("id").is_none() {
            value = json!({"id":name,"state":value,"scopes":[scope]});
        }
        let (target, objects) = runtime::encode_document(&new, scope, &manifest.kind, &value)?;
        store.transaction(|| {
            for (name, payload, _, _) in objects {
                store
                    .db
                    .execute(
                        "INSERT OR IGNORE INTO tp_sync_rekey_objects(name,payload) VALUES(?1,?2)",
                        params![name, payload],
                    )
                    .map_err(db_error)?;
            }
            store
                .db
                .execute(
                    "INSERT INTO tp_sync_rekey_docs VALUES(?1,?2)",
                    params![name, target],
                )
                .map_err(db_error)?;
            Ok(())
        })?;
    }
    let (count, bytes): (u64, u64) = store
        .db
        .query_row(
            "SELECT COUNT(*),COALESCE(SUM(LENGTH(payload)),0) FROM tp_sync_rekey_objects",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(db_error)?;
    let mut names=store.db.prepare("SELECT name FROM tp_sync_rekey_objects ORDER BY CASE WHEN name LIKE '%-chunk-%' THEN 0 ELSE 1 END,name").map_err(db_error)?;
    let names = names
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(db_error)?;
    let mut uploaded = 0;
    let mut transferred = 0;
    for name in &names {
        let (payload, _verified): (Vec<u8>, bool) = store
            .db
            .query_row(
                "SELECT payload,verified FROM tp_sync_rekey_objects WHERE name=?1",
                [name],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(db_error)?;
        // Re-read checkpoints on every resumed run. The cloud may have lost an
        // object while this device was offline; a local verified bit is insufficient.
        update(
            store,
            "uploading",
            55 + 37 * uploaded / count.max(1),
            uploaded,
            count,
            transferred,
        )?;
        let mut target = Namespace {
            cloud,
            library: new.library.clone(),
            generation: new.generation.clone(),
            guard: guard.clone(),
        };
        target.put(name, &payload)?;
        if target.get(name)?.as_deref() != Some(&payload) {
            return Err(err(
                "syncVerify",
                "新密文回读校验失败，原同步版本保持不变。",
            ));
        }
        store
            .db
            .execute(
                "UPDATE tp_sync_rekey_objects SET verified=1 WHERE name=?1",
                [name],
            )
            .map_err(db_error)?;
        uploaded += 1;
        transferred += payload.len() as u64;
    }
    update(store, "verifying", 94, count, count, bytes)?;
    let mut source = Namespace {
        cloud,
        library: old.library.clone(),
        generation: old.generation.clone(),
        guard: guard.clone(),
    };
    if inventory(&mut source)? != job.inventory {
        return Err(err(
            "syncLegacyWriter",
            "迁移期间旧区域出现变化。请停止旧版客户端同步，升级所有设备后重试；原数据已保留。",
        ));
    }
    let mut target = Namespace {
        cloud,
        library: new.library.clone(),
        generation: new.generation.clone(),
        guard,
    };
    let listed: BTreeSet<_> = target.list()?.into_iter().collect();
    if names.iter().any(|name| !listed.contains(name)) {
        return Err(err("syncVerify", "云端新版本缺少对象，尚未切换。"));
    }
    target.check()?;
    update(store, "switching", 97, count, count, bytes)?;
    lease.cutover(cloud, &new, names)?;
    drop(lease);
    finish(vault, store, cloud, new)
}
fn finish(vault: &Vault, store: &Store<'_>, cloud: &mut dyn Objects, new: Config) -> Result<Value> {
    update(store, "finishing", 99, 0, 0, 0)?;
    if store.config()?.generation != new.generation {
        switch_local(store, new)?;
    }
    // Keep the durable job until native rows and snapshot catalogs are usable
    // under the new generation, including recovery after a lost cutover reply.
    let config = store.config()?;
    let lease = control::acquire(store, cloud, "password-finishing")?;
    if lease.head()?.bundles.is_some() {
        super::bundle::run(vault, store, cloud, &lease)?;
    } else {
        let mut target = Namespace {
            cloud,
            library: config.library,
            generation: config.generation,
            guard: Some(&lease),
        };
        runtime::exchange(store, &mut target)?;
        runtime::exchange(store, &mut target)?;
    }
    runtime::project_current(vault, store)?;
    control::release(store, cloud, &lease)?;
    store.transaction(||{
        store.remove("passwordJob")?;
        store.remove("cloudLockToken")?;
        store.db.execute_batch("DELETE FROM tp_sync_rekey_docs; DELETE FROM tp_sync_rekey_objects; DELETE FROM tp_sync_rekey_source;").map_err(db_error)?;
        store.put("passwordProgress",&json!({"active":false,"phase":"completed","percent":100,"error":Value::Null}))
    })?;
    progress(store)
}

struct Downloaded<'a, 'b> {
    store: &'a Store<'b>,
}
impl Objects for Downloaded<'_, '_> {
    fn list(&mut self) -> Result<Vec<String>> {
        let mut statement = self
            .store
            .db
            .prepare("SELECT name FROM tp_sync_rekey_source ORDER BY name")
            .map_err(db_error)?;
        let names = statement
            .query_map([], |r| r.get(0))
            .map_err(db_error)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(db_error)?;
        Ok(names)
    }
    fn get(&mut self, name: &str) -> Result<Option<Vec<u8>>> {
        self.store
            .db
            .query_row(
                "SELECT payload FROM tp_sync_rekey_source WHERE name=?1",
                [name],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)
    }
    fn put(&mut self, _: &str, _: &[u8]) -> Result<()> {
        Err(err("syncInternal", "旧密文缓存只读。"))
    }
    fn server_time(&self) -> Option<i64> {
        None
    }
}
