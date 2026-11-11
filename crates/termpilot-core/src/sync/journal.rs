//! Triggers capture native GRDB and Rust writes in the same transaction as business data.
//! Payloads (including OLD for DELETE) are encrypted before SQLite persists the journal.
use super::{db_error, err, policy, Result};
use crate::vault::crypto;
use rusqlite::{functions::FunctionFlags, Connection};
use serde_json::{json, Value};
use zeroize::Zeroizing;
pub const AAD: &[u8] = b"TermPilot:sync:journal:v1";
pub const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS tp_sync_context (
 id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL DEFAULT 0,
 suppressed INTEGER NOT NULL DEFAULT 0, context TEXT NOT NULL DEFAULT '{}',
 origin TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tp_sync_journal (
 id INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL);
";
pub fn register(db: &Connection, key: &[u8]) -> Result<()> {
    let key = Zeroizing::new(key.to_vec());
    db.create_scalar_function("tp_sync_seal", 1, FunctionFlags::SQLITE_UTF8, move |ctx| {
        let input: String = ctx.get(0)?;
        crypto::seal(&key, input.as_bytes(), AAD).map_err(|_| rusqlite::Error::InvalidQuery)
    })
    .map_err(db_error)
}
pub fn install(db: &Connection, ai: bool) -> Result<()> {
    let installed: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='tp_sync_context')",
            [],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !installed {
        let path: String = db
            .query_row(
                "SELECT file FROM pragma_database_list WHERE name='main'",
                [],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if !path.is_empty() {
            let backup = std::path::PathBuf::from(format!("{path}.before-sync-v1"));
            if !backup.exists() {
                db.backup(rusqlite::DatabaseName::Main, &backup, None)
                    .map_err(db_error)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(&backup, std::fs::Permissions::from_mode(0o600))
                        .map_err(|_| err("syncBackup", "无法保护迁移前备份。"))?;
                }
            }
        }
    }
    db.execute_batch(SCHEMA).map_err(db_error)?;
    let has_writer: bool = db
        .prepare("PRAGMA table_info(tp_sync_context)")
        .map_err(db_error)?
        .query_map([], |r| r.get::<_, String>(1))
        .map_err(db_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(db_error)?
        .iter()
        .any(|c| c == "writer");
    if !has_writer {
        db.execute_batch("ALTER TABLE tp_sync_context ADD COLUMN writer TEXT;")
            .map_err(db_error)?;
    }
    db.execute(
        "INSERT OR IGNORE INTO tp_sync_context(id,origin) VALUES(1,?1)",
        [uuid::Uuid::new_v4().to_string()],
    )
    .map_err(db_error)?;
    // The journal stream ID remains stable; each process gets a fresh writer epoch.
    // Reopening an old backup or cloning a directory can never reuse an operation ID.
    let path: String = db
        .query_row(
            "SELECT file FROM pragma_database_list WHERE name='main'",
            [],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let writer = session_writer(&path);
    db.execute(
        "UPDATE tp_sync_context SET writer=?1 WHERE id=1 AND writer IS NOT ?1",
        [&writer],
    )
    .map_err(db_error)?;
    if !has_writer {
        for (table, _) in if ai {
            vec![("records", "id")]
        } else {
            policy::TABLES.to_vec()
        } {
            for event in ["INSERT", "UPDATE", "DELETE"] {
                db.execute_batch(&format!("DROP TRIGGER IF EXISTS tp_sync_{table}_{event}"))
                    .map_err(db_error)?;
            }
        }
    }
    let tables = if ai {
        vec![("records", "id")]
    } else {
        policy::TABLES.to_vec()
    };
    for (table, pk) in tables {
        let mut statement = db
            .prepare(&format!("PRAGMA table_info({table})"))
            .map_err(db_error)?;
        let columns = statement
            .query_map([], |r| r.get::<_, String>(1))
            .map_err(db_error)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(db_error)?;
        if columns.is_empty() {
            continue;
        }
        let object = |row: &str| {
            let fields = columns.iter().map(|c| format!("'{c}', CASE WHEN typeof({row}.\"{c}\")='blob' THEN json_object('$blob',hex({row}.\"{c}\")) ELSE {row}.\"{c}\" END")).collect::<Vec<_>>().join(",");
            format!("json_object({fields})")
        };
        for (event, old, new) in [
            ("INSERT", "NULL".into(), object("NEW")),
            ("UPDATE", object("OLD"), object("NEW")),
            ("DELETE", object("OLD"), "NULL".into()),
        ] {
            let row = if event == "DELETE" { "OLD" } else { "NEW" };
            let collection = if ai {
                format!("'ai:'||{row}.collection")
            } else {
                format!("'{table}'")
            };
            let condition = if event == "UPDATE" {
                format!(
                    " AND ({})",
                    columns
                        .iter()
                        .map(|c| format!("OLD.\"{c}\" IS NOT NEW.\"{c}\""))
                        .collect::<Vec<_>>()
                        .join(" OR ")
                )
            } else {
                String::new()
            };
            let sql = format!(
                "CREATE TRIGGER IF NOT EXISTS tp_sync_{table}_{event} AFTER {event} ON {table}
              WHEN (SELECT enabled=1 AND suppressed=0 FROM tp_sync_context WHERE id=1){condition}
              BEGIN INSERT INTO tp_sync_journal(payload) SELECT tp_sync_seal(json_object(
                'collection',{collection},'record',{row}.\"{pk}\",'before',{old},'after',{new},
                'context',json(context),'origin',writer,'at',strftime('%Y-%m-%dT%H:%M:%fZ','now')))
                FROM tp_sync_context WHERE id=1; END;"
            );
            db.execute_batch(&sql).map_err(db_error)?;
        }
    }
    Ok(())
}
pub fn decode_record(collection: &str, value: &Value, key: &[u8]) -> Result<Value> {
    if value.is_null() {
        return Ok(Value::Null);
    }
    let mut object = value
        .as_object()
        .cloned()
        .ok_or_else(|| err("syncJournal", "本机同步日志格式无效。"))?;
    for (field, value) in &mut object {
        if let Some(blob) = value.get("$blob").and_then(Value::as_str) {
            let bytes = hex::decode(blob).map_err(|_| err("syncJournal", "本机日志内容无效。"))?;
            if !collection.starts_with("ai:") {
                *value = serde_json::from_slice(&bytes)
                    .map_err(|_| err("syncJournal", "保存内容无法解析。"))?;
            }
        } else if crate::vault::model::is_secret(field) {
            *value = crypto::decrypt_field(key, value)?;
        }
    }
    if collection.starts_with("ai:") {
        let id = object.get("id").and_then(Value::as_str).unwrap_or("");
        let bytes = object
            .get("payload")
            .and_then(|p| p["$blob"].as_str())
            .and_then(|s| hex::decode(s).ok())
            .ok_or_else(|| err("syncJournal", "AI 日志内容无效。"))?;
        let aad = format!(
            "TermPilot:AI:v1:{}:{id}",
            collection.trim_start_matches("ai:")
        );
        let clear = crypto::unseal(key, &bytes, aad.as_bytes())?;
        return serde_json::from_slice(&clear).map_err(|_| err("syncJournal", "AI 日志无法解析。"));
    }
    if let Some(payload) = object.remove("payload") {
        if let Some(payload) = payload.as_object() {
            object.extend(payload.clone());
        }
    }
    Ok(Value::Object(object))
}
pub fn set_context(db: &Connection, context: &Value, enabled: bool) -> Result<()> {
    db.execute(
        "UPDATE tp_sync_context SET context=?1,enabled=?2 WHERE id=1",
        rusqlite::params![context.to_string(), enabled],
    )
    .map_err(db_error)?;
    Ok(())
}
pub fn seed(db: &Connection, key: &[u8], ai: bool) -> Result<()> {
    seed_scopes(db, key, ai, None)
}
pub fn seed_scopes(db: &Connection, key: &[u8], ai: bool, scopes: Option<&[String]>) -> Result<()> {
    let context: String = db
        .query_row("SELECT context FROM tp_sync_context WHERE id=1", [], |r| {
            r.get(0)
        })
        .map_err(db_error)?;
    let origin: String = db
        .query_row(
            "SELECT COALESCE(writer,origin) FROM tp_sync_context WHERE id=1",
            [],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    enqueue_delta(
        db,
        key,
        &[],
        &snapshot(db, ai)?,
        &serde_json::from_str::<Value>(&context).unwrap_or_default(),
        scopes,
        &origin,
    )?;
    Ok(())
}

fn session_writer(path: &str) -> String {
    static WRITERS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::BTreeMap<String, String>>,
    > = std::sync::OnceLock::new();
    let mut writers = WRITERS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    writers
        .entry(path.into())
        .or_insert_with(|| uuid::Uuid::new_v4().to_string())
        .clone()
}

/// Raw native rows remain encrypted inside the local profile baseline. Keeping OLD
/// as well as NEW allows a later activation to carry deletions across destinations.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub(super) struct CapturedRow {
    pub collection: String,
    pub record: String,
    pub value: Value,
}
pub(super) fn snapshot(db: &Connection, ai: bool) -> Result<Vec<CapturedRow>> {
    let mut result = Vec::new();
    let tables = if ai {
        vec![("records", "id")]
    } else {
        policy::TABLES.to_vec()
    };
    for (table, pk) in tables {
        let mut stmt = db
            .prepare(&format!("SELECT * FROM {table}"))
            .map_err(db_error)?;
        let names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let mut rows = stmt.query([]).map_err(db_error)?;
        while let Some(row) = rows.next().map_err(db_error)? {
            let mut value = serde_json::Map::new();
            for (index, name) in names.iter().enumerate() {
                use rusqlite::types::ValueRef;
                let v = match row.get_ref(index).map_err(db_error)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(n) => json!(n),
                    ValueRef::Text(s) => json!(String::from_utf8_lossy(s)),
                    ValueRef::Blob(b) => json!({"$blob":hex::encode(b)}),
                };
                value.insert(name.clone(), v);
            }
            let collection = if ai {
                format!("ai:{}", value["collection"].as_str().unwrap_or(""))
            } else {
                table.into()
            };
            result.push(CapturedRow {
                collection,
                record: value[pk].as_str().unwrap_or("").into(),
                value: Value::Object(value),
            });
        }
    }
    Ok(result)
}
pub(super) fn enqueue_delta(
    db: &Connection,
    key: &[u8],
    before: &[CapturedRow],
    after: &[CapturedRow],
    context: &Value,
    scopes: Option<&[String]>,
    writer: &str,
) -> Result<()> {
    use std::collections::BTreeMap;
    let old: BTreeMap<_, _> = before
        .iter()
        .map(|r| ((r.collection.clone(), r.record.clone()), &r.value))
        .collect();
    let new: BTreeMap<_, _> = after
        .iter()
        .map(|r| ((r.collection.clone(), r.record.clone()), &r.value))
        .collect();
    let keys: std::collections::BTreeSet<_> = old.keys().chain(new.keys()).collect();
    for (collection, record) in keys {
        let old = old
            .get(&(collection.clone(), record.clone()))
            .copied()
            .unwrap_or(&Value::Null);
        let new = new
            .get(&(collection.clone(), record.clone()))
            .copied()
            .unwrap_or(&Value::Null);
        if old == new {
            continue;
        }
        let event = json!({"collection":collection,"record":record,"before":old,"after":new,
            "context":context,"origin":writer,"scopes":scopes,"at":chrono::Utc::now().to_rfc3339()});
        let sealed = crypto::seal(key, &serde_json::to_vec(&event).unwrap(), AAD)?;
        db.execute("INSERT INTO tp_sync_journal(payload) VALUES(?1)", [sealed])
            .map_err(db_error)?;
    }
    Ok(())
}
