use super::{
    control::{self, Namespace},
    lease,
    store::{Config, Store},
    transport::{Objects, Provider},
    *,
};
use crate::vault::Vault;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

#[derive(Clone)]
pub(super) struct Cloud {
    pub(super) values: Arc<Mutex<BTreeMap<String, Vec<u8>>>>,
    time: Arc<AtomicI64>,
    background: bool,
}
impl Cloud {
    pub(super) fn new() -> Self {
        Self {
            values: Arc::default(),
            time: Arc::new(AtomicI64::new(10_000)),
            background: false,
        }
    }
    pub(super) fn advance(&self, seconds: i64) {
        self.time.fetch_add(seconds, Ordering::SeqCst);
    }
}
impl Objects for Cloud {
    fn list(&mut self) -> Result<Vec<String>> {
        Ok(self.values.lock().unwrap().keys().cloned().collect())
    }
    fn get(&mut self, name: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.values.lock().unwrap().get(name).cloned())
    }
    fn put(&mut self, name: &str, value: &[u8]) -> Result<()> {
        let mut values = self.values.lock().unwrap();
        if values.get(name).is_some_and(|v| v != value) {
            return Err(err("syncCollision", "collision"));
        }
        values.insert(name.into(), value.into());
        Ok(())
    }
    fn remove_retired(&mut self, name: &str) -> Result<()> { self.values.lock().unwrap().remove(name); Ok(()) }
    fn server_time(&self) -> Option<i64> {
        Some(self.time.load(Ordering::SeqCst))
    }
    fn lease_connection(&self) -> Result<Option<Box<dyn Objects + Send>>> {
        Ok(self
            .background
            .then(|| Box::new(self.clone()) as Box<dyn Objects + Send>))
    }
    fn compare_exchange(
        &mut self,
        name: &str,
        expected: Option<&[u8]>,
        value: &[u8],
    ) -> Result<bool> {
        let mut values = self.values.lock().unwrap();
        if values.get(name).map(Vec::as_slice) != expected {
            return Ok(false);
        }
        values.insert(name.into(), value.into());
        Ok(true)
    }
}
pub(super) struct Fixture {
    root: std::path::PathBuf,
    pub(super) library: String,
}
impl Fixture {
    pub(super) fn new() -> Self {
        Self {
            root: std::env::temp_dir().join(format!("termpilot-lease-{}", uuid::Uuid::new_v4())),
            library: uuid::Uuid::new_v4().to_string(),
        }
    }
    pub(super) fn peer(&self, name: &str) -> Vault {
        let vault = Vault::open(&self.root.join(name), None).unwrap();
        Store::new(&vault)
            .unwrap()
            .put(
                "config",
                &Config {
                    library: self.library.clone(),
                    generation: String::new(),
                    generation_sequence: 0,
                    device: name.into(),
                    name: name.into(),
                    auto: false,
                    lock_timeout_minutes: 1,
                    retention_days: Some(30),
                    scopes: vec!["configuration".into()],
                    scope_keys: BTreeMap::from([("configuration".into(), vec![7; 32])]),
                    provider: Provider::Folder {
                        path: self.root.join("cloud"),
                    },
                },
            )
            .unwrap();
        vault
    }
    fn object(&self, data: &[u8]) -> String {
        format!(
            "tp1-{}-chunk-configuration-{}.tps",
            self.library,
            hex::encode(Sha256::digest(data))
        )
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn active_lease_renews_beyond_original_deadline_and_expired_owner_is_fenced() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let sa = Store::new(&a).unwrap();
    let sb = Store::new(&b).unwrap();
    let mut cloud = Cloud::new();
    let first = control::acquire(&sa, &mut cloud, "sync").unwrap();
    cloud.advance(40);
    first.renew(&mut cloud).unwrap();
    cloud.advance(30);
    assert_eq!(
        control::acquire(&sb, &mut cloud, "sync")
            .err()
            .unwrap()
            .code,
        "syncCloudBusy"
    );
    cloud.advance(31);
    let second = control::acquire(&sb, &mut cloud, "sync").unwrap();
    for result in [
        first.renew(&mut cloud),
        control::release(&sa, &mut cloud, &first),
    ] {
        assert_eq!(result.unwrap_err().code, "syncLeaseLost");
    }
    control::release(&sb, &mut cloud, &second).unwrap();
    assert!(control::read(&mut cloud, &f.library)
        .unwrap()
        .unwrap()
        .0
        .lock
        .is_none());
}

#[test]
fn reacquiring_same_device_uses_new_fence_and_old_worker_cannot_unlock_it() {
    let f = Fixture::new();
    let a = f.peer("a");
    let sa = Store::new(&a).unwrap();
    let mut cloud = Cloud::new();
    let old = control::acquire(&sa, &mut cloud, "sync").unwrap();
    let old_token = sa.get::<String>("cloudLockToken").unwrap();
    let new = control::acquire(&sa, &mut cloud, "sync").unwrap();
    assert_ne!(old_token, sa.get::<String>("cloudLockToken").unwrap());
    assert!(control::release(&sa, &mut cloud, &old).is_err());
    control::release(&sa, &mut cloud, &new).unwrap();
}

#[test]
fn legacy_lock_is_not_stolen_and_owner_upgrades_without_losing_objects() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let sa = Store::new(&a).unwrap();
    let sb = Store::new(&b).unwrap();
    let mut cloud = Cloud::new();
    let mut head = control::Head::new(&sa.config().unwrap());
    head.version = 2;
    head.catalog = None;
    head.lock = Some(control::Lock {
        device: "a".into(),
        token: "durable".into(),
        kind: "sync".into(),
        expires_at: None,
        timeout_minutes: None,
    });
    let old = head.signed(&sa.config().unwrap()).unwrap();
    // A v2 verifier serializes exactly these fields; no lease fields are emitted.
    assert!(!String::from_utf8(old.clone())
        .unwrap()
        .contains("expires_at"));
    cloud
        .compare_exchange(&control::name(&f.library), None, &old)
        .unwrap();
    cloud.advance(86_400 * 365);
    assert_eq!(
        control::acquire(&sb, &mut cloud, "sync")
            .err()
            .unwrap()
            .code,
        "syncCloudBusy"
    );
    sa.put("cloudLockToken", &"durable").unwrap();
    let object = f.object(b"legacy");
    cloud.put(&object, b"legacy").unwrap();
    let lease = control::acquire(&sa, &mut cloud, "sync").unwrap();
    assert_eq!(lease.names(&mut cloud).unwrap(), vec![object]);
    let head = control::read(&mut cloud, &f.library).unwrap().unwrap().0;
    assert_eq!(head.version, 4);
    head.verify(&sa.config().unwrap()).unwrap();
    control::release(&sa, &mut cloud, &lease).unwrap();
}

