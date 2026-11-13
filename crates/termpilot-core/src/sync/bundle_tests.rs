use super::super::{
    lease_tests::{Cloud, Fixture},
    model::Action,
};
use super::*;
fn edit(v: &Vault, writer: &str, id: &str, fields: Value) {
    let s = Store::new(v).unwrap();
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
fn sync(v: &Vault, c: &mut dyn Objects) -> Result<()> {
    let s = Store::new(v)?;
    let l = control::acquire(&s, c, "sync")?;
    let result = run(v, &s, c, &l);
    let released = control::release(&s, c, &l);
    result.and(released)
}
fn history(v: &Vault) -> History {
    Store::new(v)
        .unwrap()
        .get("bundleHistory")
        .unwrap()
        .unwrap()
}

fn previous_directory_layout(v: &Vault, cloud: &mut Cloud) -> History {
    let store = Store::new(v).unwrap();
    let cfg = store.config().unwrap();
    let mut h = history(v);
    for (kind, reference) in h
        .current
        .iter_mut()
        .map(|r| ("current", r))
        .chain(h.versions.iter_mut().map(|r| ("history", r)))
    {
        let bytes = cloud.get(&reference.path).unwrap().unwrap();
        cloud.values.lock().unwrap().remove(&reference.path);
        reference.path = format!("tp1-{}-{kind}/full-{}.tps", cfg.library, reference.digest);
        cloud.put(&reference.path, &bytes).unwrap();
    }
    let lease = control::acquire(&store, cloud, "fixture").unwrap();
    lease.publish_bundles(cloud, h.clone()).unwrap();
    control::release(&store, cloud, &lease).unwrap();
    catalog(&store, &h).unwrap();
    h
}

#[test]
fn old_directory_layout_moves_exact_versions_and_preserves_other_libraries() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut cloud = Cloud::new();
    edit(&a, "a", "host", json!({"label":"one"}));
    sync(&a, &mut cloud).unwrap();
    edit(&a, "a", "host", json!({"label":"two"}));
    sync(&a, &mut cloud).unwrap();
    let old = previous_directory_layout(&a, &mut cloud);
    let foreign = format!(
        "current/full-{}-{}.tps",
        uuid::Uuid::new_v4(),
        hash(b"keep")
    );
    cloud.put(&foreign, b"keep").unwrap();
    sync(&a, &mut cloud).unwrap();
    let new = history(&a);
    assert_eq!(new.versions.len(), old.versions.len());
    for (before, after) in old
        .current
        .iter()
        .chain(&old.versions)
        .zip(new.current.iter().chain(&new.versions))
    {
        assert_eq!(before.id, after.id);
        assert_eq!(before.digest, after.digest);
        assert_eq!(before.revision, after.revision);
        assert_ne!(before.path, after.path);
        assert_eq!(
            cloud.get(&before.path).unwrap(),
            cloud.get(&after.path).unwrap()
        );
    }
    assert!(new.current.as_ref().unwrap().path.starts_with("current/"));
    assert!(new.versions.iter().all(|v| v.path.starts_with("history/")));
    cloud.advance(GRACE + 1);
    sync(&a, &mut cloud).unwrap();
    for before in old.current.iter().chain(&old.versions) {
        assert!(cloud.get(&before.path).unwrap().is_none());
    }
    assert_eq!(cloud.get(&foreign).unwrap().unwrap(), b"keep");
}

