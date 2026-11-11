//! Apply canonical records without generating another local change. Unknown fields remain
//! in the encrypted canonical state; this adapter only projects columns understood here.
use super::{db_error, err, model::record_key, policy, store::Store, Result};
use crate::vault::crypto;
use rusqlite::{params, types::Value as SqlValue, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

pub fn vault(store: &Store<'_>) -> Result<()> {
    let config = store.config()?;
    let public = store.state("configuration")?;
    let secrets = if config.scopes.iter().any(|s| s == "credentials") {
        Some(store.state("credentials")?)
    } else {
        None
    };
    store
        .db
        .execute("UPDATE tp_sync_context SET suppressed=1 WHERE id=1", [])
        .map_err(db_error)?;
    store
        .db
        .execute_batch("PRAGMA defer_foreign_keys=ON")
        .map_err(db_error)?;
    let mut rows = BTreeMap::new();
    for (key, record) in &public.records {
        if record.deleted() {
            continue;
        }
        let mut row = policy::expand(record.value());
        if let Some(record) = secrets
            .as_ref()
            .and_then(|s| s.records.get(key))
            .filter(|r| !r.deleted())
        {
            policy::overlay(&mut row, &record.value());
        }
        rows.insert(key.clone(), row);
    }
    // Orphans are a display projection only. The canonical reference is never overwritten.
    let alive: BTreeSet<String> = rows.keys().cloned().collect();
    for (key, row) in &mut rows {
        for (field, table) in [
            ("group_id", "host_groups"),
            ("parent_group_id", "host_groups"),
            ("host_id", "hosts"),
        ] {
            if let Some(id) = row[field].as_str() {
                if !alive.contains(&record_key(table, id)) {
                    row[field] = Value::Null;
                }
            }
        }
        if key.starts_with("host_groups/") {
            let mut seen = BTreeSet::from([key.trim_start_matches("host_groups/").to_owned()]);
            let mut parent = row["parent_group_id"].as_str().map(str::to_owned);
            while let Some(id) = parent {
                if !seen.insert(id.clone()) {
                    row["parent_group_id"] = Value::Null;
                    break;
                }
                parent = public
                    .records
                    .get(&record_key("host_groups", &id))
                    .and_then(|r| r.value()["parent_group_id"].as_str().map(str::to_owned));
            }
        }
    }
    for (table, pk) in policy::TABLES {
        for (key, row) in rows
            .iter()
            .filter(|(k, _)| k.starts_with(&format!("{table}/")))
        {
            let id = key.trim_start_matches(&format!("{table}/"));
            if *table == "screen_sharing_profiles" && !alive.contains(&record_key("hosts", id)) {
                continue;
            }
            write_row(store.db, store.key, table, pk, id, row)?;
        }
    }
    for (key, record) in &public.records {
        if !record.deleted() {
            continue;
        }
        if let Some((table, pk)) = policy::TABLES
            .iter()
            .find(|(t, _)| key.starts_with(&format!("{t}/")))
        {
            store
                .db
                .execute(
                    &format!("DELETE FROM {table} WHERE {pk}=?1"),
                    [key.trim_start_matches(&format!("{table}/"))],
                )
                .map_err(db_error)?;
        }
    }
    store
        .db
        .execute("UPDATE tp_sync_context SET suppressed=0 WHERE id=1", [])
        .map_err(db_error)?;
    super::journal::set_context(store.db, &store.context()?, true)
}
pub(super) fn write_row(
    db: &Connection,
    key: &[u8],
    table: &str,
    pk: &str,
    id: &str,
    value: &Value,
) -> Result<()> {
    uuid::Uuid::parse_str(id).map_err(|_| err("syncRecord", "收到无效的记录 ID。"))?;
    let mut stmt = db
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(db_error)?;
    let columns = stmt
        .query_map([], |r| r.get::<_, String>(1))
        .map_err(db_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(db_error)?;
    let existing: bool = db
        .query_row(
            &format!("SELECT EXISTS(SELECT 1 FROM {table} WHERE {pk}=?1)"),
            [id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let current = if existing {
        let mut q = db
            .prepare(&format!("SELECT * FROM {table} WHERE {pk}=?1"))
            .map_err(db_error)?;
        let names = q
            .column_names()
            .iter()
            .map(|s| (*s).to_owned())
            .collect::<Vec<_>>();
        let raw = q
            .query_row([id], |row| {
                let mut values = serde_json::Map::new();
                for (index, name) in names.iter().enumerate() {
                    use rusqlite::types::ValueRef;
                    let value = match row.get_ref(index)? {
                        ValueRef::Null => Value::Null,
                        ValueRef::Integer(n) => json!(n),
                        ValueRef::Real(n) => json!(n),
                        ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                        ValueRef::Blob(b) => json!({"$blob":hex::encode(b)}),
                    };
                    values.insert(name.clone(), value);
                }
                Ok(Value::Object(values))
            })
            .map_err(db_error)?;
        super::journal::decode_record(table, &raw, key)?
    } else {
        json!({})
    };
    // Older clients treated this boolean as encrypted text and uploaded NULL.
    // Recover its meaning from the retained passphrase, or preserve the local
    // flag if the incoming scope does not contain a passphrase field.
    let mut value = value.clone();
    if table == "ssh_credentials" && value.get("saves_passphrase") == Some(&Value::Null) {
        value["saves_passphrase"] = value
            .get("passphrase")
            .map(|passphrase| json!(passphrase.as_str().is_some_and(|text| !text.is_empty())))
            .unwrap_or_else(|| {
                current
                    .get("saves_passphrase")
                    .cloned()
                    .unwrap_or(json!(false))
            });
    }
    if existing
        && value.as_object().is_some_and(|values| {
            values.iter().all(|(field, value)| {
                let old = &current[field];
                old == value || (old.as_f64().is_some() && old.as_f64() == value.as_f64())
            })
        })
    {
        return Ok(());
    }
    let now = chrono::Utc::now()
        .format("%Y-%m-%d %H:%M:%S%.3f")
        .to_string();
    let mut fields = BTreeMap::from([(pk.to_owned(), SqlValue::Text(id.into()))]);
    for column in columns {
        if column == pk {
            continue;
        }
        if column == "payload" {
            let mut payload = current.clone();
            policy::overlay(&mut payload, &value);
            payload["id"] = json!(id);
            if let Some(host) = value.get("host_id") {
                payload["hostID"] = host.clone();
            }
            fields.insert(
                column,
                SqlValue::Blob(
                    serde_json::to_vec(&payload)
                        .map_err(|_| err("syncRecord", "无法投影记录内容。"))?,
                ),
            );
        } else if let Some(v) = value.get(&column) {
            // Sync scope classification also includes metadata such as the
            // saves_passphrase boolean. Only encrypt actual vault secret columns;
            // encrypt_field turns non-strings into NULL, violating that flag's
            // NOT NULL constraint and rolling back every received credential.
            let v = if crate::vault::model::is_secret(&column) {
                crypto::encrypt_field(key, v)?
            } else {
                v.clone()
            };
            fields.insert(
                column,
                match v {
                    Value::Null => SqlValue::Null,
                    Value::Bool(b) => SqlValue::Integer(i64::from(b)),
                    Value::Number(n) => SqlValue::Real(n.as_f64().unwrap_or(0.0)),
                    Value::String(s) => SqlValue::Text(s),
                    _ => return Err(err("syncRecord", "收到无效的字段类型。")),
                },
            );
        } else if column == "created_at" && !existing || column == "updated_at" {
            fields.insert(column, SqlValue::Text(now.clone()));
        }
    }
    let names = fields
        .keys()
        .map(|s| format!("\"{s}\""))
        .collect::<Vec<_>>()
        .join(",");
    let parameters = (1..=fields.len())
        .map(|n| format!("?{n}"))
        .collect::<Vec<_>>()
        .join(",");
    if existing {
        let assignments = fields
            .keys()
            .filter(|s| s.as_str() != pk)
            .map(|s| {
                format!(
                    "\"{s}\"=?{}",
                    fields.keys().position(|k| k == s).unwrap() + 1
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        if !assignments.is_empty() {
            db.execute(
                &format!(
                    "UPDATE {table} SET {assignments} WHERE {pk}=?{}",
                    fields.keys().position(|s| s == pk).unwrap() + 1
                ),
                rusqlite::params_from_iter(fields.values()),
            )
            .map_err(db_error)?;
        }
    } else {
        db.execute(
            &format!("INSERT INTO {table}({names}) VALUES({parameters})"),
            rusqlite::params_from_iter(fields.values()),
        )
        .map_err(db_error)?;
    }
    Ok(())
}

pub fn ai(store: &Store<'_>, db: &Connection) -> Result<()> {
    let tx = rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    store.transaction(|| store.drain(db))?;
    let config = store.config()?;
    let mut documents = BTreeMap::new();
    for scope in &config.scopes {
        if !matches!(scope.as_str(), "configuration" | "aiSecrets" | "aiHistory") {
            continue;
        }
        for (key, record) in store.state(scope)?.records {
            if !key.starts_with("ai:") {
                continue;
            }
            let document = documents.entry(key).or_insert((false, json!({})));
            document.0 |= record.deleted();
            policy::overlay(&mut document.1, &record.value());
        }
    }
    db.execute("UPDATE tp_sync_context SET suppressed=1 WHERE id=1", [])
        .map_err(db_error)?;
    let settings_aad = b"TermPilot:AI:v1:settings:main";
    let old: Option<Vec<u8>> = db
        .query_row(
            "SELECT payload FROM records WHERE collection='settings' AND id='main'",
            [],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    let mut settings: Value = old
        .map(|b| {
            crypto::unseal(store.key, &b, settings_aad).and_then(|b| {
                serde_json::from_slice(&b).map_err(|_| err("syncAI", "AI 设置损坏。"))
            })
        })
        .transpose()?
        .unwrap_or(json!({"providers":[],"quickMessages":[],"mode":"confirm"}));
    let before_settings = settings.clone();
    let mut settings_changed = false;
    let history = documents
        .iter()
        .filter(|(key, _)| key.starts_with("ai:messages/"))
        .map(|(key, value)| {
            (
                key.trim_start_matches("ai:messages/").to_owned(),
                value.clone(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    for (key, (deleted, mut value)) in documents {
        let Some((collection, id)) = key.trim_start_matches("ai:").split_once('/') else {
            continue;
        };
        if collection == "messages" {
            continue;
        }
        if collection == "conversations" && !deleted && value["messageOrder"].is_array() {
            let mut messages = Vec::new();
            for message_id in value["messageOrder"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(Value::as_str)
            {
                if let Some((false, record)) = history.get(message_id) {
                    let mut message = record["message"].clone();
                    message["id"] = json!(message_id);
                    messages.push(message);
                } else {
                    return Err(err("syncHistory", "AI 历史尚缺少消息，已延后投影。"));
                }
            }
            value.as_object_mut().unwrap().remove("messageOrder");
            value["messages"] = json!(messages);
        }
        if matches!(collection, "providers" | "prompts" | "settings") {
            if collection == "settings" {
                if !deleted {
                    policy::overlay(&mut settings, &value);
                    settings_changed = true;
                }
                continue;
            }
            let (field, id_field) = if collection == "providers" {
                ("providers", "id")
            } else {
                ("quickMessages", "slug")
            };
            let mut records = settings[field].as_array().cloned().unwrap_or_default();
            if deleted {
                records.retain(|r| r[id_field] != id);
            } else if let Some(old) = records.iter_mut().find(|r| r[id_field] == id) {
                policy::overlay(old, &value);
            } else {
                let mut value = value;
                value[id_field] = json!(id);
                records.push(value);
            }
            records.sort_by(|a, b| a[id_field].as_str().cmp(&b[id_field].as_str()));
            settings[field] = json!(records);
            settings_changed = true;
            continue;
        }
        if deleted {
            db.execute(
                "DELETE FROM records WHERE collection=?1 AND id=?2",
                params![collection, id],
            )
            .map_err(db_error)?;
            continue;
        }
        let aad = format!("TermPilot:AI:v1:{collection}:{id}");
        let old: Option<Vec<u8>> = db
            .query_row(
                "SELECT payload FROM records WHERE collection=?1 AND id=?2",
                params![collection, id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        let mut current = old
            .map(|b| {
                crypto::unseal(store.key, &b, aad.as_bytes()).and_then(|b| {
                    serde_json::from_slice(&b).map_err(|_| err("syncAI", "AI 设置损坏。"))
                })
            })
            .transpose()?
            .unwrap_or(json!({}));
        if collection == "conversations" {
            if matches!(
                current["status"].as_str(),
                Some("running" | "streaming" | "thinking" | "waiting")
            ) {
                continue;
            }
            let defaults = json!({"draft":"","attachments":[],"skills":[],"externalId":null,"status":"idle","usage":null,"updated":chrono::Utc::now().timestamp_millis()});
            for (field, value) in defaults.as_object().unwrap() {
                if current.get(field).is_none() {
                    current[field] = value.clone();
                }
            }
        }
        let before = current.clone();
        policy::overlay(&mut current, &value);
        current["id"] = json!(id);
        if current == before {
            continue;
        }
        let bytes = crypto::seal(
            store.key,
            &serde_json::to_vec(&current).unwrap(),
            aad.as_bytes(),
        )?;
        db.execute("INSERT INTO records VALUES(?1,?2,?3,?4) ON CONFLICT(collection,id) DO UPDATE SET payload=excluded.payload,updated=excluded.updated",params![collection,id,bytes,chrono::Utc::now().timestamp_millis()]).map_err(db_error)?;
    }
    if settings_changed && settings != before_settings {
        let bytes = crypto::seal(
            store.key,
            &serde_json::to_vec(&settings).unwrap(),
            settings_aad,
        )?;
        db.execute("INSERT INTO records VALUES('settings','main',?1,?2) ON CONFLICT(collection,id) DO UPDATE SET payload=excluded.payload,updated=excluded.updated",params![bytes,chrono::Utc::now().timestamp_millis()]).map_err(db_error)?;
    }
    db.execute("UPDATE tp_sync_context SET suppressed=0 WHERE id=1", [])
        .map_err(db_error)?;
    super::journal::set_context(db, &store.context()?, true)?;
    tx.commit().map_err(db_error)
}