struct DelayedPut<'a> {
    inner: Cloud,
    other: &'a Store<'a>,
    fired: bool,
}
impl Objects for DelayedPut<'_> {
    fn list(&mut self) -> Result<Vec<String>> {
        self.inner.list()
    }
    fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
        self.inner.get(n)
    }
    fn put(&mut self, n: &str, d: &[u8]) -> Result<()> {
        if !self.fired {
            self.fired = true;
            self.inner.advance(61);
            let lease = control::acquire(self.other, &mut self.inner, "sync")?;
            control::release(self.other, &mut self.inner, &lease)?;
        }
        self.inner.put(n, d)
    }
    fn server_time(&self) -> Option<i64> {
        self.inner.server_time()
    }
    fn compare_exchange(&mut self, n: &str, e: Option<&[u8]>, d: &[u8]) -> Result<bool> {
        self.inner.compare_exchange(n, e, d)
    }
}
#[test]
fn delayed_upload_after_takeover_is_never_published_or_applied() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let sa = Store::new(&a).unwrap();
    let sb = Store::new(&b).unwrap();
    let mut cloud = Cloud::new();
    let lease = control::acquire(&sa, &mut cloud, "sync").unwrap();
    let object = f.object(b"stale");
    let mut delayed = DelayedPut {
        inner: cloud.clone(),
        other: &sb,
        fired: false,
    };
    let mut ns = Namespace {
        cloud: &mut delayed,
        library: f.library.clone(),
        generation: String::new(),
        guard: Some(&lease),
    };
    assert_eq!(ns.put(&object, b"stale").unwrap_err().code, "syncLeaseLost");
    assert!(cloud.get(&object).unwrap().is_some()); // Request reached storage late.
    let other = control::acquire(&sb, &mut cloud, "sync").unwrap();
    assert!(!other.names(&mut cloud).unwrap().contains(&object)); // No catalog CAS, invisible.
    control::release(&sb, &mut cloud, &other).unwrap();
}

