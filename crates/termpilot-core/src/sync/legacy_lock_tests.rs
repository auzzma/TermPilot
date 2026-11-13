use super::{
    control::{Head, Lock, Namespace},
    lease_tests::{Cloud, Fixture},
    model::{Action, Vector},
    store::Store,
    transport::{Backend, Objects},
    *,
};
use crate::vault::Vault;
use serde_json::{json, Value};
fn edit(vault: &Vault, id: &str) {
    let record = if id == "cloud-host" {
        "00000000-0000-4000-8000-000000000001"
    } else {
        "00000000-0000-4000-8000-000000000002"
    };
    let s = Store::new(vault).unwrap();
    s.append(
        "configuration",
        &s.writer().unwrap(),
        &Vector::new(),
        "hosts",
        record,
        Action::Patch {
            fields: serde_json::from_value(
                json!({"label":id,"hostname":"fixture.invalid","port":22,"username":"fixture","authentication":"password","connection_kind":"ssh"}),
            )
            .unwrap(),
        },
    )
    .unwrap();
}
fn sync(vault: &Vault, cloud: &mut dyn Objects) {
    let s = Store::new(vault).unwrap();
    let c = s.config().unwrap();
    let lease = control::acquire(&s, cloud, "sync").unwrap();
    runtime::exchange(
        &s,
        &mut Namespace {
            cloud,
            library: c.library,
            generation: c.generation,
            guard: Some(&lease),
        },
    )
    .unwrap();
    control::release(&s, cloud, &lease).unwrap();
}
fn install_old(vault: &Vault, cloud: &mut dyn Objects, kind: &str) -> Vec<u8> {
    let s = Store::new(vault).unwrap();
    let c = s.config().unwrap();
    let old = cloud.get(&control::name(&c.library)).unwrap();
    let mut head = old
        .as_ref()
        .map(|b| serde_json::from_slice::<Head>(b).unwrap())
        .unwrap_or_else(|| Head::new(&c));
    head.version = 2;
    head.catalog = None;
    head.maintenance = None;
    head.lock = Some(Lock {
        device: "uninstalled-device".into(),
        token: uuid::Uuid::new_v4().to_string(),
        kind: kind.into(),
        expires_at: None,
        timeout_minutes: None,
    });
    let bytes = head.signed(&c).unwrap();
    assert!(cloud
        .compare_exchange(&control::name(&c.library), old.as_deref(), &bytes)
        .unwrap());
    bytes
}
fn request(s: &Store<'_>, cloud: &mut dyn Objects) -> Value {
    let p = legacy_lock::inspect(s, cloud).unwrap();
    json!({"confirmed":true,"otherDevicesStopped":true,"expectedHead":p["expectedHead"]})
}
#[test]
fn explicit_recovery_backs_up_preserves_data_and_merges_offline_edits() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let mut cloud = Cloud::new();
    edit(&a, "cloud-host");
    sync(&a, &mut cloud);
    edit(&b, "offline-host");
    let previous = install_old(&a, &mut cloud, "sync");
    let original = cloud.values.lock().unwrap().clone();
    let s = Store::new(&b).unwrap();
    let req = request(&s, &mut cloud);
    let lease = legacy_lock::recover(&b, &s, &mut cloud, &req).unwrap();
    assert!(lease.head().unwrap().lock.unwrap().expires_at.is_some());
    let backup = s.get::<Value>("lockRecoveryBackup").unwrap().unwrap();
    let path = std::path::Path::new(backup["directory"].as_str().unwrap());
    let stored: Value = s
        .decode(&std::fs::read(path.join("control.encrypted")).unwrap())
        .unwrap();
    assert_eq!(stored["control"], serde_json::to_value(&previous).unwrap());
    assert!(path.join("vault.sqlite").is_file());
    for (name, bytes) in original {
        if name != control::name(&f.library) {
            assert_eq!(cloud.get(&name).unwrap(), Some(bytes.clone()));
            if !name.contains("-catalog-") {
                assert_eq!(std::fs::read(path.join(name)).unwrap(), bytes);
            }
        }
    }
    runtime::exchange(
        &s,
        &mut Namespace {
            cloud: &mut cloud,
            library: f.library.clone(),
            generation: String::new(),
            guard: Some(&lease),
        },
    )
    .unwrap();
    control::release(&s, &mut cloud, &lease).unwrap();
    let state = s.state("configuration").unwrap();
    assert!(state
        .records
        .contains_key("hosts/00000000-0000-4000-8000-000000000001"));
    assert!(state
        .records
        .contains_key("hosts/00000000-0000-4000-8000-000000000002"));
    assert_eq!(
        control::read(&mut cloud, &f.library)
            .unwrap()
            .unwrap()
            .0
            .version,
        4
    );
    sync(&a, &mut cloud);
    assert!(Store::new(&a)
        .unwrap()
        .state("configuration")
        .unwrap()
        .records
        .contains_key("hosts/00000000-0000-4000-8000-000000000002"));
}
#[test]
fn confirmation_stale_preview_new_leases_and_key_migration_are_rejected() {
    let f = Fixture::new();
    let a = f.peer("a");
    let s = Store::new(&a).unwrap();
    let mut cloud = Cloud::new();
    let first = install_old(&a, &mut cloud, "sync");
    let req = request(&s, &mut cloud);
    assert_eq!(
        legacy_lock::recover(&a, &s, &mut cloud, &json!({}))
            .err()
            .unwrap()
            .code,
        "syncConfirmation"
    );
    let second = install_old(&a, &mut cloud, "sync");
    assert_ne!(first, second);
    assert_eq!(
        legacy_lock::recover(&a, &s, &mut cloud, &req)
            .err()
            .unwrap()
            .code,
        "syncRecoveryChanged"
    );
    assert_eq!(cloud.get(&control::name(&f.library)).unwrap(), Some(second));
    install_old(&a, &mut cloud, "rekey");
    assert_eq!(
        legacy_lock::inspect(&s, &mut cloud).unwrap_err().code,
        "syncRecoveryMigration"
    );
    install_old(&a, &mut cloud, "sync");
    let req = request(&s, &mut cloud);
    let lease = legacy_lock::recover(&a, &s, &mut cloud, &req).unwrap();
    assert_eq!(
        legacy_lock::inspect(&s, &mut cloud).unwrap_err().code,
        "syncRecoveryUnavailable"
    );
    control::release(&s, &mut cloud, &lease).unwrap();
    assert!(legacy_lock::inspect(&s, &mut cloud).is_err());
}
#[test]
fn wrong_key_corrupt_objects_and_missing_chunks_never_replace_the_control() {
    for failure in ["key", "corrupt", "missing"] {
        let f = Fixture::new();
        let a = f.peer("a");
        let mut cloud = Cloud::new();
        edit(&a, "cloud-host");
        sync(&a, &mut cloud);
        let previous = install_old(&a, &mut cloud, "sync");
        let s = Store::new(&a).unwrap();
        let req = request(&s, &mut cloud);
        if failure == "key" {
            let mut c = s.config().unwrap();
            c.scope_keys.insert("configuration".into(), vec![9; 32]);
            s.put("config", &c).unwrap();
        } else {
            let chunk = cloud
                .list()
                .unwrap()
                .into_iter()
                .find(|n| n.contains("-chunk-"))
                .unwrap();
            if failure == "missing" {
                cloud.values.lock().unwrap().remove(&chunk);
            } else {
                cloud
                    .values
                    .lock()
                    .unwrap()
                    .insert(chunk, b"corrupt".to_vec());
            }
        }
        assert!(
            legacy_lock::recover(&a, &s, &mut cloud, &req).is_err(),
            "{failure}"
        );
        assert_eq!(
            cloud.get(&control::name(&f.library)).unwrap(),
            Some(previous)
        );
    }
}
struct Racing {
    cloud: Cloud,
    fail_after_commit: bool,
    competitor: Option<Vec<u8>>,
}
impl Objects for Racing {
    fn list(&mut self) -> Result<Vec<String>> {
        self.cloud.list()
    }
    fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
        self.cloud.get(n)
    }
    fn put(&mut self, n: &str, b: &[u8]) -> Result<()> {
        self.cloud.put(n, b)
    }
    fn server_time(&self) -> Option<i64> {
        self.cloud.server_time()
    }
    fn compare_exchange(&mut self, n: &str, e: Option<&[u8]>, b: &[u8]) -> Result<bool> {
        if let Some(other) = self.competitor.take() {
            self.cloud.compare_exchange(n, e, &other)?;
            return Ok(false);
        }
        let committed = self.cloud.compare_exchange(n, e, b)?;
        if self.fail_after_commit && committed {
            self.fail_after_commit = false;
            return Err(err("syncNetwork", "fixture lost response"));
        }
        Ok(committed)
    }
}
#[test]
fn competing_control_update_wins_and_lost_success_reply_is_recovered() {
    for lost in [false, true] {
        let f = Fixture::new();
        let a = f.peer("a");
        let s = Store::new(&a).unwrap();
        let mut cloud = Cloud::new();
        let old = install_old(&a, &mut cloud, "sync");
        let req = request(&s, &mut cloud);
        let mut other: Head = serde_json::from_slice(&old).unwrap();
        other.lock.as_mut().unwrap().token = "competitor".into();
        let other = other.signed(&s.config().unwrap()).unwrap();
        let mut race = Racing {
            cloud,
            fail_after_commit: lost,
            competitor: (!lost).then_some(other.clone()),
        };
        let result = legacy_lock::recover(&a, &s, &mut race, &req);
        if lost {
            let lease = result.unwrap();
            control::release(&s, &mut race, &lease).unwrap();
            assert_eq!(
                control::read(&mut race, &f.library)
                    .unwrap()
                    .unwrap()
                    .0
                    .version,
                4
            );
        } else {
            assert_eq!(result.err().unwrap().code, "syncRecoveryChanged");
            assert_eq!(race.get(&control::name(&f.library)).unwrap(), Some(other));
        }
    }
}
#[test]
fn public_recovery_command_runs_sync_and_defers_automatic_history_deletion() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let sa = Store::new(&a).unwrap();
    let config = sa.config().unwrap();
    let mut cloud = Backend::new(config.provider.clone(), &config.library).unwrap();
    edit(&a, "cloud-host");
    sync(&a, &mut cloud);
    install_old(&a, &mut cloud, "sync");
    edit(&b, "offline-host");
    let path = b.directory.to_string_lossy().to_string();
    let preview = dispatch(
        &json!({"method":"sync.lock.inspect","directory":path}),
        None,
    )
    .unwrap();
    let result=dispatch(&json!({"method":"sync.lock.recover","directory":path,"confirmed":true,"otherDevicesStopped":true,"expectedHead":preview["expectedHead"]}),None).unwrap();
    assert_eq!(result["pending"], 0);
    assert_eq!(result["lockRecoveryBackup"]["phase"], "recovered");
    assert_eq!(result["maintenance"]["deleted"], 0);
    assert!(b
        .list("hosts")
        .unwrap()
        .iter()
        .any(|v| v["label"] == "cloud-host"));
}
