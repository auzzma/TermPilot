use super::{
    store::{Config, Store},
    transport::{Backend, Objects, Provider},
    *,
};
use crate::vault::Vault;
use serde_json::{json, Value};
use std::{collections::BTreeMap, path::PathBuf};
const OLD: &str = "old-sync-passphrase-中文";
const NEW: &str = "new-sync-passphrase-中文";
struct Fixture {
    root: PathBuf,
    library: String,
}
impl Fixture {
    fn new() -> Self {
        Self {
            root: std::env::temp_dir().join(format!("termpilot-rekey-{}", uuid::Uuid::new_v4())),
            library: uuid::Uuid::new_v4().to_string(),
        }
    }
    fn peer(&self, name: &str, password: &str) -> Vault {
        let vault = Vault::open(&self.root.join(name), None).unwrap();
        let store = Store::new(&vault).unwrap();
        store
            .put(
                "config",
                &Config {
                    library: self.library.clone(),
                    generation: String::new(),
                    generation_sequence: 0,
                    device: uuid::Uuid::new_v4().to_string(),
                    name: name.into(),
                    auto: false,
                    scopes: policy::SCOPES.iter().map(|s| (*s).into()).collect(),
                    lock_timeout_minutes: super::lease::default_timeout(),
                    retention_days: Some(30),
                    scope_keys: runtime::derive_keys(password, &self.library).unwrap(),
                    provider: Provider::Folder {
                        path: self.root.join("cloud"),
                    },
                },
            )
            .unwrap();
        journal::set_context(&vault.db, &json!({}), true).unwrap();
        vault
    }
    fn cloud(&self) -> Backend {
        Backend::new(
            Provider::Folder {
                path: self.root.join("cloud"),
            },
            &self.library,
        )
        .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
fn call(vault: &Vault, mut request: Value) -> Result<Value> {
    request["directory"] = json!(vault.directory);
    super::dispatch(&request, None)
}
fn run(vault: &Vault) -> Value {
    call(vault, json!({"method":"sync.run"})).unwrap()
}
fn host(label: &str) -> Value {
    json!({"label":label,"hostname":"fixture.invalid","port":22,"username":"fixture","authentication":"password","password":"private-host-secret","connectionKind":"ssh"})
}
fn begin(vault: &Vault) -> Value {
    call(vault,json!({"method":"sync.password.begin","oldPassphrase":OLD,"newPassphrase":NEW,"confirmPassphrase":NEW,"confirmed":true,"clientsUpdated":true})).unwrap()
}
fn finish(vault: &Vault) -> Value {
    call(vault, json!({"method":"sync.password.resume"})).unwrap()
}
fn namespace<'a>(cloud: &'a mut dyn Objects, config: &Config) -> control::Namespace<'a> {
    control::Namespace {
        cloud,
        library: config.library.clone(),
        generation: config.generation.clone(),
        guard: None,
    }
}