#[test]
fn interrupted_directory_move_keeps_live_references_until_all_copies_verify() {
    struct Fault(Cloud, bool);
    impl Objects for Fault {
        fn list(&mut self) -> Result<Vec<String>> {
            self.0.list()
        }
        fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
            self.0.get(n)
        }
        fn put(&mut self, n: &str, b: &[u8]) -> Result<()> {
            if self.1 && n.starts_with("history/") {
                self.1 = false;
                return Err(err("fixture", "copy interrupted"));
            }
            self.0.put(n, b)
        }
        fn server_time(&self) -> Option<i64> {
            self.0.server_time()
        }
        fn compare_exchange(&mut self, n: &str, e: Option<&[u8]>, b: &[u8]) -> Result<bool> {
            self.0.compare_exchange(n, e, b)
        }
        fn remove_retired(&mut self, n: &str) -> Result<()> {
            self.0.remove_retired(n)
        }
    }
    let f = Fixture::new();
    let a = f.peer("a");
    let mut cloud = Cloud::new();
    edit(&a, "a", "host", json!({"label":"one"}));
    sync(&a, &mut cloud).unwrap();
    edit(&a, "a", "host", json!({"label":"two"}));
    sync(&a, &mut cloud).unwrap();
    let old = previous_directory_layout(&a, &mut cloud);
    let mut fault = Fault(cloud, true);
    assert!(sync(&a, &mut fault).is_err());
    let (head, _) = control::read(&mut fault, &f.library).unwrap().unwrap();
    let h = head.bundles.unwrap();
    assert_eq!(h.current, old.current);
    assert_eq!(h.versions, old.versions);
    for v in old.current.iter().chain(&old.versions) {
        assert!(fault.get(&v.path).unwrap().is_some());
    }
    sync(&a, &mut fault).unwrap();
    assert!(history(&a).current.unwrap().path.starts_with("current/"));
}
#[test]
fn one_file_contains_complete_scopes_and_noop_does_not_create_history() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let mut c = Cloud::new();
    edit(
        &a,
        "a",
        "host",
        json!({"label":"first","hostname":"fixture.invalid"}),
    );
    sync(&a, &mut c).unwrap();
    let h = history(&a);
    assert_eq!(h.versions.len(), 0);
    let files = c.list().unwrap();
    assert_eq!(files.len(), 2, "one control plus one whole package");
    let v = h.current.unwrap();
    assert!(v.path.starts_with("current/full-"));
    let bytes = c.get(&v.path).unwrap().unwrap();
    let p = decode(&Store::new(&a).unwrap().config().unwrap(), &bytes).unwrap();
    assert_eq!(p.scopes.len(), 1);
    assert_eq!(
        scope_state(
            &Store::new(&a).unwrap().config().unwrap(),
            "configuration",
            &p.scopes["configuration"]
        )
        .unwrap()
        .records
        .len(),
        1
    );
    sync(&a, &mut c).unwrap();
    assert_eq!(history(&a).current.unwrap(), v);
    sync(&b, &mut c).unwrap();
    assert_eq!(history(&b).current.unwrap(), v);
    assert_eq!(
        Store::new(&a).unwrap().state("configuration").unwrap(),
        Store::new(&b).unwrap().state("configuration").unwrap()
    );
}
#[test]
fn bounded_history_survives_gc_with_offline_edits_and_each_version_is_self_contained() {
    let f = Fixture::new();
    let a = f.peer("a");
    let offline = f.peer("offline");
    let mut c = Cloud::new();
    edit(&a, "a", "host", json!({"label":"first","port":22}));
    sync(&a, &mut c).unwrap();
    sync(&offline, &mut c).unwrap();
    edit(&offline, "offline", "host", json!({"port":2222}));
    let s = Store::new(&a).unwrap();
    s.put("pendingHistoryKeep", &1u32).unwrap();
    for n in 0..4 {
        edit(&a, "a", "host", json!({"label":format!("revision-{n}")}));
        sync(&a, &mut c).unwrap();
    }
    let h = history(&a);
    assert_eq!(h.versions.len(), 1);
    assert_eq!(h.keep, 1);
    assert!(h
        .versions
        .iter()
        .all(|v| v.path.starts_with("history/full-")));
    for v in h.current.iter().chain(&h.versions) {
        let bytes = c.get(&v.path).unwrap().unwrap();
        let p = decode(&s.config().unwrap(), &bytes).unwrap();
        assert_eq!(
            scope_state(
                &s.config().unwrap(),
                "configuration",
                &p.scopes["configuration"]
            )
            .unwrap()
            .records
            .len(),
            1
        );
    }
    c.advance(GRACE + 1);
    sync(&a, &mut c).unwrap();
    assert!(history(&a).retired.is_empty());
    sync(&offline, &mut c).unwrap();
    sync(&a, &mut c).unwrap();
    let value = s.state("configuration").unwrap().records["hosts/host"].value();
    assert_eq!(value["port"], 2222);
    assert_eq!(value["label"], "revision-3");
}
#[test]
fn missing_current_is_repaired_only_from_verified_original_ciphertext() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let mut c = Cloud::new();
    edit(&a, "a", "host", json!({"label":"first"}));
    sync(&a, &mut c).unwrap();
    let v = history(&a).current.unwrap();
    let original = c.values.lock().unwrap().remove(&v.path).unwrap();
    assert_eq!(sync(&b, &mut c).unwrap_err().code, "syncMissing");
    sync(&a, &mut c).unwrap();
    assert_eq!(c.get(&v.path).unwrap().unwrap(), original);
    assert_eq!(history(&a).current.unwrap(), v);
    c.values
        .lock()
        .unwrap()
        .insert(v.path.clone(), vec![1, 2, 3]);
    assert!(sync(&a, &mut c).is_err());
}
#[test]
fn failed_publication_keeps_local_operations_pending() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut c = Cloud::new();
    edit(&a, "a", "host", json!({"label":"one"}));
    sync(&a, &mut c).unwrap();
    edit(&a, "a", "host", json!({"label":"two"}));
    let s = Store::new(&a).unwrap();
    let l = control::acquire(&s, &mut c, "sync").unwrap();
    c.advance(61);
    assert_eq!(run(&a, &s, &mut c, &l).unwrap_err().code, "syncLeaseLost");
    let pending: i64 =
        s.db.query_row(
            "SELECT count(*) FROM tp_sync_operations WHERE published=0",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(pending > 0);
}
#[test]
fn corruption_and_wrong_key_cannot_restore_a_package() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut c = Cloud::new();
    sync(&a, &mut c).unwrap();
    let v = history(&a).current.unwrap();
    let mut b = c.get(&v.path).unwrap().unwrap();
    let mut cfg = Store::new(&a).unwrap().config().unwrap();
    cfg.scope_keys.insert("configuration".into(), vec![9; 32]);
    assert!(decode(&cfg, &b).is_err());
    cfg.scope_keys.insert("configuration".into(), vec![7; 32]);
    let n = b.len() - 1;
    b[n] ^= 1;
    assert!(decode(&cfg, &b).is_err());
}
#[test]
fn repairs_legacy_missing_batch_and_missing_catalog_reference_before_migration() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut c = Cloud::new();
    let s = Store::new(&a).unwrap();
    edit(&a, "a", "host", json!({"label":"recoverable"}));
    let lease = control::acquire(&s, &mut c, "sync").unwrap();
    let cfg = s.config().unwrap();
    {
        let mut ns = Namespace {
            cloud: &mut c,
            library: cfg.library.clone(),
            generation: cfg.generation.clone(),
            guard: Some(&lease),
        };
        runtime::exchange(&s, &mut ns).unwrap();
    }
    control::release(&s, &mut c, &lease).unwrap();
    let (mut head, old) = control::read(&mut c, &cfg.library).unwrap().unwrap();
    let mut names = super::super::lease::catalog_names(&mut c, &head).unwrap();
    let missing = names
        .iter()
        .find(|n| n.contains("-batch-"))
        .unwrap()
        .clone();
    let original = c.values.lock().unwrap().remove(&missing).unwrap();
    names.retain(|n| n != &missing);
    head.catalog =
        Some(super::super::lease::catalog_build(&mut c, &cfg.library, "", names).unwrap());
    c.compare_exchange(
        &control::name(&cfg.library),
        Some(&old),
        &head.signed(&cfg).unwrap(),
    )
    .unwrap();
    let lease = control::acquire(&s, &mut c, "repair").unwrap();
    assert_eq!(repair(&a, &s, &mut c, &lease).unwrap(), 1);
    assert_eq!(c.get(&missing).unwrap().unwrap(), original);
    assert!(lease.names(&mut c).unwrap().contains(&missing));
    control::release(&s, &mut c, &lease).unwrap();
    sync(&a, &mut c).unwrap();
    assert!(history(&a).current.is_some());
    let legacy = history(&a).legacy_objects;
    assert!(!legacy.is_empty());
    let unknown = format!("tp1-{}-unrecognized.tps", cfg.library);
    c.put(&unknown, b"keep").unwrap();
    assert!(c.get(&missing).unwrap().is_some());
    c.advance(GRACE + 1);
    sync(&a, &mut c).unwrap();
    for path in legacy {
        assert!(c.get(&path).unwrap().is_none());
    }
    assert_eq!(c.get(&unknown).unwrap().unwrap(), b"keep");
    let b = f.peer("b");
    sync(&b, &mut c).unwrap();
    assert_eq!(
        s.state("configuration").unwrap(),
        Store::new(&b).unwrap().state("configuration").unwrap()
    );
}

