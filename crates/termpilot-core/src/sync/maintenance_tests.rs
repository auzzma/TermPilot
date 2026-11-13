use super::{
    lease_tests::{Cloud, Fixture},
    model::{Action, Vector},
    store::Store,
    transport::Objects,
    *,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
fn edit(vault: &crate::vault::Vault, writer: &str, id: &str, fields: Value) {
    let s = Store::new(vault).unwrap();
    let basis = s.state("configuration").unwrap().frontier;
    s.append(
        "configuration",
        writer,
        &basis,
        "hosts",
        id,
        Action::Patch {
            fields: serde_json::from_value(fields).unwrap(),
        },
    )
    .unwrap();
}
fn sync(vault: &crate::vault::Vault, cloud: &mut dyn Objects) {
    let s = Store::new(vault).unwrap();
    rekey::adopt_matching(&s, cloud).unwrap();
    let c = s.config().unwrap();
    let lease = control::acquire(&s, cloud, "sync").unwrap();
    {
        let mut ns = control::Namespace {
            cloud,
            library: c.library,
            generation: c.generation,
            guard: Some(&lease),
        };
        runtime::exchange(&s, &mut ns).unwrap();
    }
    control::release(&s, cloud, &lease).unwrap();
}
fn policy() -> maintenance::Policy {
    maintenance::Policy {
        interval: 0,
        grace: 100,
        snapshots: 30 * 86400,
        minimum: 0,
        batch: 10_000,
    }
}
fn compact(vault: &crate::vault::Vault, cloud: &mut dyn Objects) -> bool {
    let s = Store::new(vault).unwrap();
    let lease = control::acquire(&s, cloud, "sync").unwrap();
    let changed = maintenance::run(&s, cloud, &lease, policy()).unwrap();
    if lease.active().unwrap() {
        control::release(&s, cloud, &lease).unwrap();
    }
    changed
}
#[test]
fn compaction_preserves_conflicts_deleted_recovery_and_offline_edits_after_physical_gc() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let c = f.peer("offline");
    let mut cloud = Cloud::new();
    let host = uuid::Uuid::new_v4().to_string();
    edit(
        &a,
        "a",
        &host,
        json!({"label":"Shared host","hostname":"host.invalid","port":22,"username":"fixture"}),
    );
    sync(&a, &mut cloud);
    sync(&b, &mut cloud);
    sync(&c, &mut cloud);
    edit(&a, "a", &host, json!({"hostname":"a.invalid"}));
    edit(&b, "b", &host, json!({"hostname":"b.invalid"}));
    edit(&c, "offline", &host, json!({"port":2222}));
    let removed = uuid::Uuid::new_v4().to_string();
    edit(
        &a,
        "a",
        &removed,
        json!({"label":"Deleted host","hostname":"deleted.invalid"}),
    );
    sync(&a, &mut cloud);
    sync(&b, &mut cloud);
    sync(&a, &mut cloud);
    let sa = Store::new(&a).unwrap();
    let before = sa.state("configuration").unwrap();
    sa.append(
        "configuration",
        "a",
        &before.frontier,
        "hosts",
        &removed,
        Action::Delete {
            recovery: json!({"label":"Deleted host","hostname":"deleted.invalid"}),
            retention_days: Some(30),
            deleted_at: "2026-11-13T00:00:00Z".into(),
        },
    )
    .unwrap();
    sync(&a, &mut cloud);
    let expected = sa.state("configuration").unwrap();
    assert!(expected.records[&format!("hosts/{host}")].conflicted());
    let old: Vec<_> = cloud
        .list()
        .unwrap()
        .into_iter()
        .filter(|n| !n.contains("-control."))
        .collect();
    assert!(compact(&a, &mut cloud));
    for name in &old {
        assert!(cloud.get(name).unwrap().is_some());
    }
    assert!(!sa.config().unwrap().generation.is_empty());
    cloud.advance(101);
    compact(&a, &mut cloud);
    for name in old {
        assert!(
            cloud.get(&name).unwrap().is_none(),
            "old generation object retained: {name}"
        );
    }
    // Offline peer adopts the checkpoint without replaying deleted batches.
    sync(&c, &mut cloud);
    sync(&a, &mut cloud);
    let after = sa.state("configuration").unwrap();
    assert_eq!(
        after.records[&format!("hosts/{host}")].value()["port"],
        2222
    );
    assert!(after.records[&format!("hosts/{host}")].conflicted());
    assert!(after.records[&format!("hosts/{removed}")].deleted());
    assert!(after
        .recycle
        .values()
        .any(|r| r.record == removed && r.recovery.is_some()));
    let fresh = f.peer("fresh");
    sync(&fresh, &mut cloud);
    assert_eq!(
        Store::new(&fresh).unwrap().state("configuration").unwrap(),
        after
    );
}
#[test]
fn cleanup_checks_active_chunks_and_never_deletes_control_or_other_libraries() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut cloud = Cloud::new();
    edit(&a, "a", "one", json!({"label":"One"}));
    sync(&a, &mut cloud);
    compact(&a, &mut cloud);
    let s = Store::new(&a).unwrap();
    let head = control::read(&mut cloud, &f.library).unwrap().unwrap().0;
    let active = cloud
        .list()
        .unwrap()
        .into_iter()
        .find(|n| n.contains(&head.generation) && n.contains("-chunk-"))
        .unwrap();
    let saved = cloud.values.lock().unwrap().remove(&active).unwrap();
    let before = cloud.list().unwrap();
    cloud.advance(101);
    let lease = control::acquire(&s, &mut cloud, "sync").unwrap();
    assert!(maintenance::run(&s, &mut cloud, &lease, policy()).is_err());
    control::release(&s, &mut cloud, &lease).unwrap();
    assert_eq!(before, cloud.list().unwrap());
    cloud.values.lock().unwrap().insert(active, saved);
    let foreign = "tp1-unrelated-chunk-configuration-not-a-real-hash.tps";
    cloud
        .values
        .lock()
        .unwrap()
        .insert(foreign.into(), b"keep".to_vec());
    compact(&a, &mut cloud);
    assert!(cloud.get(foreign).unwrap().is_some());
    assert!(cloud.get(&control::name(&f.library)).unwrap().is_some());
}
struct Failing {
    cloud: Cloud,
    writes: usize,
    fail: usize,
    denied: bool,
}
impl Objects for Failing {
    fn list(&mut self) -> Result<Vec<String>> {
        self.cloud.list()
    }
    fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
        self.cloud.get(n)
    }
    fn put(&mut self, n: &str, b: &[u8]) -> Result<()> {
        self.writes += 1;
        if self.writes == self.fail {
            return Err(err("syncNetwork", "fixture"));
        }
        self.cloud.put(n, b)
    }
    fn server_time(&self) -> Option<i64> {
        self.cloud.server_time()
    }
    fn compare_exchange(&mut self, n: &str, e: Option<&[u8]>, b: &[u8]) -> Result<bool> {
        self.cloud.compare_exchange(n, e, b)
    }
    fn remove_retired(&mut self, n: &str) -> Result<()> {
        if self.denied {
            return Err(err("syncCleanupPermission", "fixture"));
        }
        self.cloud.remove_retired(n)
    }
}
#[test]
fn interrupted_staging_is_not_published_and_can_be_collected_later() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut cloud = Cloud::new();
    edit(&a, "a", "one", json!({"label":"One"}));
    sync(&a, &mut cloud);
    let s = Store::new(&a).unwrap();
    let lease = control::acquire(&s, &mut cloud, "sync").unwrap();
    let mut failed = Failing {
        cloud,
        writes: 0,
        fail: 2,
        denied: false,
    };
    assert!(maintenance::run(&s, &mut failed, &lease, policy()).is_err());
    assert!(s.config().unwrap().generation.is_empty());
    let head = lease.head().unwrap();
    let abandoned = head.maintenance.unwrap().staging[0].generation.clone();
    assert!(head.generation.is_empty());
    control::release(&s, &mut failed, &lease).unwrap();
    assert!(failed
        .list()
        .unwrap()
        .iter()
        .any(|n| n.contains(&abandoned)));
    failed.fail = usize::MAX;
    failed.cloud.advance(101);
    sync(&a, &mut failed);
    compact(&a, &mut failed);
    assert!(!failed
        .list()
        .unwrap()
        .iter()
        .any(|n| n.contains(&abandoned)));
    let fresh = f.peer("fresh");
    sync(&fresh, &mut failed);
    assert_eq!(
        Store::new(&fresh)
            .unwrap()
            .state("configuration")
            .unwrap()
            .records["hosts/one"]
            .value()["label"],
        "One"
    );
}
#[test]
fn deletion_failure_and_batch_limits_keep_history_for_retry() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut cloud = Cloud::new();
    edit(&a, "a", "one", json!({"label":"One"}));
    sync(&a, &mut cloud);
    compact(&a, &mut cloud);
    cloud.advance(101);
    let s = Store::new(&a).unwrap();
    let mut denied = Failing {
        cloud,
        writes: 0,
        fail: usize::MAX,
        denied: true,
    };
    let lease = control::acquire(&s, &mut denied, "sync").unwrap();
    assert_eq!(
        maintenance::run(&s, &mut denied, &lease, policy())
            .unwrap_err()
            .code,
        "syncCleanupPermission"
    );
    control::release(&s, &mut denied, &lease).unwrap();
    let b = f.peer("b");
    sync(&b, &mut denied);
    assert!(!Store::new(&b)
        .unwrap()
        .state("configuration")
        .unwrap()
        .records
        .is_empty());
    denied.denied = false;
    let lease = control::acquire(&s, &mut denied, "sync").unwrap();
    let mut p = policy();
    p.batch = 1;
    p.minimum = usize::MAX;
    maintenance::run(&s, &mut denied, &lease, p).unwrap();
    assert_eq!(
        s.get::<Value>("maintenanceStatus").unwrap().unwrap()["deleted"],
        1
    );
    assert!(!lease
        .head()
        .unwrap()
        .maintenance
        .unwrap()
        .retired
        .is_empty());
    control::release(&s, &mut denied, &lease).unwrap();
    compact(&a, &mut denied);
}
#[test]
fn disabled_scope_objects_are_copied_without_losing_their_encrypted_data() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut cloud = Cloud::new();
    let s = Store::new(&a).unwrap();
    let mut c = s.config().unwrap();
    c.scopes.push("credentials".into());
    c.scope_keys.insert("credentials".into(), vec![8; 32]);
    s.put("config", &c).unwrap();
    edit(&a, "a", "one", json!({"label":"One"}));
    s.append(
        "credentials",
        "a",
        &Vector::new(),
        "hosts",
        "one",
        Action::Patch {
            fields: BTreeMap::from([("password".into(), json!("fixture-secret"))]),
        },
    )
    .unwrap();
    sync(&a, &mut cloud);
    let original = cloud
        .list()
        .unwrap()
        .into_iter()
        .filter(|n| n.contains("-credentials-"))
        .map(|n| {
            let b = cloud.get(&n).unwrap().unwrap();
            (n, b)
        })
        .collect::<Vec<_>>();
    c.scopes.retain(|s| s != "credentials");
    c.scope_keys.remove("credentials");
    s.put("config", &c).unwrap();
    compact(&a, &mut cloud);
    cloud.advance(101);
    compact(&a, &mut cloud);
    let current = s.config().unwrap();
    for (name, bytes) in original {
        let suffix = name.strip_prefix(&format!("tp1-{}-", f.library)).unwrap();
        let next = format!("tp1-{}-g-{}-{suffix}", f.library, current.generation);
        assert_eq!(cloud.get(&next).unwrap().unwrap(), bytes);
    }
}

