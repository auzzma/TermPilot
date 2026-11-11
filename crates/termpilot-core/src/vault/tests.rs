use super::*;
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!("termpilot-vault-{}", uuid::Uuid::new_v4())))
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

#[test]
fn credential_elevation_migration_preserves_encrypted_data_backup_and_journal() {
    let dir = Fixture::new();
    let vault = dir.open();
    let credential = vault.save("credentials", json!({"label":"Legacy","username":"ops","kind":"password","password":"fixture-secret"}), None).unwrap();
    let key = fs::read(dir.0.join("credential.key")).unwrap();
    for event in ["INSERT", "UPDATE", "DELETE"] {
        vault.db.execute_batch(&format!("DROP TRIGGER tp_sync_ssh_credentials_{event}")).unwrap();
    }
    vault.db.execute_batch("ALTER TABLE ssh_credentials DROP COLUMN elevation_method; DELETE FROM grdb_migrations WHERE identifier='v19-credential-elevation-method';").unwrap();
    crate::sync::journal::install(&vault.db, false).unwrap();
    drop(vault);

    let vault = dir.open();
    assert_eq!(fs::read(dir.0.join("credential.key")).unwrap(), key);
    let mut restored = vault.list("credentials").unwrap().remove(0);
    assert_eq!(restored["id"], credential["id"]);
    assert_eq!(restored["password"], "fixture-secret");
    assert!(restored["elevationMethod"].is_null());
    let backups: Vec<_> = fs::read_dir(&dir.0).unwrap().map(|f| f.unwrap().path()).filter(|p| p.file_name().unwrap().to_string_lossy().contains("before-credential-elevation-v19")).collect();
    assert_eq!(backups.len(), 1);
    let backup = Connection::open(&backups[0]).unwrap();
    assert!(backup.prepare("SELECT elevation_method FROM ssh_credentials").is_err());
    let encrypted: String = backup.query_row("SELECT password FROM ssh_credentials", [], |r| r.get(0)).unwrap();
    assert!(encrypted.starts_with("enc:v1:"));
    assert!(!encrypted.contains("fixture-secret"));
    drop(backup);
    vault.db.execute_batch("UPDATE tp_sync_context SET enabled=1").unwrap();
    for method in [json!("sudo"), json!("su"), Value::Null] {
        restored["elevationMethod"] = method.clone();
        restored = vault.save("credentials", restored, None).unwrap();
        assert_eq!(restored["elevationMethod"], method);
        let payload: Vec<u8> = vault.db.query_row("SELECT payload FROM tp_sync_journal ORDER BY id DESC LIMIT 1", [], |r| r.get(0)).unwrap();
        let journal: Value = serde_json::from_slice(&crypto::unseal(&key, &payload, crate::sync::journal::AAD).unwrap()).unwrap();
        assert_eq!(journal["after"]["elevation_method"], method);
    }
    restored["elevationMethod"] = json!("invalid");
    assert!(vault.save("credentials", restored, None).is_err());
    drop(vault);
    let _reopened = dir.open();
    let backups_after: Vec<_> = fs::read_dir(&dir.0).unwrap().map(|f| f.unwrap().file_name().to_string_lossy().into_owned()).filter(|name| name.contains("before-credential-elevation-v19")).collect();
    assert_eq!(backups_after.iter().filter(|name| !name.ends_with("-wal") && !name.ends_with("-shm")).count(), 1, "{backups_after:?}");
}
fn host(name: &str) -> Value {
    json!({"label":name,"hostname":"fixture.invalid","port":22,"username":"fixture","authentication":"password","password":"fixture-secret","connectionKind":"ssh"})
}
#[test]
fn persistent_encryption_and_group_cycle_rollback() {
    let dir = Fixture::new();
    let vault = dir.open();
    let parent = vault
        .save("groups", json!({"name":"Parent"}), None)
        .unwrap();
    let child = vault
        .save(
            "groups",
            json!({"name":"Child","parentGroupID":parent["id"]}),
            None,
        )
        .unwrap();
    let mut bad = parent.clone();
    bad["parentGroupID"] = child["id"].clone();
    assert_eq!(
        vault.save("groups", bad, None).unwrap_err().code,
        "groupCycle"
    );
    let mut h = host("中文主机");
    h["groupID"] = child["id"].clone();
    vault.save("hosts", h, None).unwrap();
    let stored: String = vault
        .db
        .query_row("SELECT password FROM hosts", [], |r| r.get(0))
        .unwrap();
    assert!(stored.starts_with("enc:v1:"));
    assert!(!stored.contains("fixture-secret"));
    drop(vault);
    let vault = dir.open();
    assert_eq!(
        vault.list("hosts").unwrap()[0]["password"],
        "fixture-secret"
    );
    vault.delete("groups", &parent["id"]).unwrap();
    assert_eq!(vault.list("groups").unwrap().len(), 0);
    assert!(vault.list("hosts").unwrap()[0]["groupID"].is_null());
}
#[test]
fn host_and_screen_profile_are_atomic() {
    let dir = Fixture::new();
    let vault = dir.open();
    assert!(vault
        .save(
            "hosts",
            host("Atomic"),
            Some(json!({"port":0,"username":"fixture"}))
        )
        .is_err());
    assert!(vault.list("hosts").unwrap().is_empty());
}
#[test]
fn encrypted_backup_wrong_password_and_cross_vault_roundtrip() {
    let a = Fixture::new();
    let b = Fixture::new();
    let va = a.open();
    va.save("hosts", host("Backup"), None).unwrap();
    let snapshot = va.snapshot().unwrap();
    assert!(snapshot["hosts"][0]["createdAt"].is_string());
    let encrypted = crypto::encrypt_backup(&snapshot, "test-password").unwrap();
    assert!(crypto::decrypt_backup(&encrypted, "incorrect").is_err());
    let vb = b.open();
    vb.import(crypto::decrypt_backup(&encrypted, "test-password").unwrap())
        .unwrap();
    assert_eq!(vb.list("hosts").unwrap()[0]["password"], "fixture-secret");
    assert_ne!(*va.key, *vb.key);
}
#[test]
fn missing_key_never_replaces_existing_key_or_vault() {
    let dir = Fixture::new();
    {
        let v = dir.open();
        v.save("hosts", host("Preserved"), None).unwrap();
    }
    fs::remove_file(dir.0.join("credential.key")).unwrap();
    assert!(matches!(Vault::open(&dir.0,None),Err(e) if e.code=="missingCredentialKey"));
    assert!(!dir.0.join("credential.key").exists());
}

