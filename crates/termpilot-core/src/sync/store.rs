use super::{db_error, err, journal, model::*, policy, Result};
use crate::vault::{crypto, Vault};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

const AAD: &[u8] = b"TermPilot:sync:local:v1";
#[derive(Clone, Serialize, Deserialize)]
pub struct Config {
    pub library: String,
    #[serde(default)]
    pub generation: String,
    #[serde(default)]
    pub generation_sequence: u64,
    pub device: String,
    pub name: String,
    pub auto: bool,
    pub scopes: Vec<String>,
    pub retention_days: Option<u32>,
    // Key material and cloud authorization are encrypted under the existing device key.
    pub scope_keys: BTreeMap<String, Vec<u8>>,
    pub provider: super::transport::Provider,
}
pub struct Store<'a> {
    pub db: &'a Connection,
    pub key: &'a [u8],
}
impl<'a> Store<'a> {
    pub fn new(vault: &'a Vault) -> Result<Self> {
        let store = Self {
            db: &vault.db,
            key: &vault.key,
        };
        store.db.execute_batch("CREATE TABLE IF NOT EXISTS tp_sync_values (id TEXT PRIMARY KEY,payload BLOB NOT NULL);
          CREATE TABLE IF NOT EXISTS tp_sync_operations (scope TEXT NOT NULL,writer TEXT NOT NULL,seq INTEGER NOT NULL,payload BLOB NOT NULL,published INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(scope,writer,seq));
          CREATE TABLE IF NOT EXISTS tp_sync_object_ops(name TEXT NOT NULL,scope TEXT NOT NULL,writer TEXT NOT NULL,seq INTEGER NOT NULL,PRIMARY KEY(scope,writer,seq));
          CREATE TABLE IF NOT EXISTS tp_sync_objects (name TEXT PRIMARY KEY,payload BLOB NOT NULL,published INTEGER NOT NULL DEFAULT 0,kind TEXT NOT NULL,scope TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS tp_sync_received (name TEXT PRIMARY KEY,digest TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS tp_sync_cursors (origin TEXT PRIMARY KEY,seq INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS tp_sync_actions (id TEXT PRIMARY KEY,payload BLOB NOT NULL);").map_err(db_error)?;
        super::profiles::prepare(vault, &store)?;
        Ok(store)
    }
    pub fn transaction<T>(&self, action: impl FnOnce() -> Result<T>) -> Result<T> {
        let tx =
            rusqlite::Transaction::new_unchecked(self.db, rusqlite::TransactionBehavior::Immediate)
                .map_err(db_error)?;
        let value = action()?;
        tx.commit().map_err(db_error)?;
        Ok(value)
    }
    pub fn get<T: DeserializeOwned>(&self, id: &str) -> Result<Option<T>> {
        let bytes: Option<Vec<u8>> = self
            .db
            .query_row(
                "SELECT payload FROM tp_sync_values WHERE id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        bytes.map(|b| self.decode(&b)).transpose()
    }
    pub fn remove(&self, id: &str) -> Result<()> {
        self.db
            .execute("DELETE FROM tp_sync_values WHERE id=?1", [id])
            .map_err(db_error)?;
        Ok(())
    }
    pub fn put(&self, id: &str, value: &impl Serialize) -> Result<()> {
        self.db.execute("INSERT INTO tp_sync_values VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",params![id,self.encode(value)?]).map_err(db_error)?;
        Ok(())
    }
    pub fn encode(&self, value: &impl Serialize) -> Result<Vec<u8>> {
        let bytes = zeroize::Zeroizing::new(
            serde_json::to_vec(value).map_err(|_| err("syncEncode", "无法保存同步内容。"))?,
        );
        crypto::seal(self.key, &bytes, AAD)
    }
    pub fn decode<T: DeserializeOwned>(&self, bytes: &[u8]) -> Result<T> {
        serde_json::from_slice(&crypto::unseal(self.key, bytes, AAD)?)
            .map_err(|_| err("syncDecode", "同步内容损坏或版本不兼容。"))
    }
    pub fn writer(&self) -> Result<String> {
        let writer: String = self
            .db
            .query_row(
                "SELECT COALESCE(writer,origin) FROM tp_sync_context WHERE id=1",
                [],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        self.profile_writer(&writer)
    }
    fn profile_writer(&self, writer: &str) -> Result<String> {
        // Two saved connections may point at the very same library. Their local
        // sequence counters are independent, so their writer IDs must be too.
        if let Some(id) = super::profiles::active(self)? {
            let suffix = format!("@{id}");
            if !writer.ends_with(&suffix) {
                return Ok(format!("{writer}{suffix}"));
            }
        }
        Ok(writer.into())
    }
    pub fn config(&self) -> Result<Config> {
        self.get("config")?
            .ok_or_else(|| err("syncNotConfigured", "请先配置同步服务。"))
    }
    pub fn state(&self, scope: &str) -> Result<State> {
        Ok(self.get(&format!("state:{scope}"))?.unwrap_or_default())
    }
    pub fn save_state(&self, scope: &str, state: &State) -> Result<()> {
        self.put(&format!("state:{scope}"), state)
    }
    pub fn context(&self) -> Result<Value> {
        let config = self.config()?;
        let mut context = serde_json::Map::new();
        for scope in &config.scopes {
            context.insert(scope.clone(), json!(self.state(scope)?.frontier));
        }
        if let Some(id) = super::profiles::active(self)? {
            context.insert("_profile".into(), json!(id));
        }
        Ok(Value::Object(context))
    }
    pub fn receive(&self, operation: &Operation, published: bool) -> Result<bool> {
        let config = self.config()?;
        if !config.scopes.contains(&operation.scope) {
            return Err(err("syncScope", "当前设备未启用此同步范围。"));
        }
        let mut state = self.state(&operation.scope)?;
        let changed = state.receive(operation.clone(), &config.library, &operation.scope)?;
        if changed {
            self.db.execute("INSERT INTO tp_sync_operations(scope,writer,seq,payload,published) VALUES(?1,?2,?3,?4,?5)",params![operation.scope,operation.dot.writer,operation.dot.seq,self.encode(operation)?,published]).map_err(db_error)?;
            self.save_state(&operation.scope, &state)?;
        } else if published {
            self.db.execute("UPDATE tp_sync_operations SET published=1 WHERE scope=?1 AND writer=?2 AND seq=?3",params![operation.scope,operation.dot.writer,operation.dot.seq]).map_err(db_error)?;
        }
        Ok(changed)
    }
    pub fn append(
        &self,
        scope: &str,
        writer: &str,
        basis: &Vector,
        collection: &str,
        record: &str,
        action: Action,
    ) -> Result<Operation> {
        let config = self.config()?;
        let mut basis = basis.clone();
        let stored: u64 = self
            .db
            .query_row(
                "SELECT COALESCE(MAX(seq),0) FROM tp_sync_operations WHERE scope=?1 AND writer=?2",
                params![scope, writer],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        let last = stored.max(
            self.state(scope)?
                .frontier
                .get(writer)
                .copied()
                .unwrap_or(0),
        );
        if last > 0 {
            basis.insert(writer.into(), last);
        } else {
            basis.remove(writer);
        }
        let operation = Operation {
            version: 1,
            library: config.library,
            scope: scope.into(),
            dot: Dot {
                writer: writer.into(),
                seq: last + 1,
            },
            basis,
            collection: collection.into(),
            record: record.into(),
            action,
        };
        self.receive(&operation, false)?;
        Ok(operation)
    }
    /// The original context is captured by the native SQL trigger, never replaced on retry.
    pub fn drain(&self, source: &Connection) -> Result<usize> {
        let config = self.config()?;
        let selected_profile = super::profiles::active(self)?;
        let activation_context = self.get::<Value>("profileActivationContext")?;
        let origin: String = source
            .query_row("SELECT origin FROM tp_sync_context WHERE id=1", [], |r| {
                r.get(0)
            })
            .map_err(db_error)?;
        let cursor: i64 = self
            .db
            .query_row(
                "SELECT seq FROM tp_sync_cursors WHERE origin=?1",
                [&origin],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?
            .unwrap_or(0);
        let mut statement = source
            .prepare("SELECT id,payload FROM tp_sync_journal WHERE id>?1 ORDER BY id")
            .map_err(db_error)?;
        let events = statement
            .query_map([cursor], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
            })
            .map_err(db_error)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(db_error)?;
        let mut deleted_credentials = std::collections::BTreeSet::new();
        let mut deleted_proxies = std::collections::BTreeSet::new();
        for (_, bytes) in &events {
            let event: Value =
                serde_json::from_slice(&crypto::unseal(self.key, bytes, journal::AAD)?)
                    .map_err(|_| err("syncJournal", "同步日志无法解析。"))?;
            if event["after"].is_null() {
                if let Some(id) = event["record"].as_str() {
                    match event["collection"].as_str() {
                        Some("ssh_credentials") => {
                            deleted_credentials.insert(id.to_owned());
                        }
                        Some("ssh_proxy_profiles") => {
                            deleted_proxies.insert(id.to_owned());
                        }
                        _ => {}
                    }
                }
            }
        }
        let total = events.len();
        super::progress::stage("merging", 0, Some(total));
        let mut count = 0;
        for (index, (id, bytes)) in events.into_iter().enumerate() {
            super::progress::stage("merging", index, Some(total));
            let event: Value =
                serde_json::from_slice(&crypto::unseal(self.key, &bytes, journal::AAD)?)
                    .map_err(|_| err("syncJournal", "同步日志无法解析。"))?;
            let collection = event["collection"].as_str().unwrap_or("");
            let record = event["record"].as_str().unwrap_or("");
            let before = journal::decode_record(collection, &event["before"], self.key)?;
            let mut after = journal::decode_record(collection, &event["after"], self.key)?;
            if collection == "hosts" && !after.is_null() {
                for (field, deleted) in [
                    ("credential_reference", &deleted_credentials),
                    ("proxy_profile_reference", &deleted_proxies),
                ] {
                    if after[field].is_null()
                        && before[field]
                            .as_str()
                            .is_some_and(|id| deleted.contains(id))
                        && before["authentication"] == after["authentication"]
                        && before["username"] == after["username"]
                    {
                        after[field] = before[field].clone();
                    }
                }
            }
            let changes = split_records(collection, record, before, after);
            for (collection, record, before, after) in changes {
                let collection = collection.as_str();
                let record = record.as_str();
                for scope in &config.scopes {
                    if event["scopes"]
                        .as_array()
                        .is_some_and(|scopes| !scopes.iter().any(|s| s == scope))
                    {
                        continue;
                    }
                    let before_fields = policy::fields(collection, &before, scope);
                    let mut after_fields = policy::fields(collection, &after, scope);
                    if before.is_null() && matches!(scope.as_str(), "credentials" | "aiSecrets") {
                        // A new replica may only have configuration, without the
                        // corresponding secrets yet. Seeding its empty columns
                        // must not publish deletions that compete with cloud keys.
                        // Updates with a before-image still propagate explicit clears.
                        after_fields = policy::initial_secrets(after_fields);
                    }
                    if before_fields.is_empty() && after_fields.is_empty() {
                        continue;
                    }
                    let basis_context = if activation_context.is_some()
                        && event["context"]["_profile"].as_str() != selected_profile.as_deref()
                    {
                        activation_context.as_ref().unwrap()
                    } else {
                        &event["context"]
                    };
                    let basis: Vector =
                        serde_json::from_value(basis_context[scope].clone()).unwrap_or_default();
                    let canonical = if before.is_null() {
                        Some(
                            self.state(scope)?
                                .records
                                .get(&record_key(collection, record))
                                .map(Record::value)
                                .unwrap_or(Value::Null),
                        )
                    } else {
                        None
                    };
                    let action = if after.is_null() {
                        Action::Delete {
                            recovery: json!(before_fields),
                            retention_days: config.retention_days,
                            deleted_at: event["at"].as_str().unwrap_or("").into(),
                        }
                    } else {
                        let mut fields: BTreeMap<String, Value> = after_fields
                            .iter()
                            .filter(|(k, v)| {
                                before_fields.get(*k) != Some(*v)
                                    && !canonical
                                        .as_ref()
                                        .is_some_and(|old| old.get(k.as_str()) == Some(*v))
                            })
                            .map(|(k, v)| (k.clone(), v.clone()))
                            .collect();
                        for field in before_fields.keys() {
                            if !after_fields.contains_key(field) {
                                fields.insert(field.clone(), Value::Null);
                            }
                        }
                        if fields.is_empty() {
                            continue;
                        }
                        Action::Patch { fields }
                    };
                    let deletion = matches!(&action, Action::Delete { .. });
                    let operation = self.append(
                        scope,
                        &self.profile_writer(event["origin"].as_str().unwrap_or(&origin))?,
                        &basis,
                        collection,
                        record,
                        action,
                    )?;
                    if deletion {
                        self.put(
                            &format!("recovery:{scope}:{}", operation.dot.key()),
                            &before,
                        )?;
                    }
                    count += 1;
                }
            }
            self.db.execute("INSERT INTO tp_sync_cursors VALUES(?1,?2) ON CONFLICT(origin) DO UPDATE SET seq=excluded.seq",params![origin,id]).map_err(db_error)?;
        }
        Ok(count)
    }
    pub fn operations(&self, scope: &str, published_only: bool) -> Result<Vec<Operation>> {
        let mut statement = self.db.prepare("SELECT payload FROM tp_sync_operations WHERE scope=?1 AND (?2=0 OR published=1) ORDER BY writer,seq").map_err(db_error)?;
        let blobs = statement
            .query_map(params![scope, published_only], |r| r.get::<_, Vec<u8>>(0))
            .map_err(db_error)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(db_error)?;
        blobs.iter().map(|b| self.decode(b)).collect()
    }
    /// Call only after the canonical transaction commits. A crash before pruning
    /// replays nothing (the cursor is durable); a crash after pruning loses no input.
    pub fn prune_journal(&self, source: &Connection) -> Result<()> {
        let origin: String = source
            .query_row("SELECT origin FROM tp_sync_context WHERE id=1", [], |r| {
                r.get(0)
            })
            .map_err(db_error)?;
        let cursor: i64 = self
            .db
            .query_row(
                "SELECT seq FROM tp_sync_cursors WHERE origin=?1",
                [&origin],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?
            .unwrap_or(0);
        source
            .execute("DELETE FROM tp_sync_journal WHERE id<=?1", [cursor])
            .map_err(db_error)?;
        Ok(())
    }
    /// Builds only from acknowledged operations, excluding every local unpublished edit.
    pub fn published_state(&self, scope: &str) -> Result<State> {
        let config = self.config()?;
        let mut state = self
            .get::<State>(&format!("baseline:{scope}"))?
            .unwrap_or_default();
        for op in self.operations(scope, true)? {
            state.receive(op, &config.library, scope)?;
        }
        state.waiting.clear();
        state.fingerprints.retain(|id, _| {
            id.rsplit_once(':').is_some_and(|(writer, seq)| {
                seq.parse::<u64>()
                    .is_ok_and(|s| state.frontier.get(writer).copied().unwrap_or(0) >= s)
            })
        });
        for (id, time) in self.state(scope)?.published {
            if state.recycle.contains_key(&id) {
                state.publication(&id, time);
            }
        }
        Ok(state)
    }
}

fn split_records(
    collection: &str,
    record: &str,
    before: Value,
    after: Value,
) -> Vec<(String, String, Value, Value)> {
    if collection == "ai:conversations"
        && !after.is_null()
        && matches!(
            after["status"].as_str(),
            Some("running" | "streaming" | "thinking" | "waiting")
        )
    {
        return vec![];
    }
    if collection == "ai:conversations" {
        let normalize = |value: &Value| -> (Value, BTreeMap<String, Value>) {
            if value.is_null() {
                return (Value::Null, BTreeMap::new());
            }
            let mut metadata = value.clone();
            let mut messages = BTreeMap::new();
            let mut order = Vec::new();
            for (index, message) in value["messages"]
                .as_array()
                .into_iter()
                .flatten()
                .enumerate()
            {
                let id = policy::message_id(record, index, message);
                order.push(id.clone());
                messages.insert(
                    id,
                    serde_json::json!({"conversationId":record,"message":message}),
                );
            }
            metadata.as_object_mut().unwrap().remove("messages");
            metadata["messageOrder"] = serde_json::json!(order);
            (metadata, messages)
        };
        let (old_meta, mut old) = normalize(&before);
        let (new_meta, new) = normalize(&after);
        let mut result = vec![(collection.into(), record.into(), old_meta, new_meta)];
        for (id, value) in new {
            let previous = old.remove(&id).unwrap_or(Value::Null);
            result.push(("ai:messages".into(), id, previous, value));
        }
        if after.is_null() {
            for (id, value) in old {
                result.push(("ai:messages".into(), id, value, Value::Null));
            }
        }
        // Reconcile final output against the durable completed view, not skipped streaming writes.
        if matches!(
            before["status"].as_str(),
            Some("running" | "streaming" | "thinking" | "waiting")
        ) {
            for (_, _, before, after) in &mut result {
                if !after.is_null() {
                    *before = Value::Null;
                }
            }
        }
        return result;
    }
    if collection != "ai:settings" {
        // A completed conversation must include fields skipped while it was streaming.
        let before = if collection == "ai:conversations"
            && matches!(
                before["status"].as_str(),
                Some("running" | "streaming" | "thinking" | "waiting")
            ) {
            Value::Null
        } else {
            before
        };
        return vec![(collection.into(), record.into(), before, after)];
    }
    let mut result = Vec::new();
    for (field, kind, id_key) in [
        ("providers", "ai:providers", "id"),
        ("quickMessages", "ai:prompts", "slug"),
    ] {
        let map = |value: &Value| -> BTreeMap<String, Value> {
            value[field]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v[id_key].as_str().map(|id| (id.to_owned(), v.clone())))
                .collect()
        };
        let mut old = map(&before);
        let new = map(&after);
        for (id, value) in new {
            let previous = old.remove(&id).unwrap_or(Value::Null);
            result.push((kind.into(), id, previous, value));
        }
        for (id, value) in old {
            result.push((kind.into(), id, value, Value::Null));
        }
    }
    let clean = |mut value: Value| {
        if let Some(object) = value.as_object_mut() {
            object.remove("providers");
            object.remove("quickMessages");
        }
        value
    };
    result.push((
        collection.into(),
        record.into(),
        clean(before),
        clean(after),
    ));
    result
}