#[test]
fn only_old_snapshots_outside_retention_are_retired_and_latest_restore_still_works() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut cloud = Cloud::new();
    let id = uuid::Uuid::new_v4().to_string();
    edit(
        &a,
        "a",
        &id,
        json!({"label":"Recoverable host","hostname":"fixture.invalid","port":22,"username":"fixture","authentication":"password","connectionKind":"ssh"}),
    );
    sync(&a, &mut cloud);
    let s = Store::new(&a).unwrap();
    let c = s.config().unwrap();
    let lease = control::acquire(&s, &mut cloud, "sync").unwrap();
    for i in 0..4 {
        let at = chrono::DateTime::from_timestamp(cloud.server_time().unwrap() + i, 0)
            .unwrap()
            .to_rfc3339();
        let doc = json!({"id":format!("historical-{i}"),"at":at,"scopes":["configuration"],"state":s.published_state("configuration").unwrap()});
        let (_, objects) = runtime::encode_document(&c, "configuration", "snapshot", &doc).unwrap();
        let mut ns = control::Namespace {
            cloud: &mut cloud,
            library: c.library.clone(),
            generation: c.generation.clone(),
            guard: Some(&lease),
        };
        for (n, b, _, _) in objects {
            ns.put(&n, &b).unwrap();
        }
    }
    control::release(&s, &mut cloud, &lease).unwrap();
    cloud.advance(31 * 86400);
    sync(&a, &mut cloud);
    compact(&a, &mut cloud);
    cloud.advance(101);
    let lease = control::acquire(&s, &mut cloud, "sync").unwrap();
    let mut cleanup = policy();
    cleanup.minimum = usize::MAX;
    maintenance::run(&s, &mut cloud, &lease, cleanup).unwrap();
    control::release(&s, &mut cloud, &lease).unwrap();
    let fresh = f.peer("fresh");
    sync(&fresh, &mut cloud);
    let fs = Store::new(&fresh).unwrap();
    let snapshots = fs.get::<Vec<Value>>("snapshots").unwrap().unwrap();
    assert!(snapshots.iter().any(|s| s["id"] == "historical-3"));
    assert!(!snapshots.iter().any(|s| s["id"] == "historical-0"));
    let snapshot = snapshots
        .iter()
        .find(|s| s["id"] != "historical-3")
        .unwrap();
    let preview = super::dispatch(
        &json!({"method":"sync.snapshot.preview","directory":fresh.directory,"id":snapshot["id"]}),
        None,
    )
    .unwrap();
    assert_eq!(preview["copies"], 1);
    super::dispatch(&json!({"method":"sync.snapshot.restore","directory":fresh.directory,"id":snapshot["id"],"confirmed":true,"actionId":uuid::Uuid::new_v4().to_string()}),None).unwrap();
    assert!(fresh
        .list("hosts")
        .unwrap()
        .iter()
        .any(|h| h["label"] == "Recoverable host" && h["id"] != id));
}
#[test]
fn stale_compactor_cannot_publish_after_another_device_takes_the_lease() {
    struct Steal<'a> {
        cloud: Cloud,
        other: &'a Store<'a>,
        stolen: Option<lease::Lease>,
    }
    impl Objects for Steal<'_> {
        fn list(&mut self) -> Result<Vec<String>> {
            self.cloud.list()
        }
        fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
            self.cloud.get(n)
        }
        fn put(&mut self, n: &str, b: &[u8]) -> Result<()> {
            self.cloud.put(n, b)?;
            if self.stolen.is_none() && n.contains("-g-") {
                self.cloud.advance(61);
                self.stolen = Some(control::acquire(self.other, &mut self.cloud, "sync")?);
            }
            Ok(())
        }
        fn server_time(&self) -> Option<i64> {
            self.cloud.server_time()
        }
        fn compare_exchange(&mut self, n: &str, e: Option<&[u8]>, b: &[u8]) -> Result<bool> {
            self.cloud.compare_exchange(n, e, b)
        }
    }
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let mut cloud = Cloud::new();
    edit(&a, "a", "one", json!({"label":"One"}));
    sync(&a, &mut cloud);
    sync(&b, &mut cloud);
    let sa = Store::new(&a).unwrap();
    let sb = Store::new(&b).unwrap();
    let lease = control::acquire(&sa, &mut cloud, "sync").unwrap();
    let mut race = Steal {
        cloud,
        other: &sb,
        stolen: None,
    };
    assert_eq!(
        maintenance::run(&sa, &mut race, &lease, policy())
            .unwrap_err()
            .code,
        "syncLeaseLost"
    );
    assert!(control::read(&mut race, &f.library)
        .unwrap()
        .unwrap()
        .0
        .generation
        .is_empty());
    let winner = race.stolen.take().unwrap();
    control::release(&sb, &mut race, &winner).unwrap();
    sync(&b, &mut race);
    assert_eq!(
        sb.state("configuration").unwrap().records["hosts/one"].value()["label"],
        "One"
    );
}
