//! Named destinations. Only the selected profile occupies the engine's working
//! tables; inactive tables are archived transactionally without decoding secrets.
use super::{
    db_error, err, journal, runtime,
    store::{Config, Store},
    transport::{Backend, Provider},
    Result,
};
use crate::vault::Vault;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const TABLES: &[&str] = &[
    "values",
    "operations",
    "object_ops",
    "objects",
    "received",
    "cursors",
    "actions",
];
#[derive(Default, Serialize, Deserialize)]
struct Profile {
    title: String,
    #[serde(default)]
    baseline: Vec<journal::CapturedRow>,
    #[serde(default)]
    preferences: Value,
}

pub(super) fn prepare(vault: &Vault, store: &Store<'_>) -> Result<()> {
    let installed: bool = store
        .db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='tp_sync_profiles')",
            [],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !installed && store.get::<Config>("config")?.is_some() {
        backup(vault, store, "vault.before-sync-profiles.sqlite")?;
    }
    schema(store)
}
fn schema(store: &Store<'_>) -> Result<()> {
    store.db.execute_batch("CREATE TABLE IF NOT EXISTS tp_sync_profiles(id TEXT PRIMARY KEY,payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS tp_sync_selection(id INTEGER PRIMARY KEY CHECK(id=1),profile TEXT NOT NULL);").map_err(db_error)?;
    for table in TABLES {
        store.db.execute_batch(&format!("CREATE TABLE IF NOT EXISTS tp_sync_saved_{table} AS SELECT CAST('' AS TEXT) AS profile, * FROM tp_sync_{table} WHERE 0;
            CREATE INDEX IF NOT EXISTS tp_sync_saved_{table}_profile ON tp_sync_saved_{table}(profile);")).map_err(db_error)?;
    }
    Ok(())
}
pub(super) fn active(store: &Store<'_>) -> Result<Option<String>> {
    store
        .db
        .query_row(
            "SELECT profile FROM tp_sync_selection WHERE id=1",
            [],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)
}
fn read(store: &Store<'_>, id: &str) -> Result<Profile> {
    let bytes: Vec<u8> = store
        .db
        .query_row(
            "SELECT payload FROM tp_sync_profiles WHERE id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?
        .ok_or_else(|| err("syncProfileMissing", "云服务配置不存在，请刷新列表。"))?;
    store.decode(&bytes)
}
fn save(store: &Store<'_>, id: &str, profile: &Profile) -> Result<()> {
    store.db.execute("INSERT INTO tp_sync_profiles VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", params![id, store.encode(profile)?]).map_err(db_error)?;
    Ok(())
}
fn value<T: serde::de::DeserializeOwned>(
    store: &Store<'_>,
    id: &str,
    key: &str,
) -> Result<Option<T>> {
    if active(store)?.as_deref() == Some(id) {
        return store.get(key);
    }
    let bytes: Option<Vec<u8>> = store
        .db
        .query_row(
            "SELECT payload FROM tp_sync_saved_values WHERE profile=?1 AND id=?2",
            params![id, key],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    bytes.map(|b| store.decode(&b)).transpose()
}
fn put<T: Serialize>(store: &Store<'_>, id: &str, key: &str, content: &T) -> Result<()> {
    if active(store)?.as_deref() == Some(id) {
        return store.put(key, content);
    }
    store
        .db
        .execute(
            "DELETE FROM tp_sync_saved_values WHERE profile=?1 AND id=?2",
            params![id, key],
        )
        .map_err(db_error)?;
    store
        .db
        .execute(
            "INSERT INTO tp_sync_saved_values VALUES(?1,?2,?3)",
            params![id, key, store.encode(content)?],
        )
        .map_err(db_error)?;
    Ok(())
}
pub(super) fn config(store: &Store<'_>, id: &str) -> Result<Config> {
    value(store, id, "config")?
        .ok_or_else(|| err("syncProfileMissing", "云服务配置不存在，请刷新列表。"))
}
fn backup(vault: &Vault, store: &Store<'_>, name: &str) -> Result<()> {
    let path = vault.directory.join(name);
    if path.exists() {
        return Ok(());
    }
    store
        .db
        .backup(rusqlite::DatabaseName::Main, &path, None)
        .map_err(db_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| err("syncBackup", "无法保护同步配置备份。"))?;
    }
    Ok(())
}
/// Preserve old singleton databases exactly once, before assigning their identity.
pub(super) fn ensure(vault: &Vault, store: &Store<'_>) -> Result<()> {
    if active(store)?.is_some() || store.get::<Config>("config")?.is_none() {
        return Ok(());
    }
    backup(vault, store, "vault.before-sync-profiles.sqlite")?;
    store.transaction(|| {
        if active(store)?.is_none() {
            let config = store.config()?;
            let id = uuid::Uuid::new_v4().to_string();
            save(
                store,
                &id,
                &Profile {
                    title: format!("{} · {}", config.provider.label(), config.name),
                    ..Default::default()
                },
            )?;
            store
                .db
                .execute("INSERT INTO tp_sync_selection VALUES(1,?1)", [&id])
                .map_err(db_error)?;
        }
        Ok(())
    })
}
pub(super) fn list(store: &Store<'_>) -> Result<Vec<Value>> {
    let selected = active(store)?;
    let mut q = store
        .db
        .prepare("SELECT id FROM tp_sync_profiles ORDER BY rowid")
        .map_err(db_error)?;
    let ids = q
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(db_error)?;
    ids.iter().map(|id| {
        let p = read(store, id)?;
        let c = config(store, id)?;
        let selected = selected.as_deref() == Some(id.as_str());
        let pending: i64 = if selected {
            store.db.query_row("SELECT COUNT(*) FROM tp_sync_operations WHERE published=0", [], |r| r.get(0))
        } else {
            store.db.query_row("SELECT COUNT(*) FROM tp_sync_saved_operations WHERE profile=?1 AND published=0", [id], |r| r.get(0))
        }.map_err(db_error)?;
        Ok(json!({"id":id,"title":p.title,"active":selected,"provider":c.provider.public(),"library":c.library,"name":c.name,"auto":c.auto,"scopes":c.scopes,"pending":pending}))
    }).collect()
}
fn title(request: &Value) -> Result<String> {
    request["title"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.chars().count() <= 100)
        .map(str::to_owned)
        .ok_or_else(|| err("syncProfileName", "请填写 1–100 个字符的云服务名称。"))
}
fn require_confirmation(request: &Value) -> Result<()> {
    if request["confirmed"] != true {
        return Err(err("syncConfirmation", "请确认云服务配置和本机数据合并。"));
    }
    Ok(())
}
pub(super) fn blocked(store: &Store<'_>, id: &str) -> Result<()> {
    let progress: Value = value(store, id, "passwordProgress")?.unwrap_or(Value::Null);
    // Use the same persisted job as the password engine, including failed/retry states.
    if value::<Value>(store, id, "passwordJob")?.is_some() || progress["active"] == true {
        return Err(err(
            "syncPasswordBusy",
            "请先完成当前云服务的 Key 修改，再切换或删除配置。",
        ));
    }
    Ok(())
}
/// Empty secrets mean keep, but only within the same endpoint/account. Credentials
/// are never silently sent to an edited hostname or a different provider kind.
pub(super) fn merge_provider(old: &Provider, input: &Value) -> Result<Provider> {
    let previous =
        serde_json::to_value(old).map_err(|_| err("syncProvider", "云服务配置无效。"))?;
    let same_account = ["kind", "endpoint", "username", "auth_type"]
        .iter()
        .all(|key| {
            input.get(*key).and_then(Value::as_str).unwrap_or("")
                == previous.get(*key).and_then(Value::as_str).unwrap_or("")
        });
    let mut next = input.clone();
    if same_account {
        for key in [
            "password",
            "token",
            "access_key",
            "secret_key",
            "session_token",
        ] {
            if next
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or("")
                .is_empty()
            {
                if let Some(secret) = previous.get(key) {
                    next[key] = secret.clone();
                }
            }
        }
    }
    serde_json::from_value(next).map_err(|_| err("syncProvider", "云服务配置不完整。"))
}

pub(super) fn dispatch(vault: &Vault, store: &Store<'_>, request: &Value) -> Result<()> {
    require_confirmation(request)?;
    let method = request["method"].as_str().unwrap_or("");
    let id = request["id"].as_str().unwrap_or("");
    match method {
        "sync.profile.add" => {
            let password = request["passphrase"].as_str().unwrap_or("");
            if password.chars().count() < 12 {
                return Err(err("syncPassword", "同步 Key 至少需要 12 个字符。"));
            }
            let title = title(request)?;
            let library = match request["library"].as_str().filter(|s| !s.trim().is_empty()) {
                Some(id) => uuid::Uuid::parse_str(id.trim())
                    .map_err(|_| err("syncLibrary", "同步库 ID 无效。"))?,
                None => uuid::Uuid::new_v4(),
            }
            .to_string();
            let scopes = runtime::parse_scopes(&request["scopes"])?;
            let provider: Provider = serde_json::from_value(request["provider"].clone())
                .map_err(|_| err("syncProvider", "云服务配置不完整。"))?;
            let _ = Backend::new(provider.clone(), &library)?;
            let mut scope_keys = runtime::derive_keys(password, &library)?;
            scope_keys.retain(|scope, _| scopes.contains(scope));
            let config = Config {
                library,
                generation: String::new(),
                generation_sequence: 0,
                device: uuid::Uuid::new_v4().to_string(),
                name: request["name"].as_str().unwrap_or("TermPilot").into(),
                auto: request["auto"] == true,
                scopes,
                retention_days: Some(30),
                scope_keys,
                provider,
            };
            let id = uuid::Uuid::new_v4().to_string();
            store.transaction(|| {
                save(
                    store,
                    &id,
                    &Profile {
                        title,
                        ..Default::default()
                    },
                )?;
                put(store, &id, "config", &config)
            })?;
        }
        "sync.profile.update" => {
            let mut profile = read(store, id)?;
            let mut c = config(store, id)?;
            blocked(store, id)?;
            profile.title = title(request)?;
            if request["library"].as_str().is_some_and(|s| s != c.library) {
                return Err(err(
                    "syncLibrary",
                    "已有配置的同步库 ID 不能修改；请新增配置以连接其它同步库。",
                ));
            }
            let provider = merge_provider(&c.provider, &request["provider"])?;
            let _ = Backend::new(provider.clone(), &c.library)?;
            let moved = provider.public() != c.provider.public();
            if moved && value::<String>(store, id, "cloudLockToken")?.is_some() {
                return Err(err(
                    "syncCloudBusy",
                    "此配置有未完成的云端操作，请先使用原位置完成一次同步。",
                ));
            }
            let scopes = runtime::parse_scopes(&request["scopes"])?;
            let added: Vec<_> = scopes
                .iter()
                .filter(|s| !c.scopes.contains(s))
                .cloned()
                .collect();
            if !added.is_empty() {
                let keys =
                    runtime::derive_keys(request["passphrase"].as_str().unwrap_or(""), &c.library)?;
                if keys.get("configuration") != c.scope_keys.get("configuration") {
                    return Err(err("syncPassword", "重新启用范围需要正确的同步 Key。"));
                }
                for scope in &added {
                    c.scope_keys.insert(scope.clone(), keys[scope].clone());
                }
            }
            let is_active = active(store)?.as_deref() == Some(id);
            let ai = runtime::ai_database(vault)?;
            if is_active {
                runtime::drain(store, ai.as_ref())?;
            }
            if moved {
                backup(
                    vault,
                    store,
                    &format!(
                        "vault.before-sync-profile-edit-{}.sqlite",
                        uuid::Uuid::new_v4()
                    ),
                )?;
            }
            c.provider = provider;
            c.scopes = scopes;
            c.auto = request["auto"] == true;
            c.name = request["name"].as_str().unwrap_or(&c.name).into();
            store.transaction(|| {
                save(store, id, &profile)?;
                put(store, id, "config", &c)?;
                if moved {
                    put(store, id, "allowControlCreate", &true)?;
                    if is_active {
                        store
                            .db
                            .execute("DELETE FROM tp_sync_received", [])
                            .map_err(db_error)?;
                        store
                            .db
                            .execute("UPDATE tp_sync_objects SET published=0", [])
                            .map_err(db_error)?;
                        runtime::maybe_snapshot(store, true)?;
                    } else {
                        store
                            .db
                            .execute("DELETE FROM tp_sync_saved_received WHERE profile=?1", [id])
                            .map_err(db_error)?;
                        store
                            .db
                            .execute(
                                "UPDATE tp_sync_saved_objects SET published=0 WHERE profile=?1",
                                [id],
                            )
                            .map_err(db_error)?;
                        put(store, id, "profileNeedsSnapshot", &true)?;
                    }
                }
                let mut pending: Vec<String> =
                    value(store, id, "profileSeedScopes")?.unwrap_or_default();
                pending.extend(added);
                pending.sort();
                pending.dedup();
                put(store, id, "profileSeedScopes", &pending)?;
                put(store, id, "nextAttempt", &0i64)?;
                put(store, id, "lastError", &Value::Null)
            })?;
            if is_active {
                activate(vault, store, Some(id))?;
            }
        }
        "sync.profile.use" => {
            read(store, id)?;
            activate(vault, store, Some(id))?;
        }
        "sync.profile.delete" => {
            read(store, id)?;
            blocked(store, id)?;
            if value::<String>(store, id, "cloudLockToken")?.is_some() {
                return Err(err(
                    "syncCloudBusy",
                    "此配置有未完成的云端操作，请先完成一次同步再移除。",
                ));
            }
            backup(
                vault,
                store,
                &format!(
                    "vault.before-sync-profile-delete-{}.sqlite",
                    uuid::Uuid::new_v4()
                ),
            )?;
            if active(store)?.as_deref() == Some(id) {
                activate(vault, store, None)?;
            }
            store.transaction(|| {
                store
                    .db
                    .execute("DELETE FROM tp_sync_profiles WHERE id=?1", [id])
                    .map_err(db_error)?;
                for table in TABLES {
                    store
                        .db
                        .execute(
                            &format!("DELETE FROM tp_sync_saved_{table} WHERE profile=?1"),
                            [id],
                        )
                        .map_err(db_error)?;
                }
                Ok(())
            })?;
        }
        _ => return Err(err("syncMethod", "不支持的云服务操作。")),
    }
    Ok(())
}

fn archive(store: &Store<'_>, id: &str) -> Result<()> {
    for table in TABLES {
        store
            .db
            .execute(
                &format!("DELETE FROM tp_sync_saved_{table} WHERE profile=?1"),
                [id],
            )
            .map_err(db_error)?;
        store
            .db
            .execute(
                &format!("INSERT INTO tp_sync_saved_{table} SELECT ?1,* FROM tp_sync_{table}"),
                [id],
            )
            .map_err(db_error)?;
    }
    Ok(())
}
fn load(store: &Store<'_>, id: Option<&str>) -> Result<()> {
    for table in TABLES {
        store
            .db
            .execute(&format!("DELETE FROM tp_sync_{table}"), [])
            .map_err(db_error)?;
        if let Some(id) = id {
            let mut q = store
                .db
                .prepare(&format!("PRAGMA table_info(tp_sync_{table})"))
                .map_err(db_error)?;
            let columns = q
                .query_map([], |r| r.get::<_, String>(1))
                .map_err(db_error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(db_error)?
                .join(",");
            store.db.execute(&format!("INSERT INTO tp_sync_{table} SELECT {columns} FROM tp_sync_saved_{table} WHERE profile=?1"), [id]).map_err(db_error)?;
            // The active working set is the sole authority; do not retain stale keys.
            store
                .db
                .execute(
                    &format!("DELETE FROM tp_sync_saved_{table} WHERE profile=?1"),
                    [id],
                )
                .map_err(db_error)?;
        }
    }
    Ok(())
}
fn skip_journal(store: &Store<'_>, source: &rusqlite::Connection) -> Result<()> {
    let (origin, seq): (String,i64) = source.query_row("SELECT origin,(SELECT COALESCE(MAX(id),0) FROM tp_sync_journal) FROM tp_sync_context WHERE id=1", [], |r| Ok((r.get(0)?,r.get(1)?))).map_err(db_error)?;
    store.db.execute("INSERT INTO tp_sync_cursors VALUES(?1,?2) ON CONFLICT(origin) DO UPDATE SET seq=excluded.seq", params![origin,seq]).map_err(db_error)?;
    Ok(())
}
fn activate(vault: &Vault, store: &Store<'_>, target: Option<&str>) -> Result<()> {
    let previous = active(store)?;
    if let Some(id) = &previous {
        blocked(store, id)?;
    }
    if let Some(id) = target {
        blocked(store, id)?;
    }
    let ai = runtime::ai_database(vault)?;
    let tx =
        rusqlite::Transaction::new_unchecked(store.db, rusqlite::TransactionBehavior::Immediate)
            .map_err(db_error)?;
    // Lock both native writers before draining and taking the baseline. The AI
    // context is tagged with a profile so a crash between commits cannot borrow
    // another library's causal vector (Store::drain has a conservative fallback).
    let ai_tx = ai
        .as_ref()
        .map(|db| {
            rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Immediate)
        })
        .transpose()
        .map_err(db_error)?;
    let mut current = journal::snapshot(store.db, false)?;
    if let Some(ai) = ai.as_ref() {
        current.extend(journal::snapshot(ai, true)?);
    }
    let prefs = store.get::<Value>("preferences")?.unwrap_or(json!({}));
    if let Some(id) = &previous {
        store.drain(store.db)?;
        if let Some(ai) = ai.as_ref() {
            store.drain(ai)?;
        }
        let mut profile = read(store, id)?;
        profile.baseline = current.clone();
        profile.preferences = prefs.clone();
        save(store, id, &profile)?;
        archive(store, id)?;
    }
    load(store, target)?;
    store.put("preferences", &prefs)?;
    store
        .db
        .execute("DELETE FROM tp_sync_selection", [])
        .map_err(db_error)?;
    if let Some(id) = target {
        store
            .db
            .execute("INSERT INTO tp_sync_selection VALUES(1,?1)", [id])
            .map_err(db_error)?;
        let profile = read(store, id)?;
        let c = store.config()?;
        let context = store.context()?;
        store.put("profileActivationContext", &context)?;
        skip_journal(store, store.db)?;
        if let Some(ai) = ai.as_ref() {
            skip_journal(store, ai)?;
        }
        let seed: Vec<String> = store.get("profileSeedScopes")?.unwrap_or_default();
        let normal: Vec<String> = c
            .scopes
            .iter()
            .filter(|s| !seed.contains(s))
            .cloned()
            .collect();
        journal::enqueue_delta(
            store.db,
            store.key,
            &profile.baseline,
            &current,
            &context,
            Some(&normal),
            &store.writer()?,
        )?;
        if !seed.is_empty() {
            journal::enqueue_delta(
                store.db,
                store.key,
                &[],
                &current,
                &context,
                Some(&seed),
                &store.writer()?,
            )?;
        }
        store.remove("profileSeedScopes")?;
        store.drain(store.db)?;
        if c.scopes.iter().any(|s| s == "preferences")
            && (profile.preferences != prefs || seed.iter().any(|s| s == "preferences"))
        {
            if let Some(fields) = prefs.as_object() {
                store.append(
                    "preferences",
                    &store.writer()?,
                    &store.state("preferences")?.frontier,
                    "preferences",
                    "main",
                    super::model::Action::Patch {
                        fields: fields.clone().into_iter().collect(),
                    },
                )?;
            }
        }
        if store.get::<bool>("profileNeedsSnapshot")?.unwrap_or(false) {
            runtime::maybe_snapshot(store, true)?;
            store.remove("profileNeedsSnapshot")?;
        }
        journal::set_context(store.db, &store.context()?, true)?;
        if let Some(ai) = ai.as_ref() {
            journal::set_context(ai, &store.context()?, true)?;
        }
    } else {
        journal::set_context(store.db, &json!({}), false)?;
        if let Some(ai) = ai.as_ref() {
            journal::set_context(ai, &json!({}), false)?;
        }
    }
    tx.commit().map_err(db_error)?;
    if let Some(tx) = ai_tx {
        tx.commit().map_err(db_error)?;
    }
    Ok(())
}

/// Install only a cloud-validated configuration. Replica identity is created here.
pub(super) fn add_imported(store: &Store<'_>, title: String, mut config: Config) -> Result<String> {
    config.device = uuid::Uuid::new_v4().to_string();
    let id = uuid::Uuid::new_v4().to_string();
    store.transaction(|| {
        save(
            store,
            &id,
            &Profile {
                title,
                ..Default::default()
            },
        )?;
        put(store, &id, "config", &config)
    })?;
    Ok(id)
}
