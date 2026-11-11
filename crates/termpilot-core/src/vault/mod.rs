pub mod crypto;
pub mod batch_library;
pub mod model;
mod portable;
mod migrations;
#[cfg(test)]
mod tests;
use crate::connection::CoreError;
use model::*;
use rusqlite::{
    params_from_iter,
    types::{Value as SqlValue, ValueRef},
    Connection, OptionalExtension,
};
use serde_json::{json, Map, Value};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::Duration,
};
use zeroize::Zeroizing;
type Result<T> = std::result::Result<T, CoreError>;
fn database_error(_: rusqlite::Error) -> CoreError {
    CoreError::new(
        "databaseError",
        "The vault operation failed. No partial changes were saved.",
    )
}
fn io_error(_: std::io::Error) -> CoreError {
    CoreError::new("vaultIO", "Unable to access the TermPilot data directory.")
}
fn invalid() -> CoreError {
    CoreError::new("invalidRecord", "Invalid vault record or identifier.")
}
fn table(collection: &str) -> Result<&'static str> {
    match collection {
        "hosts" => Ok("hosts"),
        "groups" => Ok("host_groups"),
        "credentials" => Ok("ssh_credentials"),
        "proxies" => Ok("ssh_proxy_profiles"),
        "screenSharing" => Ok("screen_sharing_profiles"),
        "history" => Ok("connection_history"),
        "forwards" => Ok("port_forward_rules"),
        "scripts" => Ok("automation_scripts"),
        "notes" => Ok("host_notes"),
        _ => Err(CoreError::new(
            "unknownCollection",
            "Unknown vault collection.",
        )),
    }
}
fn pk(collection: &str) -> &'static str {
    if collection == "screenSharing" {
        "host_id"
    } else {
        "id"
    }
}
fn uuid(value: &Value) -> Result<String> {
    uuid::Uuid::parse_str(value.as_str().unwrap_or(""))
        .map(|id| id.to_string().to_uppercase())
        .map_err(|_| invalid())
}
fn sql_value(v: &Value) -> Result<SqlValue> {
    Ok(match v {
        Value::Null => SqlValue::Null,
        Value::Bool(b) => SqlValue::Integer(i64::from(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                SqlValue::Integer(i)
            } else {
                SqlValue::Real(n.as_f64().ok_or_else(invalid)?)
            }
        }
        Value::String(s) => SqlValue::Text(s.clone()),
        _ => return Err(invalid()),
    })
}