#[test]
fn two_expired_lock_contenders_have_only_one_winner() {
    let f = Fixture::new();
    let a = f.peer("a");
    let sa = Store::new(&a).unwrap();
    let mut cloud = Cloud::new();
    let old = control::acquire(&sa, &mut cloud, "sync").unwrap();
    drop(old);
    cloud.advance(61);
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let outcomes = std::thread::scope(|scope| {
        let handles: Vec<_> = ["b", "c"]
            .into_iter()
            .map(|n| {
                let vault = f.peer(n);
                let mut cloud = cloud.clone();
                let barrier = barrier.clone();
                scope.spawn(move || {
                    let store = Store::new(&vault).unwrap();
                    barrier.wait();
                    control::acquire(&store, &mut cloud, "sync").is_ok()
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert_eq!(outcomes.into_iter().filter(|ok| *ok).count(), 1);
}

#[test]
fn settings_default_validate_and_survive_reopening_profiles() {
    let f = Fixture::new();
    let a = f.peer("a");
    let store = Store::new(&a).unwrap();
    let mut config = serde_json::to_value(store.config().unwrap()).unwrap();
    config
        .as_object_mut()
        .unwrap()
        .remove("lock_timeout_minutes");
    assert_eq!(
        serde_json::from_value::<Config>(config)
            .unwrap()
            .lock_timeout_minutes,
        60
    );
    let call = |mut req: serde_json::Value| {
        req["directory"] = json!(a.directory);
        super::dispatch(&req, None)
    };
    for invalid in [
        json!(0),
        json!(1441),
        json!(-1),
        json!(1.5),
        json!("60"),
        json!(null),
    ] {
        assert_eq!(
            call(json!({"method":"sync.configure","confirmed":true,"lockTimeoutMinutes":invalid}))
                .unwrap_err()
                .code,
            "syncLeaseSettings"
        );
    }
    let result =
        call(json!({"method":"sync.configure","confirmed":true,"lockTimeoutMinutes":37})).unwrap();
    assert_eq!(result["lockTimeoutMinutes"], 37);
    assert_eq!(
        call(json!({"method":"sync.status"})).unwrap()["profiles"][0]["lockTimeoutMinutes"],
        37
    );
    let reopened = Vault::open(&a.directory, None).unwrap();
    assert_eq!(
        Store::new(&reopened)
            .unwrap()
            .config()
            .unwrap()
            .lock_timeout_minutes,
        37
    );
}

#[test]
fn missing_cloud_clock_never_uses_client_wall_time_for_takeover() {
    struct NoClock(Cloud);
    impl Objects for NoClock {
        fn list(&mut self) -> Result<Vec<String>> {
            self.0.list()
        }
        fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
            self.0.get(n)
        }
        fn put(&mut self, n: &str, d: &[u8]) -> Result<()> {
            self.0.put(n, d)
        }
        fn server_time(&self) -> Option<i64> {
            None
        }
    }
    let f = Fixture::new();
    let a = f.peer("a");
    let store = Store::new(&a).unwrap();
    assert_eq!(
        control::acquire(&store, &mut NoClock(Cloud::new()), "sync")
            .err()
            .unwrap()
            .code,
        "syncLeaseClock"
    );
}

#[test]
fn renewable_fields_are_authenticated() {
    let f = Fixture::new();
    let a = f.peer("a");
    let sa = Store::new(&a).unwrap();
    let mut cloud = Cloud::new();
    let _lease = control::acquire(&sa, &mut cloud, "sync").unwrap();
    let mut head = control::read(&mut cloud, &f.library).unwrap().unwrap().0;
    head.lock.as_mut().unwrap().expires_at = Some(i64::MAX);
    assert!(head.verify(&sa.config().unwrap()).is_err());
}

#[test]
fn background_heartbeat_runs_during_idle_work_and_stops_on_drop() {
    let f = Fixture::new();
    let a = f.peer("a");
    let store = Store::new(&a).unwrap();
    let mut cloud = Cloud::new();
    let lease = control::acquire(&store, &mut cloud, "sync").unwrap();
    drop(lease);
    let (head, bytes) = control::read(&mut cloud, &f.library).unwrap().unwrap();
    let initial = head.lock.as_ref().unwrap().expires_at.unwrap();
    cloud.background = true;
    let lease = lease::Lease::start_with_interval(
        store.config().unwrap(),
        head,
        bytes,
        &mut cloud,
        Duration::from_millis(20),
    )
    .unwrap();
    cloud.advance(10);
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        if control::read(&mut cloud, &f.library)
            .unwrap()
            .unwrap()
            .0
            .lock
            .unwrap()
            .expires_at
            .unwrap()
            > initial
        {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "heartbeat did not renew while worker idle"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    drop(lease);
    let stopped = cloud.get(&control::name(&f.library)).unwrap();
    cloud.advance(10);
    std::thread::sleep(Duration::from_millis(60));
    assert_eq!(cloud.get(&control::name(&f.library)).unwrap(), stopped);
}

#[test]
fn catalog_page_boundary_preserves_committed_objects_and_rejects_corruption() {
    let f = Fixture::new();
    let a = f.peer("a");
    let sa = Store::new(&a).unwrap();
    let mut cloud = Cloud::new();
    // Import a full legacy page, then publish across the page boundary.
    let mut original = Vec::new();
    for i in 0..1024 {
        let data = format!("catalog-fixture-{i}").into_bytes();
        let name = f.object(&data);
        cloud.put(&name, &data).unwrap();
        original.push(name);
    }
    let lease = control::acquire(&sa, &mut cloud, "sync").unwrap();
    let extra = f.object(b"next page");
    Namespace {
        cloud: &mut cloud,
        library: f.library.clone(),
        generation: String::new(),
        guard: Some(&lease),
    }
    .put(&extra, b"next page")
    .unwrap();
    control::release(&sa, &mut cloud, &lease).unwrap();
    let head = control::read(&mut cloud, &f.library).unwrap().unwrap().0;
    assert_eq!(head.catalog.as_ref().unwrap().len(), 2);
    let names = lease::catalog_names(&mut cloud, &head).unwrap();
    assert_eq!(names.len(), 1025);
    assert!(original.iter().all(|n| names.contains(n)));
    assert!(names.contains(&extra));
    let page = head.catalog.as_ref().unwrap()[0].clone();
    cloud
        .values
        .lock()
        .unwrap()
        .insert(page.clone(), b"[]".to_vec());
    assert_eq!(
        lease::catalog_names(&mut cloud, &head).unwrap_err().code,
        "syncIntegrity"
    );
    cloud.values.lock().unwrap().remove(&page);
    assert_eq!(
        lease::catalog_names(&mut cloud, &head).unwrap_err().code,
        "syncRollback"
    );
}

#[test]
fn expired_rekey_cannot_cut_over_after_another_device_has_acquired() {
    let f = Fixture::new();
    let a = f.peer("a");
    let b = f.peer("b");
    let sa = Store::new(&a).unwrap();
    let sb = Store::new(&b).unwrap();
    let mut cloud = Cloud::new();
    let migrating = control::acquire(&sa, &mut cloud, "password").unwrap();
    cloud.advance(61);
    let current = control::acquire(&sb, &mut cloud, "sync").unwrap();
    let mut new = sa.config().unwrap();
    new.generation = uuid::Uuid::new_v4().to_string();
    new.generation_sequence = 1;
    new.scope_keys.insert("configuration".into(), vec![8; 32]);
    assert_eq!(
        migrating
            .cutover(&mut cloud, &new, Vec::new())
            .unwrap_err()
            .code,
        "syncLeaseLost"
    );
    let head = control::read(&mut cloud, &f.library).unwrap().unwrap().0;
    assert_eq!(head.sequence, 0);
    assert!(head.generation.is_empty());
    head.verify(&sb.config().unwrap()).unwrap();
    control::release(&sb, &mut cloud, &current).unwrap();
}
