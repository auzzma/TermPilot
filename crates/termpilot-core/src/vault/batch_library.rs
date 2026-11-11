//! Reusable jobs and local editor drafts. No worker state or resolved credentials.
use super::*;
use rusqlite::params;
pub const SCHEMA: &str = include_str!("batch_schema.sql");

fn invalid_batch() -> CoreError {
    CoreError::new("invalidBatchDocument", "Invalid or unsupported saved job.")
}
fn conflict() -> CoreError {
    CoreError::new(
        "batchConflict",
        "This job changed in another window. Reopen it or use Save as.",
    )
}

pub(super) fn install(db: &Connection, directory: &Path) -> Result<()> {
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='batch_saved_jobs')",
            [],
            |r| r.get(0),
        )
        .map_err(database_error)?;
    if exists {
        return Ok(());
    }
    // A SQLite backup includes committed WAL data, unlike copying vault.sqlite.
    let path = directory.join(format!(
        "vault.sqlite.before-batch-library-v1-{}",
        uuid::Uuid::new_v4()
    ));
    db.backup(rusqlite::DatabaseName::Main, &path, None)
        .map_err(database_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(io_error)?;
    }
    let transaction = db.unchecked_transaction().map_err(database_error)?;
    transaction.execute_batch(SCHEMA).map_err(database_error)?;
    transaction.commit().map_err(database_error)
}

/// A deliberately small, credential-free target contract shared by both clients.
#[derive(serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TargetReference {
    id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    saved_host_id: Option<String>,
    label: String,
    hostname: String,
    port: i64,
    username: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    credential_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    proxy_profile_id: Option<String>,
    elevation: String,
}

pub fn configuration(text: &str) -> Result<String> {
    if text.len() > 768 * 1024 {
        return Err(invalid_batch());
    }
    let mut v: Value = serde_json::from_str(text).map_err(|_| invalid_batch())?;
    if v["version"] != 1 || !v["job"].is_object() {
        return Err(invalid_batch());
    }
    let allowed = ["version", "job", "targets", "defaults"];
    if v.as_object()
        .ok_or_else(invalid_batch)?
        .keys()
        .any(|k| !allowed.contains(&k.as_str()))
    {
        return Err(invalid_batch());
    }
    // Drafts may be incomplete or have temporarily invalid numeric settings.
    // Execution validation belongs to batch.start, not autosave.
    let baseline =
        serde_json::to_value(crate::batch::Job::default()).map_err(|_| invalid_batch())?;
    if v["job"]
        .as_object()
        .unwrap()
        .keys()
        .any(|k| baseline.get(k).is_none())
    {
        return Err(invalid_batch());
    }
    for key in ["script", "before", "after"] {
        if !v["job"][key].is_null() {
            serde_json::from_value::<crate::batch::Script>(v["job"][key].clone())
                .map_err(|_| invalid_batch())?;
        }
    }
    v["job"]["remoteWorkDirectory"] = json!("");
    v["job"]["sourceTaskId"] = json!("");
    let targets: Vec<TargetReference> =
        serde_json::from_value(v["targets"].clone()).map_err(|_| invalid_batch())?;
    if targets.len() > 1000 {
        return Err(invalid_batch());
    }
    let mut ids = HashSet::new();
    for target in &targets {
        uuid(&json!(target.id))?;
        if !ids.insert(target.id.to_uppercase()) {
            return Err(invalid_batch());
        }
        for id in [
            &target.saved_host_id,
            &target.credential_id,
            &target.proxy_profile_id,
        ]
        .into_iter()
        .flatten()
        {
            uuid(&json!(id))?;
        }
        if !matches!(target.elevation.as_str(), "none" | "sudo" | "su") {
            return Err(invalid_batch());
        }
    }
    v["targets"] = serde_json::to_value(targets).map_err(|_| invalid_batch())?;
    if !v["defaults"].is_object()
        || v["defaults"]
            .as_object()
            .unwrap()
            .keys()
            .any(|k| !["ips", "port", "credential", "elevation"].contains(&k.as_str()))
    {
        return Err(invalid_batch());
    }
    serde_json::to_string(&v).map_err(|_| invalid_batch())
}