#[test]
fn full_reencryption_preserves_deletions_snapshots_secrets_and_offline_edits() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", OLD);
    let b = fixture.peer("B", OLD);
    let h = a.save("hosts", host("before-delete"), None).unwrap();
    run(&a);
    let snapshots = call(&a, json!({"method":"sync.snapshot"})).unwrap();
    run(&a);
    run(&b);
    let snapshot_id = snapshots["snapshots"].as_array().unwrap().last().unwrap()["id"].clone();
    a.delete("hosts", &h["id"]).unwrap();
    run(&a);
    let offline = b.save("hosts", host("offline-new-host"), None).unwrap();
    let before = Store::new(&a).unwrap().config().unwrap();
    let pending = begin(&a);
    assert_eq!(pending["passwordChange"]["active"], true);
    let done = finish(&a);
    assert_eq!(done["passwordChange"]["percent"], 100);
    assert_eq!(done["passwordChange"]["active"], false);
    assert!(!rekey::active(&Store::new(&a).unwrap()).unwrap());
    assert_eq!(done["pending"], 0);
    assert!(
        call(
            &a,
            json!({"method":"sync.snapshot.preview","id":snapshot_id})
        )
        .unwrap()["copies"]
            .as_u64()
            .unwrap()
            > 0
    );

    assert_eq!(
        call(&b, json!({"method":"sync.run"})).unwrap_err().code,
        "syncPasswordChanged"
    );
    assert_eq!(
        call(
            &b,
            json!({"method":"sync.password.unlock","passphrase":OLD})
        )
        .unwrap_err()
        .code,
        "syncPasswordChanged"
    );
    call(
        &b,
        json!({"method":"sync.password.unlock","passphrase":NEW}),
    )
    .unwrap();
    run(&b);
    run(&a);
    run(&b);
    let sa = Store::new(&a).unwrap();
    let sb = Store::new(&b).unwrap();
    let state_a = sa.state("configuration").unwrap();
    let state_b = sb.state("configuration").unwrap();
    assert_eq!(state_a, state_b);
    assert!(state_a.records[&format!("hosts/{}", h["id"].as_str().unwrap())].deleted());
    assert!(state_a
        .records
        .contains_key(&format!("hosts/{}", offline["id"].as_str().unwrap())));
    assert!(!state_a.recycle.is_empty());
    let preview = call(
        &a,
        json!({"method":"sync.snapshot.preview","id":snapshot_id}),
    )
    .unwrap();
    assert!(preview["copies"].as_u64().unwrap() > 0);
    let c = fixture.peer("C", NEW);
    run(&c);
    // Joining can trigger a verified history compaction; existing peers adopt it.
    run(&a);
    run(&b);
    assert_eq!(
        Store::new(&c).unwrap().config().unwrap().generation,
        sa.config().unwrap().generation
    );
    let mut cloud = fixture.cloud();
    let current = sa.config().unwrap();
    let reference=control::read(&mut cloud,&current.library).unwrap().unwrap().0.bundles.unwrap().current.unwrap();
    let bytes=cloud.get(&reference.path).unwrap().unwrap();
    assert!(super::bundle::verify_bytes(&before,&bytes).is_err());
    assert!(super::bundle::verify_bytes(&current,&bytes).is_ok());
    let encrypted:Vec<u8>=super::tests::cloud_tree(&fixture.root.join("cloud")).into_values().flatten().collect();
    for secret in [OLD, NEW, "private-host-secret", "offline-new-host"] {
        assert!(!encrypted
            .windows(secret.len())
            .any(|w| w == secret.as_bytes()));
    }
}