pub struct Vault {
    pub(crate) db: Connection,
    pub(crate) key: Zeroizing<Vec<u8>>,
    pub directory: PathBuf,
}
impl Vault {
    pub fn validate_record(collection: &str, mut record: Value) -> Result<Value> {
        table(collection)?;
        validate(collection, &mut record)?;
        Ok(record)
    }
    pub fn open(directory: &Path, key_path: Option<&Path>) -> Result<Self> {
        if !directory.is_absolute() {
            return Err(CoreError::new(
                "invalidPath",
                "Vault path must be absolute.",
            ));
        }
        fs::create_dir_all(directory).map_err(io_error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).map_err(io_error)?;
        }
        let file = directory.join("vault.sqlite");
        let key_file = key_path
            .map(Path::to_path_buf)
            .unwrap_or_else(|| directory.join("credential.key"));
        if !key_file.exists() {
            if file.exists() && file.metadata().map_err(io_error)?.len() > 0 {
                return Err(CoreError::new(
                    "missingCredentialKey",
                    "The existing vault's credential key is missing.",
                ));
            }
            let key = crypto::random_key();
            let mut opts = fs::OpenOptions::new();
            opts.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                opts.mode(0o600);
            }
            match opts.open(&key_file) {
                Ok(mut f) => {
                    f.write_all(&key).map_err(io_error)?;
                    f.sync_all().map_err(io_error)?;
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(io_error(e)),
            }
        }
        let key = Zeroizing::new(fs::read(key_file).map_err(io_error)?);
        Self::open_with_key(directory, &key)
    }

    /// Open the existing schema using a key supplied by Keychain/Keystore.
    /// This path never creates or replaces a plaintext credential.key file.
    pub fn open_with_key(directory: &Path, key: &[u8]) -> Result<Self> {
        if !directory.is_absolute() {
            return Err(CoreError::new(
                "invalidPath",
                "Vault path must be absolute.",
            ));
        }
        if key.len() != 32 {
            return Err(CoreError::new(
                "invalidCredentialKey",
                "Invalid credential key.",
            ));
        }
        fs::create_dir_all(directory).map_err(io_error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).map_err(io_error)?;
        }
        let key = Zeroizing::new(key.to_vec());
        let file = directory.join("vault.sqlite");
        let db = Connection::open(file).map_err(database_error)?;
        db.busy_timeout(Duration::from_secs(5))
            .map_err(database_error)?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")
            .map_err(database_error)?;
        let initialized: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='grdb_migrations')",
                [],
                |r| r.get(0),
            )
            .map_err(database_error)?;
        if !initialized {
            db.execute_batch(&format!(
                "BEGIN IMMEDIATE; {} COMMIT;",
                include_str!("schema.sql")
            ))
            .map_err(database_error)?;
        }
        let mut stmt = db
            .prepare("SELECT identifier FROM grdb_migrations")
            .map_err(database_error)?;
        let migrations = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(database_error)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(database_error)?;
        let known: HashSet<&str> = include_str!("schema.sql")
            .lines()
            .filter_map(|l| {
                l.strip_prefix("INSERT INTO grdb_migrations(identifier) VALUES ('")
                    .and_then(|s| s.strip_suffix("');"))
            })
            .collect();
        drop(stmt);
        if migrations.len() + 1 == known.len()
            && !migrations.iter().any(|m| m == migrations::CREDENTIAL_ELEVATION)
            && migrations.iter().all(|m| known.contains(m.as_str()))
        {
            migrations::credential_elevation(&db, directory)?;
        } else if migrations.len() != known.len() || migrations.iter().any(|m| !known.contains(m.as_str()))
        {
            return Err(CoreError::new(
                "unsupportedSchema",
                "Open this vault with a compatible TermPilot version before continuing.",
            ));
        }
        batch_library::install(&db, directory)?;
        crate::sync::journal::register(&db, &key)?;
        crate::sync::journal::install(&db, false)?;
        Ok(Self {
            db,
            key,
            directory: directory.to_path_buf(),
        })
    }
    pub fn list(&self, collection: &str) -> Result<Vec<Value>> {
        let table = table(collection)?;
        let order = match collection {
            "hosts" => "group_id,sort_order,label COLLATE NOCASE",
            "groups" => "sort_order,name COLLATE NOCASE",
            "credentials" => "label COLLATE NOCASE",
            "proxies" | "scripts" => "sort_order",
            "history" => "started_at DESC",
            "screenSharing" => "host_id",
            _ => "updated_at DESC",
        };
        let mut stmt = self
            .db
            .prepare(&format!("SELECT * FROM {table} ORDER BY {order}"))
            .map_err(database_error)?;
        let columns: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let mut rows = stmt.query([]).map_err(database_error)?;
        let mut result = Vec::new();
        while let Some(row) = rows.next().map_err(database_error)? {
            let mut object = Map::new();
            for (i, column) in columns.iter().enumerate() {
                let raw = match row.get_ref(i).map_err(database_error)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(n) => json!(n),
                    ValueRef::Text(s) => json!(String::from_utf8_lossy(s)),
                    ValueRef::Blob(b) => serde_json::from_slice(b).map_err(|_| invalid())?,
                };
                if column == "payload" {
                    object.insert("payload".into(), raw);
                    continue;
                }
                let value = if is_secret(column) {
                    crypto::decrypt_field(&self.key, &raw)?
                } else if is_bool(column) && !raw.is_null() {
                    json!(raw.as_i64().unwrap_or(0) != 0)
                } else if column.ends_with("_at") {
                    swift_date(&raw)
                } else {
                    raw
                };
                object.insert(key(column), value);
            }
            if let Some(mut payload) = object.remove("payload") {
                if let Some(id) = object.get("hostID") {
                    payload["hostID"] = id.clone();
                }
                if let Some(order) = object.get("sortOrder") {
                    payload["sortOrder"] = order.clone();
                }
                result.push(payload);
                continue;
            }
            let mut item = Value::Object(object);
            if collection == "hosts" {
                if !item["proxyType"].is_null() {
                    item["proxyConfiguration"] = json!({"type":item["proxyType"],"host":item["proxyHost"],"port":item["proxyPort"],"command":item["proxyCommand"],"credentialID":item["proxyCredentialReference"],"username":item["proxyUsername"],"password":item["proxyPassword"]});
                }
                for k in [
                    "proxyType",
                    "proxyHost",
                    "proxyPort",
                    "proxyCommand",
                    "proxyCredentialReference",
                    "proxyUsername",
                    "proxyPassword",
                ] {
                    item.as_object_mut().unwrap().remove(k);
                }
            } else if collection == "proxies" {
                item["configuration"] = json!({"type":item["type"],"host":item["host"],"port":item["port"],"command":item["command"],"credentialID":item["credentialID"],"username":item["username"],"password":item["password"]});
                for k in [
                    "type",
                    "host",
                    "port",
                    "command",
                    "credentialID",
                    "username",
                    "password",
                ] {
                    item.as_object_mut().unwrap().remove(k);
                }
            }
            result.push(item);
        }
        Ok(result)
    }
    pub fn get(&self, collection: &str, id: &Value) -> Result<Option<Value>> {
        let id = uuid(id)?;
        let k = if collection == "screenSharing" {
            "hostID"
        } else {
            "id"
        };
        Ok(self
            .list(collection)?
            .into_iter()
            .find(|v| v[k].as_str().is_some_and(|s| s.eq_ignore_ascii_case(&id))))
    }
    fn validate_parent(&self, id: &str, parent: &Value) -> Result<()> {
        let mut current = parent.as_str().map(str::to_owned);
        let mut seen = HashSet::new();
        while let Some(value) = current {
            let value = uuid(&json!(value))?;
            if value == id || !seen.insert(value.clone()) {
                return Err(CoreError::new(
                    "groupCycle",
                    "A group cannot be its own descendant.",
                ));
            }
            current = self
                .db
                .query_row(
                    "SELECT parent_group_id FROM host_groups WHERE id=?",
                    [value],
                    |r| r.get::<_, Option<String>>(0),
                )
                .optional()
                .map_err(database_error)?
                .flatten();
        }
        Ok(())
    }
    fn save_inner(&self, collection: &str, mut item: Value) -> Result<Value> {
        validate(collection, &mut item)?;
        let table = table(collection)?;
        let key_field = if collection == "screenSharing" {
            "hostID"
        } else {
            "id"
        };
        if item[key_field].is_null() {
            item[key_field] = json!(uuid::Uuid::new_v4().to_string().to_uppercase());
        }
        let id = uuid(&item[key_field])?;
        item[key_field] = json!(id);
        for key in [
            "hostID",
            "groupID",
            "parentGroupID",
            "credentialID",
            "proxyProfileID",
        ] {
            if !item[key].is_null() {
                item[key] = json!(uuid(&item[key])?);
            }
        }
        if collection == "groups" {
            self.validate_parent(&id, &item["parentGroupID"])?;
        }
        let existing = self.get(collection, &json!(id))?;
        let sync_enabled: bool = self
            .db
            .query_row("SELECT enabled FROM tp_sync_context WHERE id=1", [], |r| {
                r.get(0)
            })
            .map_err(database_error)?;
        if sync_enabled {
            if let (Some(previous), Some(expected)) = (existing.as_ref(), item.get("updatedAt")) {
                if let (Some(current), Some(expected)) =
                    (previous["updatedAt"].as_f64(), expected.as_f64())
                {
                    if (current - expected).abs() > 0.002 {
                        return Err(CoreError::new("staleEdit","此记录已被另一个窗口或同步更新。请保留当前草稿，重新打开记录后合并修改。"));
                    }
                }
            }
        }
        if item["createdAt"].is_null() {
            item["createdAt"] = now();
        }
        item["updatedAt"] = now();
        let columns: Vec<(String, Option<String>)> = {
            let mut statement = self
                .db
                .prepare(&format!("PRAGMA table_info({table})"))
                .map_err(database_error)?;
            let rows = statement
                .query_map([], |r| Ok((r.get(1)?, r.get(4)?)))
                .map_err(database_error)?;
            rows.collect::<std::result::Result<_, _>>()
                .map_err(database_error)?
        };
        let payload = matches!(collection, "forwards" | "scripts" | "notes");
        let mut names = Vec::new();
        let mut values = Vec::new();
        for (column, default) in columns {
            if column == "payload" {
                names.push(column);
                values.push(SqlValue::Blob(
                    serde_json::to_vec(&item).map_err(|_| invalid())?,
                ));
                continue;
            }
            let json_key = key(&column);
            let mut value = if collection == "proxies"
                && matches!(
                    column.as_str(),
                    "type"
                        | "host"
                        | "port"
                        | "command"
                        | "credential_reference"
                        | "username"
                        | "password"
                ) {
                item["configuration"][json_key.as_str()].clone()
            } else if collection == "hosts"
                && column.starts_with("proxy_")
                && column != "proxy_profile_reference"
            {
                let k = if column == "proxy_credential_reference" {
                    "credentialID".into()
                } else {
                    key(column.strip_prefix("proxy_").unwrap())
                };
                item["proxyConfiguration"][k.as_str()].clone()
            } else {
                item[json_key.as_str()].clone()
            };
            if column == "sort_order"
                && (value.is_null() || collection == "proxies" || collection == "scripts")
            {
                value = existing
                    .as_ref()
                    .and_then(|v| v.get("sortOrder"))
                    .cloned()
                    .unwrap_or_else(|| {
                        json!(self
                            .db
                            .query_row(
                                &format!("SELECT COALESCE(MAX(sort_order),-1)+1 FROM {table}"),
                                [],
                                |r| r.get::<_, i64>(0)
                            )
                            .unwrap_or(0))
                    });
            }
            if column == "sort_order"
                && collection == "hosts"
                && (existing.is_none() || existing.as_ref().unwrap()["groupID"] != item["groupID"])
            {
                let group = item["groupID"].as_str();
                value = json!(self
                    .db
                    .query_row(
                        "SELECT COALESCE(MAX(sort_order),-1)+1 FROM hosts WHERE group_id IS ?",
                        [group],
                        |r| r.get::<_, i64>(0)
                    )
                    .map_err(database_error)?);
            }
            if value.is_null() && default.is_some() {
                continue;
            }
            if column.ends_with("_at") {
                value = sql_date(&value);
            }
            if is_secret(&column) {
                value = crypto::encrypt_field(&self.key, &value)?;
            }
            names.push(column);
            values.push(sql_value(&value)?);
        }
        let placeholders = vec!["?"; names.len()].join(",");
        let assignments = names
            .iter()
            .filter(|n| n.as_str() != pk(collection))
            .map(|n| format!("{n}=excluded.{n}"))
            .collect::<Vec<_>>()
            .join(",");
        self.db.execute(&format!("INSERT INTO {table} ({}) VALUES ({placeholders}) ON CONFLICT({}) DO UPDATE SET {assignments}",names.join(","),pk(collection)),params_from_iter(values)).map_err(database_error)?;
        if payload {
            Ok(item)
        } else {
            self.get(collection, &json!(id))?.ok_or_else(invalid)
        }
    }
    fn transaction<T>(&self, body: impl FnOnce() -> Result<T>) -> Result<T> {
        self.db
            .execute_batch("BEGIN IMMEDIATE")
            .map_err(database_error)?;
        match body() {
            Ok(v) => {
                self.db.execute_batch("COMMIT").map_err(database_error)?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.db.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }
    pub fn save(&self, collection: &str, item: Value, screen: Option<Value>) -> Result<Value> {
        self.transaction(|| {
            let saved = self.save_inner(collection, item)?;
            if let Some(mut profile) = screen {
                profile["hostID"] = saved["id"].clone();
                self.save_inner("screenSharing", profile)?;
            }
            Ok(saved)
        })
    }
    /// Atomically validate and save a batch, including AI-assisted imports.
    pub fn save_batch(&self, collection: &str, items: Vec<Value>) -> Result<Vec<Value>> {
        self.transaction(|| {
            items
                .into_iter()
                .map(|item| self.save_inner(collection, item))
                .collect()
        })
    }
    pub fn delete(&self, collection: &str, id: &Value) -> Result<()> {
        let id = uuid(id)?;
        let table = table(collection)?;
        self.transaction(||{
            if collection=="credentials"{self.db.execute("UPDATE hosts SET credential_reference=NULL WHERE credential_reference=?",[&id]).map_err(database_error)?;}
            if collection=="proxies"{self.db.execute("UPDATE hosts SET proxy_profile_reference=NULL WHERE proxy_profile_reference=?",[&id]).map_err(database_error)?;}
            if collection=="groups"{
                self.db.execute("WITH RECURSIVE descendants(id) AS (SELECT ? UNION SELECT g.id FROM host_groups g JOIN descendants d ON g.parent_group_id=d.id) UPDATE hosts SET group_id=NULL WHERE group_id IN descendants",[&id]).map_err(database_error)?;
                self.db.execute("WITH RECURSIVE descendants(id) AS (SELECT ? UNION SELECT g.id FROM host_groups g JOIN descendants d ON g.parent_group_id=d.id) DELETE FROM host_groups WHERE id IN descendants",[&id]).map_err(database_error)?;
            }else{self.db.execute(&format!("DELETE FROM {table} WHERE {}=?",pk(collection)),[id]).map_err(database_error)?;}
            Ok(())
        })
    }
    pub fn reorder(&self, collection: &str, ids: &Value, parent: &Value) -> Result<()> {
        if !matches!(collection, "hosts" | "groups" | "proxies" | "scripts") {
            return Err(invalid());
        }
        let table = table(collection)?;
        let ids = ids.as_array().ok_or_else(invalid)?;
        self.transaction(|| {
            for (order, id) in ids.iter().enumerate() {
                let id = uuid(id)?;
                if collection == "groups" {
                    self.validate_parent(&id, parent)?;
                }
                if matches!(collection, "hosts" | "groups") {
                    let column = if collection == "hosts" {
                        "group_id"
                    } else {
                        "parent_group_id"
                    };
                    self.db
                        .execute(
                            &format!("UPDATE {table} SET sort_order=?,{column}=? WHERE id=?"),
                            rusqlite::params![order as i64, parent.as_str(), id],
                        )
                        .map_err(database_error)?;
                } else {
                    self.db
                        .execute(
                            &format!("UPDATE {table} SET sort_order=? WHERE id=?"),
                            rusqlite::params![order as i64, id],
                        )
                        .map_err(database_error)?;
                }
            }
            Ok(())
        })
    }
    pub fn snapshot(&self) -> Result<Value> {
        let mut value = json!({"schemaVersion":1,"exportedAt":now()});
        for (c, k) in [
            ("hosts", "hosts"),
            ("groups", "groups"),
            ("credentials", "credentials"),
            ("proxies", "proxyProfiles"),
            ("forwards", "portForwardRules"),
            ("scripts", "automationScripts"),
            ("notes", "hostNotes"),
            ("screenSharing", "screenSharingProfiles"),
        ] {
            value[k] = json!(self.list(c)?);
        }
        value["batchJobs"] = json!(self.batch_library()?);
        backup_dates(&mut value, true);
        Ok(value)
    }
    pub fn import(&self, mut snapshot: Value) -> Result<Value> {
        if snapshot["schemaVersion"] != 1 {
            return Err(CoreError::new(
                "unsupportedSnapshotVersion",
                "Unsupported backup version.",
            ));
        }
        for key in [
            "hosts",
            "groups",
            "credentials",
            "proxyProfiles",
            "portForwardRules",
            "automationScripts",
            "hostNotes",
        ] {
            if !snapshot[key].is_array() {
                return Err(invalid());
            }
        }
        if !snapshot["batchJobs"].is_null() && !snapshot["batchJobs"].is_array() { return Err(invalid()); }
        backup_dates(&mut snapshot, false);
        self.transaction(||{
            for item in snapshot["credentials"].as_array().unwrap(){self.save_inner("credentials",item.clone())?;}
            let remove_missing=|value:&mut Value,key:&str,collection:&str|->Result<()>{if !value[key].is_null()&&self.get(collection,&value[key])?.is_none(){value[key]=Value::Null;}Ok(())};
            for item in snapshot["proxyProfiles"].as_array().unwrap(){let mut item=item.clone();remove_missing(&mut item["configuration"],"credentialID","credentials")?;self.save_inner("proxies",item)?;}
            let mut groups=snapshot["groups"].as_array().cloned().unwrap();
            while !groups.is_empty(){
                let before=groups.len();let mut deferred=Vec::new();
                for group in groups {if group["parentGroupID"].is_null()||self.get("groups",&group["parentGroupID"])?.is_some(){self.save_inner("groups",group)?;}else{deferred.push(group);}}
                groups=deferred;if groups.len()==before{return Err(CoreError::new("groupCycle","Backup contains missing or cyclic parent groups."));}
            }
            fn identity(host:&Value)->String{let name=host["hostname"].as_str().unwrap_or("").trim().to_lowercase();let name=name.trim_start_matches('[').trim_end_matches(']').trim_end_matches('.');name.parse::<std::net::IpAddr>().map(|a|a.to_string()).unwrap_or_else(|_|name.to_string())}
            let existing=self.list("hosts")?;
            let mut by_identity:HashMap<String,String>=existing.iter().map(|h|(identity(h),h["id"].as_str().unwrap().to_string())).collect();
            let mut replacements=HashMap::new();let mut saved=HashSet::new();let mut duplicates=0;
            for item in snapshot["hosts"].as_array().unwrap(){
                let original=uuid(&item["id"])?;let normalized=identity(item);
                let target=if let Some(id)=by_identity.get(&normalized){duplicates+=1;id.clone()}else{original.clone()};
                replacements.insert(original,target.clone());by_identity.insert(normalized,target.clone());
                if !saved.insert(target.clone()){continue;}
                let mut item=item.clone();item["id"]=json!(target);
                if let Some(old)=existing.iter().find(|h|h["id"]==target){item["createdAt"]=old["createdAt"].clone();}
                for (key,collection) in [("groupID","groups"),("credentialID","credentials"),("proxyProfileID","proxies")]{remove_missing(&mut item,key,collection)?;}
                if item["proxyConfiguration"].is_object(){remove_missing(&mut item["proxyConfiguration"],"credentialID","credentials")?;}
                self.save_inner("hosts",item)?;
            }
            for (c,k) in [("screenSharing","screenSharingProfiles"),("forwards","portForwardRules"),("scripts","automationScripts"),("notes","hostNotes")]{
                for item in snapshot[k].as_array().into_iter().flatten(){let mut item=item.clone();
                    if !item["hostID"].is_null(){let original=uuid(&item["hostID"])?;if let Some(target)=replacements.get(&original){item["hostID"]=json!(target);}remove_missing(&mut item,"hostID","hosts")?;}
                    if c=="screenSharing"&&item["hostID"].is_null(){continue;}
                    if c=="forwards"{item["status"]=json!("inactive");item["error"]=Value::Null;}
                    self.save_inner(c,item)?;
                }
            }
            for job in snapshot["batchJobs"].as_array().into_iter().flatten() {
                let mut item = job.clone();
                let mut config: Value = serde_json::from_str(item["configuration"].as_str().ok_or_else(invalid)?).map_err(|_| invalid())?;
                for target in config["targets"].as_array_mut().ok_or_else(invalid)? {
                    if let Some(original) = target["savedHostId"].as_str() {
                        if let Some(mapped) = replacements.get(&original.to_uppercase()) { target["savedHostId"] = json!(mapped); }
                    }
                }
                item["configuration"] = json!(serde_json::to_string(&config).map_err(|_| invalid())?);
                self.save_batch_job_inner(&item, true)?;
            }
            Ok(json!({"hosts":saved.len(),"deduplicatedHosts":duplicates,"credentials":snapshot["credentials"].as_array().unwrap().len()}))
        })
    }
}
pub fn dispatch(request: &Value) -> Result<Value> {
    dispatch_with_key(request, None)
}

pub fn dispatch_with_key(request: &Value, key: Option<&[u8]>) -> Result<Value> {
    let directory = Path::new(request["directory"].as_str().ok_or_else(invalid)?);
    if request["method"] == "vault.prepareDirectory" {
        return portable::prepare(
            directory,
            Path::new(request["legacyDirectory"].as_str().ok_or_else(invalid)?),
        );
    }
    let vault = match key {
        Some(key) => Vault::open_with_key(directory, key)?,
        None => Vault::open(directory, request["keyPath"].as_str().map(Path::new))?,
    };
    let collection = request["collection"].as_str().unwrap_or("hosts");
    match request["method"].as_str().unwrap_or("") {
        "vault.list" => {
            let mut items = vault.list(collection)?;
            if let Some(query) = request["search"].as_str().filter(|q| !q.is_empty()) {
                let q = query.to_lowercase();
                items.retain(|v| {
                    ["label", "name", "hostname", "username", "title"]
                        .iter()
                        .any(|k| {
                            v[*k]
                                .as_str()
                                .is_some_and(|s| s.to_lowercase().contains(&q))
                        })
                });
            }
            Ok(json!({"items":items}))
        }
        "vault.batchStorage" => vault.batch_storage(request),
        "vault.get" => Ok(json!({"item":vault.get(collection,&request["id"])?})),
        "vault.host.duplicateDraft" => vault.transaction(|| {
            let mut item = vault.get("hosts", &request["id"])?.ok_or_else(invalid)?;
            let mut profile = vault.get("screenSharing", &request["id"])?;
            let id = uuid::Uuid::new_v4().to_string();
            let fields = item.as_object_mut().ok_or_else(invalid)?;
            for field in ["createdAt", "updatedAt", "lastConnectedAt", "sortOrder"] {
                fields.remove(field);
            }
            fields.insert("id".into(), json!(id));
            if let Some(profile) = profile.as_mut() {
                profile["hostID"] = json!(id);
            }
            // A draft is not inserted. Cancelling the editor leaves no new host,
            // journal event, stale revision or orphaned remote-desktop profile.
            Ok(json!({"item":item,"screenSharingProfile":profile}))
        }),
        "vault.save" => Ok(
            json!({"item":vault.save(collection,request["item"].clone(),request.get("screenSharingProfile").filter(|v|v.is_object()).cloned())?}),
        ),
        "vault.delete" => {
            vault.delete(collection, &request["id"])?;
            Ok(json!({"deleted":true}))
        }
        "vault.reorder" => {
            vault.reorder(collection, &request["ids"], &request["parentID"])?;
            Ok(json!({"saved":true}))
        }
        "vault.export" => {
            let data = crypto::encrypt_backup(
                &vault.snapshot()?,
                request["password"].as_str().unwrap_or(""),
            )?;
            let path = Path::new(request["path"].as_str().ok_or_else(invalid)?);
            if !path.is_absolute() {
                return Err(invalid());
            }
            fs::write(path, data).map_err(io_error)?;
            Ok(json!({"exported":true}))
        }
        "vault.import" => {
            let path = Path::new(request["path"].as_str().ok_or_else(invalid)?);
            if fs::metadata(path).map_err(io_error)?.len() > 100 * 1024 * 1024 {
                return Err(CoreError::new("backupTooLarge", "Backup exceeds 100 MiB."));
            }
            let data = fs::read(path).map_err(io_error)?;
            vault.import(crypto::decrypt_backup(
                &data,
                request["password"].as_str().unwrap_or(""),
            )?)
        }
        "vault.snapshot" => Ok(json!({"snapshot":vault.snapshot()?})),
        _ => Err(CoreError::new("unknownMethod", "Unknown vault operation.")),
    }
}