#[test]
fn portable_migration_preserves_live_wal_credentials_preferences_and_backup() {
    let old = Fixture::new();
    let new = Fixture::new();
    let vault = old.open();
    vault.save("hosts", host("迁移主机"), None).unwrap();
    fs::write(
        old.0.join("windows-preferences.json"),
        r#"{"theme":"Dark"}"#,
    )
    .unwrap();
    fs::write(old.0.join("known_hosts"), "fixture key").unwrap();
    fs::write(old.0.join("ai-mcp.json"), "expired runtime endpoint").unwrap();
    let ai = Connection::open(old.0.join("ai.sqlite")).unwrap();
    ai.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES ('history');").unwrap();
    assert!(old.0.join("vault.sqlite-wal").exists());
    let key = fs::read(old.0.join("credential.key")).unwrap();
    assert_eq!(portable::prepare(&new.0, &old.0).unwrap()["migrated"], true);
    assert_eq!(
        new.open().list("hosts").unwrap()[0]["password"],
        "fixture-secret"
    );
    assert_eq!(fs::read(new.0.join("credential.key")).unwrap(), key);
    assert_eq!(
        fs::read(new.0.join("MigrationBackup/credential.key")).unwrap(),
        key
    );
    assert_eq!(
        Vault::open(&new.0.join("MigrationBackup"), None)
            .unwrap()
            .list("hosts")
            .unwrap()[0]["label"],
        "迁移主机"
    );
    assert_eq!(
        fs::read_to_string(new.0.join("known_hosts")).unwrap(),
        "fixture key"
    );
    assert_eq!(
        fs::read(new.0.join("windows-preferences.json")).unwrap(),
        fs::read(old.0.join("windows-preferences.json")).unwrap()
    );
    let copied = Connection::open(new.0.join("ai.sqlite")).unwrap();
    assert_eq!(
        copied
            .query_row("SELECT value FROM fixture", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "history"
    );
    assert!(!new.0.join("ai-mcp.json").exists());
    assert_eq!(vault.list("hosts").unwrap().len(), 1);
    vault
        .save("hosts", host("Later legacy edit"), None)
        .unwrap();
    assert_eq!(
        portable::prepare(&new.0, &old.0).unwrap()["migrated"],
        false
    );
    assert_eq!(new.open().list("hosts").unwrap().len(), 1);
}

#[test]
fn portable_migration_failure_is_retryable_and_never_creates_a_new_key() {
    let old = Fixture::new();
    let new = Fixture::new();
    drop(old.open());
    let key = fs::read(old.0.join("credential.key")).unwrap();
    fs::remove_file(old.0.join("credential.key")).unwrap();
    assert!(portable::prepare(&new.0, &old.0).is_err());
    assert!(!new.0.exists());
    fs::write(old.0.join("credential.key"), key).unwrap();
    fs::write(old.0.join("ai.sqlite"), "corrupt").unwrap();
    assert!(portable::prepare(&new.0, &old.0).is_err());
    assert!(!new.0.exists());
    fs::remove_file(old.0.join("ai.sqlite")).unwrap();
    fs::create_dir_all(&new.0).unwrap();
    portable::prepare(&new.0, &old.0).unwrap();
    assert!(new.0.join("vault.sqlite").is_file());
}

#[test]
fn duplicate_host_draft_preserves_settings_without_inserting_or_reusing_revision() {
    let dir = Fixture::new();
    let vault = dir.open();
    for kind in ["ssh", "rdp", "screenSharing"] {
        let mut source = host("原主机");
        source["connectionKind"] = json!(kind);
        let profile = (kind != "ssh").then(|| json!({"mode":if kind=="rdp" {"rdp"} else {"highPerformance"},"port":5900,"username":"remote","password":"remote-secret","audio":false}));
        let original = vault.save("hosts", source, profile).unwrap();
        let before = vault.list("hosts").unwrap().len();
        let draft = dispatch(
            &json!({"method":"vault.host.duplicateDraft","directory":dir.0,"id":original["id"]}),
        )
        .unwrap();
        let mut copy = draft["item"].clone();
        assert_ne!(copy["id"], original["id"]);
        assert!(copy.get("updatedAt").is_none());
        assert!(copy.get("createdAt").is_none());
        assert_eq!(copy["password"], original["password"]);
        assert_eq!(vault.list("hosts").unwrap().len(), before); // Cancel is read-only.
        copy["label"] = json!("副本 edited");
        let screen = draft
            .get("screenSharingProfile")
            .filter(|p| p.is_object())
            .cloned();
        let saved = vault.save("hosts", copy, screen).unwrap();
        assert_eq!(
            vault.get("hosts", &original["id"]).unwrap().unwrap(),
            original
        );
        if kind != "ssh" {
            let profile = vault.get("screenSharing", &saved["id"]).unwrap().unwrap();
            assert_eq!(profile["hostID"], saved["id"]);
            assert_eq!(profile["password"], "remote-secret");
            assert_eq!(profile["audio"], false);
        }
    }
}