impl Vault {
    pub fn batch_library(&self) -> Result<Vec<Value>> {
        let mut statement = self.db.prepare("SELECT id,name,configuration,created_ms,updated_ms,revision FROM batch_saved_jobs ORDER BY updated_ms DESC,id").map_err(database_error)?;
        let rows = statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                ))
            })
            .map_err(database_error)?;
        rows.map(|row| {
            let (id,name,encrypted,created,updated,revision) = row.map_err(database_error)?;
            let config = crypto::decrypt_field(&self.key, &json!(encrypted))?;
            Ok(json!({"id":id,"name":name,"configuration":config,"createdMs":created,"updatedMs":updated,"revision":revision}))
        }).collect()
    }

    pub fn save_batch_job(&self, item: &Value) -> Result<Value> {
        self.transaction(|| self.save_batch_job_inner(item, false))
    }

    pub(super) fn save_batch_job_inner(&self, item: &Value, importing: bool) -> Result<Value> {
        let name = item["name"].as_str().unwrap_or("").trim();
        if name.is_empty() || name.chars().count() > 160 {
            return Err(CoreError::new(
                "batchName",
                "Enter a job name of 1–160 characters.",
            ));
        }
        let id = if item["id"].is_null() {
            uuid::Uuid::new_v4().to_string().to_uppercase()
        } else {
            uuid(&item["id"])?
        };
        let config = configuration(item["configuration"].as_str().ok_or_else(invalid_batch)?)?;
        let existing: Option<(i64, i64)> = self
            .db
            .query_row(
                "SELECT created_ms,revision FROM batch_saved_jobs WHERE id=?",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(database_error)?;
        if !importing && !item["id"].is_null() && existing.map(|v| v.1) != item["revision"].as_i64()
        {
            return Err(conflict());
        }
        let now = chrono::Utc::now().timestamp_millis();
        let (created, revision) = existing.map(|(c, r)| (c, r + 1)).unwrap_or((now, 1));
        let encrypted = crypto::encrypt_field(&self.key, &json!(config))?;
        self.db.execute("INSERT INTO batch_saved_jobs VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(id) DO UPDATE SET name=excluded.name,configuration=excluded.configuration,updated_ms=excluded.updated_ms,revision=excluded.revision", params![id,name,encrypted.as_str(),created,now,revision]).map_err(database_error)?;
        Ok(
            json!({"id":id,"name":name,"configuration":config,"createdMs":created,"updatedMs":now,"revision":revision}),
        )
    }

    pub fn delete_batch_job(&self, id: &Value, revision: i64) -> Result<()> {
        let count = self
            .db
            .execute(
                "DELETE FROM batch_saved_jobs WHERE id=? AND revision=?",
                params![uuid(id)?, revision],
            )
            .map_err(database_error)?;
        if count != 1 {
            return Err(conflict());
        }
        Ok(())
    }

    pub fn batch_draft(&self, id: &str) -> Result<Value> {
        let row: Option<(String, i64)> = self
            .db
            .query_row(
                "SELECT payload,revision FROM batch_editor_drafts WHERE id=?",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(database_error)?;
        match row {
            Some((payload, revision)) => Ok(
                json!({"payload":crypto::decrypt_field(&self.key,&json!(payload))?,"revision":revision}),
            ),
            None => Ok(json!({"payload":null,"revision":0})),
        }
    }

    pub fn save_batch_draft(&self, id: &str, payload: &str, revision: i64) -> Result<Value> {
        if id.is_empty() || id.len() > 100 || payload.len() > 8 * 1024 * 1024 {
            return Err(invalid_batch());
        }
        let mut doc: Value = serde_json::from_str(payload).map_err(|_| invalid_batch())?;
        if doc["version"] != 1 {
            return Err(invalid_batch());
        }
        let tabs = doc["tabs"].as_array_mut().ok_or_else(invalid_batch)?;
        if tabs.len() > 100 {
            return Err(invalid_batch());
        }
        let mut ids = HashSet::new();
        for tab in tabs {
            let tab_id = uuid(&tab["id"])?;
            if !ids.insert(tab_id) {
                return Err(invalid_batch());
            }
            if tab.as_object().ok_or_else(invalid_batch)?.keys().any(|k| {
                ![
                    "id",
                    "name",
                    "number",
                    "savedId",
                    "savedRevision",
                    "configuration",
                    "historyId",
                ]
                .contains(&k.as_str())
            }) {
                return Err(invalid_batch());
            }
            tab["configuration"] = json!(configuration(
                tab["configuration"].as_str().ok_or_else(invalid_batch)?
            )?);
        }
        if doc
            .as_object()
            .unwrap()
            .keys()
            .any(|k| !["version", "tabs", "selected"].contains(&k.as_str()))
        {
            return Err(invalid_batch());
        }
        let encrypted = crypto::encrypt_field(
            &self.key,
            &json!(serde_json::to_string(&doc).map_err(|_| invalid_batch())?),
        )?;
        self.transaction(|| {
            let current = self.batch_draft(id)?["revision"].as_i64().unwrap_or(0);
            if current != revision { return Err(conflict()); }
            self.db.execute("INSERT INTO batch_editor_drafts VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision", params![id,encrypted.as_str(),revision+1]).map_err(database_error)?;
            Ok(json!({"revision":revision+1}))
        })
    }

    pub fn batch_storage(&self, request: &Value) -> Result<Value> {
        match request["operation"].as_str().unwrap_or("") {
            "list" => Ok(json!({"items":self.batch_library()?})),
            "save" => Ok(json!({"item":self.save_batch_job(&request["item"])?})),
            "delete" => {
                self.delete_batch_job(
                    &request["id"],
                    request["revision"].as_i64().ok_or_else(invalid_batch)?,
                )?;
                Ok(json!({"deleted":true}))
            }
            "loadDraft" => {
                self.batch_draft(request["workspace"].as_str().ok_or_else(invalid_batch)?)
            }
            "saveDraft" => self.save_batch_draft(
                request["workspace"].as_str().ok_or_else(invalid_batch)?,
                request["payload"].as_str().ok_or_else(invalid_batch)?,
                request["revision"].as_i64().ok_or_else(invalid_batch)?,
            ),
            _ => Err(invalid_batch()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            Self(
                std::env::temp_dir()
                    .join(format!("termpilot-batch-library-{}", uuid::Uuid::new_v4())),
            )
        }
        fn open(&self) -> Vault {
            Vault::open(&self.0, None).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn config() -> String {
        let mut job = serde_json::to_value(crate::batch::Job::default()).unwrap();
        job["script"]["body"] = json!("echo private-script-marker");
        job["script"]["environment"] = json!({"TOKEN":"private-environment-marker"});
        job["remoteWorkDirectory"] = json!("/old-run");
        job["sourceTaskId"] = json!("previous-run");
        json!({"version":1,"job":job,"targets":[],"defaults":{"ips":"192.0.2.1","port":22,"credential":"","elevation":"none"}}).to_string()
    }
    #[test]
    fn jobs_reopen_encrypted_and_save_as_does_not_overwrite() {
        let fixture = Fixture::new();
        let vault = fixture.open();
        let key = fs::read(fixture.0.join("credential.key")).unwrap();
        let first = vault
            .save_batch_job(&json!({"name":"巡检","configuration":config()}))
            .unwrap();
        let copy = vault
            .save_batch_job(&json!({"name":"巡检副本","configuration":config()}))
            .unwrap();
        assert_ne!(first["id"], copy["id"]);
        let mut changed = first.clone();
        changed["name"] = json!("更新的巡检");
        let saved = vault.save_batch_job(&changed).unwrap();
        assert_eq!(saved["revision"], 2);
        assert!(vault.save_batch_job(&changed).is_err());
        let encrypted: String = vault
            .db
            .query_row(
                "SELECT configuration FROM batch_saved_jobs LIMIT 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(encrypted.starts_with("enc:v1:"));
        assert!(!encrypted.contains("private-"));
        drop(vault);
        let reopened = fixture.open();
        let jobs = reopened.batch_library().unwrap();
        assert_eq!(jobs.len(), 2);
        assert!(jobs.iter().any(|j| j["name"] == "巡检副本"));
        let config: Value =
            serde_json::from_str(jobs[0]["configuration"].as_str().unwrap()).unwrap();
        assert_eq!(config["job"]["remoteWorkDirectory"], "");
        assert_eq!(config["job"]["sourceTaskId"], "");
        assert_eq!(
            config["job"]["script"]["environment"]["TOKEN"],
            "private-environment-marker"
        );
        assert_eq!(fs::read(fixture.0.join("credential.key")).unwrap(), key);
        reopened.delete_batch_job(&saved["id"], 2).unwrap();
        assert!(reopened.save_batch_job(&saved).is_err());
    }
    #[test]
    fn drafts_preserve_order_selection_and_incomplete_edits_without_running_state() {
        let fixture = Fixture::new();
        let vault = fixture.open();
        let a = uuid::Uuid::new_v4().to_string();
        let b = uuid::Uuid::new_v4().to_string();
        let mut incomplete: Value = serde_json::from_str(&config()).unwrap();
        incomplete["job"]["concurrency"] = json!(-1);
        let doc = json!({"version":1,"selected":b,"tabs":[{"id":b,"name":"草稿二","number":2,"configuration":incomplete.to_string()},{"id":a,"name":"草稿一","number":1,"configuration":config()}]});
        vault
            .save_batch_draft("macos-0", &doc.to_string(), 0)
            .unwrap();
        assert!(vault
            .save_batch_draft("macos-0", &doc.to_string(), 0)
            .is_err());
        vault
            .save_batch_draft(
                "macos-1",
                &json!({"version":1,"selected":a,"tabs":[]}).to_string(),
                0,
            )
            .unwrap();
        drop(vault);
        let reopened = fixture.open();
        let value = reopened.batch_draft("macos-0").unwrap();
        let restored: Value = serde_json::from_str(value["payload"].as_str().unwrap()).unwrap();
        assert_eq!(restored["selected"], b);
        assert_eq!(restored["tabs"][0]["id"], b);
        assert_eq!(value["revision"], 1);
        let mut bad = doc;
        bad["tabs"][0]["running"] = json!(true);
        assert!(reopened
            .save_batch_draft("macos-0", &bad.to_string(), 1)
            .is_err());
        assert_eq!(reopened.batch_draft("macos-0").unwrap(), value);
    }
    #[test]
    fn password_bearing_host_objects_are_rejected_and_failed_writes_keep_previous_data() {
        let fixture = Fixture::new();
        let vault = fixture.open();
        let item = vault
            .save_batch_job(&json!({"name":"safe","configuration":config()}))
            .unwrap();
        let mut configuration: Value = serde_json::from_str(&config()).unwrap();
        configuration["targets"] = json!([{"id":uuid::Uuid::new_v4().to_string(),"label":"test","hostname":"192.0.2.1","port":22,"username":"ops","elevation":"none","password":"secret"}]);
        let mut update = item.clone();
        update["configuration"] = json!(configuration.to_string());
        assert!(vault.save_batch_job(&update).is_err());
        assert_eq!(vault.batch_library().unwrap(), vec![item]);
    }
    #[test]
    fn library_is_backed_up_and_reencrypted_but_drafts_are_local() {
        let a = Fixture::new();
        let b = Fixture::new();
        let source = a.open();
        let target = b.open();
        source
            .save_batch_job(&json!({"name":"backup","configuration":config()}))
            .unwrap();
        source
            .save_batch_draft(
                "macos-0",
                &json!({"version":1,"tabs":[],"selected":uuid::Uuid::new_v4().to_string()})
                    .to_string(),
                0,
            )
            .unwrap();
        let backup = source.snapshot().unwrap();
        assert!(backup.get("drafts").is_none());
        target.import(backup).unwrap();
        assert_eq!(target.batch_library().unwrap()[0]["name"], "backup");
        assert_eq!(target.batch_draft("macos-0").unwrap()["revision"], 0);
        let read = |v: &Vault| {
            v.db.query_row("SELECT configuration FROM batch_saved_jobs", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap()
        };
        assert_ne!(read(&source), read(&target));
    }
    #[test]
    fn additive_migration_backs_up_existing_data_before_creating_tables() {
        let f = Fixture::new();
        let v = f.open();
        v.db.execute_batch("DROP TABLE batch_saved_jobs; DROP TABLE batch_editor_drafts;")
            .unwrap();
        for entry in fs::read_dir(&f.0).unwrap().flatten() {
            if entry
                .file_name()
                .to_string_lossy()
                .contains("before-batch-library")
            {
                fs::remove_file(entry.path()).unwrap();
            }
        }
        drop(v);
        let _v = f.open();
        let backups: Vec<_> = fs::read_dir(&f.0)
            .unwrap()
            .flatten()
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .contains("before-batch-library")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        let old = Connection::open(backups[0].path()).unwrap();
        let exists: bool = old
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='batch_saved_jobs')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(!exists);
    }
}