#[test]
fn one_file_import_works_without_any_cloud_objects_and_wrong_key_is_atomic() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let mut c = Cloud::new();
    let s = Store::new(&a).unwrap();
    let mut cfg = s.config().unwrap();
    cfg.scope_keys = runtime::derive_keys("independent-file-fixture", &cfg.library).unwrap();
    s.put("config", &cfg).unwrap();
    edit(
        &a,
        "a",
        "host",
        json!({"label":"Offline restore","hostname":"fixture.invalid","port":22,"username":"fixture","authentication":"password","connection_kind":"ssh","group_id":"","sort_order":0}),
    );
    sync(&a, &mut c).unwrap();
    let v = history(&a).current.unwrap();
    let bytes = c.get(&v.path).unwrap().unwrap();
    let file = a.directory.join("standalone.tps");
    std::fs::write(&file, &bytes).unwrap();
    c.values.lock().unwrap().clear();
    let sb = Store::new(&b).unwrap();
    assert!(import_file(
        &sb,
        &json!({"path":file,"passphrase":"incorrect-fixture-key"})
    )
    .is_err());
    assert!(sb.get::<Vec<Value>>("snapshots").unwrap().is_none());
    let imported = import_file(
        &sb,
        &json!({"path":file,"passphrase":"independent-file-fixture"}),
    )
    .unwrap();
    let id = imported["id"].as_str().unwrap();
    load_snapshot(&sb, id).unwrap();
    let preview = runtime::dispatch(
        &json!({"method":"sync.snapshot.preview","directory":b.directory,"id":id}),
        None,
    )
    .unwrap();
    assert_eq!(preview["copies"], 1);
    assert!(sb.state("configuration").unwrap().records.is_empty());
    runtime::dispatch(&json!({"method":"sync.snapshot.restore","directory":b.directory,"id":id,"confirmed":true,"actionId":uuid::Uuid::new_v4().to_string()}),None).unwrap();
    assert_eq!(sb.state("configuration").unwrap().records.len(), 1);
}