struct FaultCloud {
    inner: Backend,
    fail_put: bool,
    fail_commit: bool,
    log: Vec<(String, String)>,
}
impl Objects for FaultCloud {
    fn list(&mut self) -> Result<Vec<String>> {
        self.inner.list()
    }
    fn get(&mut self, name: &str) -> Result<Option<Vec<u8>>> {
        self.log.push(("get".into(), name.into()));
        self.inner.get(name)
    }
    fn put(&mut self, name: &str, data: &[u8]) -> Result<()> {
        self.log.push(("put".into(), name.into()));
        let fresh=self.inner.get(name)?.is_none();
        self.inner.put(name, data)?;
        if self.fail_put && fresh && (name.contains("-g-") || name.contains("/full-")) && !name.contains("-catalog-") {
            self.fail_put = false;
            return Err(err("syncNetwork", "lost upload response"));
        }
        Ok(())
    }
    fn server_time(&self) -> Option<i64> {
        self.inner.server_time()
    }
    fn compare_exchange(
        &mut self,
        name: &str,
        expected: Option<&[u8]>,
        data: &[u8],
    ) -> Result<bool> {
        let result = self.inner.compare_exchange(name, expected, data)?;
        let head: Value = serde_json::from_slice(data).unwrap();
        if self.fail_commit
            && head["lock"].is_null()
            && !head["generation"].as_str().unwrap().is_empty()
        {
            self.fail_commit = false;
            return Err(err("syncNetwork", "lost commit response"));
        }
        Ok(result)
    }
}
#[test]
fn interrupted_upload_resumes_same_ciphertext_and_downloads_everything_first() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", OLD);
    a.save("hosts", host("resume"), None).unwrap();
    run(&a);
    begin(&a);
    let store = Store::new(&a).unwrap();
    let h=control::read(&mut fixture.cloud(),&fixture.library).unwrap().unwrap().0.bundles.unwrap();
    let source_names:Vec<_>=h.current.iter().chain(&h.versions).map(|v|v.path.clone()).collect();
    let mut fault = FaultCloud {
        inner: fixture.cloud(),
        fail_put: true,
        fail_commit: false,
        log: Vec::new(),
    };
    assert!(rekey::resume(&a, &store, &mut fault).is_err());
    let first_put = fault
        .log
        .iter()
        .position(|(op, name)| op == "put" && name.contains("/full-") && !source_names.contains(name))
        .unwrap();
    for name in source_names.iter().filter(|n| !n.ends_with("-control.tps")) {
        assert!(fault.log[..first_put]
            .iter()
            .any(|(op, n)| op == "get" && n == name));
    }
    let raw_new: BTreeMap<_, _> = fault
        .inner
        .list()
        .unwrap()
        .into_iter()
        .filter(|n| n.contains("-g-"))
        .map(|n| {
            let value = fault.inner.get(&n).unwrap().unwrap();
            (n, value)
        })
        .collect();
    drop(store);
    drop(a);
    let a = Vault::open(&fixture.root.join("A"), None).unwrap();
    let store = Store::new(&a).unwrap();
    rekey::resume(&a, &store, &mut fault).unwrap();
    for (name, bytes) in raw_new {
        assert_eq!(fault.inner.get(&name).unwrap().unwrap(), bytes);
    }
    assert_eq!(rekey::progress(&store).unwrap()["phase"], "completed");
}
#[test]
fn lost_commit_ack_is_recovered_without_overwriting_the_new_generation() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", OLD);
    a.save("hosts", host("commit"), None).unwrap();
    run(&a);
    begin(&a);
    let store = Store::new(&a).unwrap();
    let mut fault = FaultCloud {
        inner: fixture.cloud(),
        fail_put: false,
        fail_commit: true,
        log: Vec::new(),
    };
    assert!(rekey::resume(&a, &store, &mut fault).is_err());
    let committed = control::read(&mut fault.inner, &fixture.library)
        .unwrap()
        .unwrap()
        .1;
    assert!(store.config().unwrap().generation.is_empty());
    drop(store);
    drop(a);
    let a = Vault::open(&fixture.root.join("A"), None).unwrap();
    let store = Store::new(&a).unwrap();
    rekey::resume(&a, &store, &mut fault).unwrap();
    let committed: control::Head = serde_json::from_slice(&committed).unwrap();
    let after = control::read(&mut fault.inner, &fixture.library).unwrap().unwrap().0;
    assert_eq!(after.generation, committed.generation);
    assert_eq!(after.sequence, committed.sequence);
    assert!(after.lock.is_none());
    after.verify(&store.config().unwrap()).unwrap();
    let original = super::lease::catalog_names(&mut fault.inner, &committed).unwrap();
    let final_names = super::lease::catalog_names(&mut fault.inner, &after).unwrap();
    assert!(original.iter().all(|n| final_names.contains(n)));
    assert!(!store.config().unwrap().generation.is_empty());
}
#[test]
fn wrong_password_and_mismatched_confirmation_do_not_start_a_job() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", OLD);
    for (old, new, confirmation) in [
        ("wrong-password-here", NEW, NEW),
        (OLD, NEW, "different-new-password"),
        (OLD, OLD, OLD),
    ] {
        assert!(call(&a,json!({"method":"sync.password.begin","oldPassphrase":old,"newPassphrase":new,"confirmPassphrase":confirmation,"confirmed":true,"clientsUpdated":true})).is_err());
        assert!(!rekey::active(&Store::new(&a).unwrap()).unwrap());
    }
}
#[test]
fn another_device_cannot_sync_or_rotate_while_migration_holds_the_lock() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", OLD);
    let b = fixture.peer("B", OLD);
    a.save("hosts", host("exclusive"), None).unwrap();
    run(&a);
    run(&b);
    begin(&a);
    begin(&b);
    let store = Store::new(&a).unwrap();
    let mut cloud = fixture.cloud();
    control::acquire(&store, &mut cloud, "password").unwrap();
    assert_eq!(
        call(&b, json!({"method":"sync.password.resume"}))
            .unwrap_err()
            .code,
        "syncCloudBusy"
    );
    finish(&a);
    assert_eq!(
        call(&b, json!({"method":"sync.password.resume"}))
            .unwrap_err()
            .code,
        "syncPasswordChanged"
    );
    assert!(!rekey::active(&Store::new(&b).unwrap()).unwrap());
    call(
        &b,
        json!({"method":"sync.password.unlock","passphrase":NEW}),
    )
    .unwrap();
    run(&b);
}
#[test]
fn corrupt_source_fails_before_any_new_ciphertext_is_uploaded() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", OLD);
    a.save("hosts", host("corrupt"), None).unwrap();
    run(&a);
    begin(&a);
    let cloud = fixture.cloud();
    drop(cloud);
    let reference=control::read(&mut fixture.cloud(),&fixture.library).unwrap().unwrap().0.bundles.unwrap().current.unwrap();
    let path=fixture.root.join("cloud").join(reference.path);
    let original = std::fs::read(&path).unwrap();
    std::fs::write(&path, b"corrupted").unwrap();
    assert!(call(&a, json!({"method":"sync.password.resume"})).is_err());
    assert!(!fixture
        .cloud()
        .list()
        .unwrap()
        .iter()
        .any(|n| n.contains("-g-")));
    std::fs::write(&path, original).unwrap();
    finish(&a);
}