#[test]
fn known_complete_library_never_recreates_missing_control() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut c = Cloud::new();
    sync(&a, &mut c).unwrap();
    c.values.lock().unwrap().remove(&control::name(&f.library));
    let before = c.list().unwrap();
    assert_eq!(sync(&a, &mut c).unwrap_err().code, "syncRollback");
    assert_eq!(before, c.list().unwrap());
}

#[test]
fn repair_restores_catalog_reference_when_original_file_still_exists() {
    let f = Fixture::new();
    let a = f.peer("a");
    let mut c = Cloud::new();
    let s = Store::new(&a).unwrap();
    edit(&a, "a", "host", json!({"label":"recoverable"}));
    let l = control::acquire(&s, &mut c, "sync").unwrap();
    let cfg = s.config().unwrap();
    {
        let mut ns = Namespace {
            cloud: &mut c,
            library: cfg.library.clone(),
            generation: cfg.generation.clone(),
            guard: Some(&l),
        };
        runtime::exchange(&s, &mut ns).unwrap();
    }
    control::release(&s, &mut c, &l).unwrap();
    let (mut head, old) = control::read(&mut c, &cfg.library).unwrap().unwrap();
    let mut names = super::super::lease::catalog_names(&mut c, &head).unwrap();
    let missing = names
        .iter()
        .find(|n| n.contains("-batch-"))
        .unwrap()
        .clone();
    let original = c.get(&missing).unwrap().unwrap();
    names.retain(|n| n != &missing);
    head.catalog =
        Some(super::super::lease::catalog_build(&mut c, &cfg.library, "", names).unwrap());
    c.compare_exchange(
        &control::name(&cfg.library),
        Some(&old),
        &head.signed(&cfg).unwrap(),
    )
    .unwrap();
    let l = control::acquire(&s, &mut c, "repair").unwrap();
    assert_eq!(repair(&a, &s, &mut c, &l).unwrap(), 1);
    assert_eq!(c.get(&missing).unwrap().unwrap(), original);
    assert!(l.names(&mut c).unwrap().contains(&missing));
    control::release(&s, &mut c, &l).unwrap();
}

#[test]
fn interrupted_first_upload_can_resume_without_acknowledging_pending_edits() {
    struct FailPut(Cloud, bool);
    impl Objects for FailPut {
        fn list(&mut self) -> Result<Vec<String>> {
            self.0.list()
        }
        fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
            self.0.get(n)
        }
        fn put(&mut self, n: &str, b: &[u8]) -> Result<()> {
            if self.1 && n.contains("/full-") {
                self.1 = false;
                return Err(err("fixture", "upload interrupted"));
            }
            self.0.put(n, b)
        }
        fn server_time(&self) -> Option<i64> {
            self.0.server_time()
        }
        fn compare_exchange(&mut self, n: &str, e: Option<&[u8]>, b: &[u8]) -> Result<bool> {
            self.0.compare_exchange(n, e, b)
        }
        fn remove_retired(&mut self, n: &str) -> Result<()> {
            self.0.remove_retired(n)
        }
    }
    let f = Fixture::new();
    let a = f.peer("a");
    let mut c = FailPut(Cloud::new(), true);
    edit(&a, "a", "host", json!({"label":"pending"}));
    assert!(sync(&a, &mut c).is_err());
    let s = Store::new(&a).unwrap();
    let pending: i64 =
        s.db.query_row(
            "SELECT count(*) FROM tp_sync_operations WHERE published=0",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(pending > 0);
    let (head, _) = control::read(&mut c, &f.library).unwrap().unwrap();
    assert!(head.bundles.unwrap().current.is_none());
    sync(&a, &mut c).unwrap();
    assert!(history(&a).current.is_some());
    let b = f.peer("b");
    sync(&b, &mut c).unwrap();
    assert_eq!(
        s.state("configuration").unwrap(),
        Store::new(&b).unwrap().state("configuration").unwrap()
    );
}