#[test]
#[ignore = "run python3 scripts/test-webdav.py (real Apache, loopback only)"]
fn real_apache_webdav_password_reencryption_and_offline_peer() {
    let root = std::env::var("TERMPILOT_TEST_WEBDAV_ROOT").unwrap();
    assert_eq!(
        reqwest::Url::parse(&root).unwrap().host_str(),
        Some("127.0.0.1")
    );
    for auth in ["basic", "digest"] {
        let fixture = Fixture::new();
        let a = fixture.peer("A", OLD);
        let b = fixture.peer("B", OLD);
        for vault in [&a, &b] {
            let store = Store::new(vault).unwrap();
            let mut config = store.config().unwrap();
            config.provider = Provider::Webdav {
                endpoint: format!("{root}/{auth}/同步 空间"),
                username: "fixture".into(),
                password: std::env::var("TERMPILOT_TEST_WEBDAV_PASSWORD").unwrap(),
                auth_type: auth.into(),
                token: String::new(),
            };
            store.put("config", &config).unwrap();
        }
        a.save("hosts", host("real-rekey-never-on-wire"), None)
            .unwrap();
        run(&a);
        run(&b);
        b.save("hosts", host("offline-rekey-never-on-wire"), None)
            .unwrap();
        begin(&a);
        finish(&a);
        assert_eq!(
            call(&b, json!({"method":"sync.run"})).unwrap_err().code,
            "syncPasswordChanged"
        );
        call(
            &b,
            json!({"method":"sync.password.unlock","passphrase":NEW}),
        )
        .unwrap();
        run(&b);
        run(&a);
        assert_eq!(a.list("hosts").unwrap().len(), 2);
        assert_eq!(
            Store::new(&a).unwrap().state("configuration").unwrap(),
            Store::new(&b).unwrap().state("configuration").unwrap()
        );
    }
}

#[test]
fn disabled_scope_history_repeated_rotation_and_stale_peer_are_preserved() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", OLD);
    let b = fixture.peer("B", OLD);
    a.save("hosts", host("history"), None).unwrap();
    run(&a);
    run(&b);
    call(
        &a,
        json!({"method":"sync.configure","scopes":["configuration"],"confirmed":true}),
    )
    .unwrap();
    begin(&a);
    finish(&a);
    run(&a);
    call(&a,json!({"method":"sync.password.begin","oldPassphrase":NEW,"newPassphrase":"third-sync-passphrase","confirmPassphrase":"third-sync-passphrase","confirmed":true,"clientsUpdated":true})).unwrap();
    finish(&a);
    run(&a);
    call(
        &b,
        json!({"method":"sync.password.unlock","passphrase":"third-sync-passphrase"}),
    )
    .unwrap();
    run(&b);
    run(&a);
    let store = Store::new(&b).unwrap();
    assert_eq!(store.config().unwrap().generation_sequence, 2);
    assert_eq!(store.state("credentials").unwrap().records.len(), 1);
    assert_eq!(
        b.list("hosts").unwrap()[0]["password"],
        "private-host-secret"
    );
    // A new device configured with a typo can correct it without losing work.
    let c = fixture.peer("C", "mistyped-passphrase");
    c.save("hosts", host("pending-C"), None).unwrap();
    call(
        &c,
        json!({"method":"sync.password.unlock","passphrase":"third-sync-passphrase"}),
    )
    .unwrap();
    run(&c);
    run(&b);
    assert_eq!(b.list("hosts").unwrap().len(), 2);
}

#[test]
fn unknown_future_scope_stops_migration_instead_of_omitting_data() {
    use sha2::{Digest, Sha256};
    let fixture = Fixture::new();
    let a = fixture.peer("A", OLD);
    run(&a);
    let bytes = b"ciphertext-from-a-future-client";
    let name = format!(
        "tp1-{}-batch-futureScope-{}.tps",
        fixture.library,
        hex::encode(Sha256::digest(bytes))
    );
    let store = Store::new(&a).unwrap();
    let mut cloud = fixture.cloud();
    let lease = control::acquire(&store, &mut cloud, "sync").unwrap();
    control::Namespace { cloud: &mut cloud, library: fixture.library.clone(), generation: String::new(), guard: Some(&lease) }.put(&name, bytes).unwrap();
    control::release(&store, &mut cloud, &lease).unwrap();
    begin(&a);
    assert_eq!(
        call(&a, json!({"method":"sync.password.resume"}))
            .unwrap_err()
            .code,
        "syncVersion"
    );
    assert!(!fixture
        .cloud()
        .list()
        .unwrap()
        .iter()
        .any(|name| name.contains("-g-")));
}
