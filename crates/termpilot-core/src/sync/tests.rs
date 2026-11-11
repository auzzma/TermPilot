use super::*;
use model::*;
use serde_json::json;
use std::collections::BTreeMap;
fn edit(
    writer: &str,
    seq: u64,
    basis: Vector,
    record: &str,
    field: &str,
    value: serde_json::Value,
) -> Operation {
    Operation {
        version: 1,
        library: "test".into(),
        scope: "configuration".into(),
        dot: Dot {
            writer: writer.into(),
            seq,
        },
        basis,
        collection: "hosts".into(),
        record: record.into(),
        action: Action::Patch {
            fields: BTreeMap::from([(field.into(), value)]),
        },
    }
}
#[test]
fn four_devices_offline_four_hundred_additions_converge() {
    let mut operations = Vec::new();
    for device in 0..4 {
        for seq in 1..=100 {
            let writer = format!("device{device}");
            let basis = if seq == 1 {
                Vector::new()
            } else {
                BTreeMap::from([(writer.clone(), seq - 1)])
            };
            operations.push(edit(
                &writer,
                seq,
                basis,
                &format!("{device}-{seq}"),
                "label",
                json!(seq),
            ));
        }
    }
    let mut expected = State::default();
    for op in &operations {
        expected
            .receive(op.clone(), "test", "configuration")
            .unwrap();
    }
    use rand::{seq::SliceRandom, SeedableRng};
    let mut random = rand::rngs::StdRng::seed_from_u64(20261009);
    for _ in 0..20 {
        operations.shuffle(&mut random);
        let mut state = State::default();
        for op in &operations {
            state.receive(op.clone(), "test", "configuration").unwrap();
            state.receive(op.clone(), "test", "configuration").unwrap();
        }
        assert_eq!(state, expected);
    }
    assert_eq!(expected.records.len(), 400);
    assert!(expected.waiting.is_empty());
}
#[test]
fn gap_is_not_acknowledged_and_same_id_different_content_is_rejected() {
    let first = edit("A", 1, Vector::new(), "H", "label", json!("first"));
    let second = edit(
        "A",
        2,
        BTreeMap::from([("A".into(), 1)]),
        "H",
        "label",
        json!("second"),
    );
    let mut state = State::default();
    state.receive(second, "test", "configuration").unwrap();
    assert!(state.frontier.is_empty());
    state
        .receive(first.clone(), "test", "configuration")
        .unwrap();
    assert_eq!(state.frontier["A"], 2);
    let mut changed = first;
    changed.record = "different".into();
    assert!(state.receive(changed, "test", "configuration").is_err());
}
#[test]
fn independent_fields_merge_conflicts_remain_delete_wins() {
    let a = edit("A", 1, Vector::new(), "H", "label", json!("alpha"));
    let b = edit("B", 1, Vector::new(), "H", "port", json!(22));
    let c = edit("C", 1, Vector::new(), "H", "label", json!("beta"));
    let delete = Operation {
        action: Action::Delete {
            recovery: json!({"label":"alpha"}),
            retention_days: Some(30),
            deleted_at: "2026-10-09".into(),
        },
        ..edit(
            "A",
            2,
            BTreeMap::from([("A".into(), 1)]),
            "H",
            "ignored",
            json!(0),
        )
    };
    let mut left = State::default();
    for op in [&a, &b, &c, &delete] {
        left.receive(op.clone(), "test", "configuration").unwrap();
    }
    let mut right = State::default();
    for op in [&delete, &c, &b, &a] {
        right.receive(op.clone(), "test", "configuration").unwrap();
    }
    assert_eq!(left, right);
    assert!(left.records["hosts/H"].deleted());
    assert!(left.records["hosts/H"].conflicted());
    assert_eq!(left.records["hosts/H"].value()["port"], 22);
    assert_eq!(left.recycle.len(), 1);
}
#[test]
fn scope_split_excludes_nested_secrets_and_local_paths() {
    let value = json!({"id":"id","label":"host","identity_file":"/secret/path","proxy":{"password":"pw","host":"proxy"},"password":"pw"});
    let fields = policy::fields("hosts", &value, "configuration");
    let text = serde_json::to_string(&fields).unwrap();
    assert!(!text.contains("pw"));
    assert!(!text.contains("secret/path"));
    assert!(text.contains("proxy"));
    let secrets = policy::fields("hosts", &value, "credentials");
    assert_eq!(secrets["password"], "pw");
}

struct Fixture(std::path::PathBuf);
impl Fixture {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!("termpilot-sync-test-{}", uuid::Uuid::new_v4())))
    }
    fn peer(&self, name: &str, library: &str) -> crate::vault::Vault {
        let vault = crate::vault::Vault::open(&self.0.join(name), None).unwrap();
        let store = store::Store::new(&vault).unwrap();
        store
            .put(
                "config",
                &store::Config {
                    generation: String::new(),
                    generation_sequence: 0,
                    library: library.into(),
                    device: name.into(),
                    name: name.into(),
                    auto: false,
                    scopes: vec!["configuration".into()],
                    retention_days: Some(30),
                    scope_keys: BTreeMap::from([("configuration".into(), vec![7; 32])]),
                    provider: transport::Provider::Folder {
                        path: self.0.join("cloud"),
                    },
                },
            )
            .unwrap();
        journal::set_context(&vault.db, &json!({}), true).unwrap();
        vault
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn host(label: &str) -> serde_json::Value {
    json!({"label":label,"hostname":"fixture.invalid","port":22,"username":"fixture","authentication":"password","password":"never-on-wire","connectionKind":"ssh"})
}
fn flush(vault: &crate::vault::Vault, cloud: &mut dyn transport::Objects) {
    let store = store::Store::new(vault).unwrap();
    store
        .transaction(|| {
            store.drain(&vault.db)?;
            journal::set_context(&vault.db, &store.context()?, true)
        })
        .unwrap();
    runtime::exchange(&store, cloud).unwrap();
    store.transaction(|| projection::vault(&store)).unwrap();
}

#[test]
fn enabling_credentials_on_a_new_device_does_not_publish_missing_secrets() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let source = fixture.peer("source", &library);
    let receiver = fixture.peer("receiver", &library);
    let enable = |vault: &crate::vault::Vault| {
        let store = store::Store::new(vault).unwrap();
        let mut config = store.config().unwrap();
        config.scopes.push("credentials".into());
        config.scope_keys.insert("credentials".into(), vec![8; 32]);
        store.put("config", &config).unwrap();
        journal::seed_scopes(&vault.db, &vault.key, false, Some(&["credentials".into()])).unwrap();
    };
    enable(&source);
    let credential = source.save("credentials", json!({"label":"key","username":"user","kind":"identityKey","privateKey":"fixture-private-key","savesPassphrase":true,"passphrase":"fixture-passphrase"}), None).unwrap();
    let host = source.save("hosts", host("password host"), None).unwrap();
    let mut cloud = transport::Backend::new(
        transport::Provider::Folder {
            path: fixture.0.join("cloud"),
        },
        &library,
    )
    .unwrap();
    flush(&source, &mut cloud);
    flush(&receiver, &mut cloud);
    assert!(receiver
        .get("credentials", &credential["id"])
        .unwrap()
        .unwrap()["privateKey"]
        .is_null());
    enable(&receiver);
    flush(&receiver, &mut cloud);
    flush(&source, &mut cloud);
    assert_eq!(
        receiver
            .get("credentials", &credential["id"])
            .unwrap()
            .unwrap()["privateKey"],
        "fixture-private-key"
    );
    assert_eq!(
        receiver.get("hosts", &host["id"]).unwrap().unwrap()["password"],
        "never-on-wire"
    );
    for vault in [&source, &receiver] {
        let state = store::Store::new(vault)
            .unwrap()
            .state("credentials")
            .unwrap();
        assert!(
            state.records.values().all(|r| !r.conflicted()),
            "Missing local secrets must not become competing edits"
        );
    }
    // Clearing a field on an existing credential is still an intentional edit.
    let mut updated = receiver
        .get("credentials", &credential["id"])
        .unwrap()
        .unwrap();
    updated["savesPassphrase"] = json!(false);
    updated["passphrase"] = Value::Null;
    receiver.save("credentials", updated, None).unwrap();
    flush(&receiver, &mut cloud);
    flush(&source, &mut cloud);
    assert!(source
        .get("credentials", &credential["id"])
        .unwrap()
        .unwrap()["passphrase"]
        .is_null());
}
#[test]
fn initial_secret_seed_preserves_array_slots_and_omits_missing_fields() {
    let fields = serde_json::from_value(json!({
        "password": null, "private_key": "fixture-key", "saves_passphrase": 0,
        "providers": [{"apiKey":""}, {"apiKey":"fixture-api-key","headers":{}}]
    }))
    .unwrap();
    assert_eq!(
        json!(policy::initial_secrets(fields)),
        json!({
            "private_key":"fixture-key", "providers":[null,{"apiKey":"fixture-api-key"}]
        })
    );
}
#[test]
fn legacy_null_passphrase_flag_can_be_projected_without_losing_secrets() {
    let fixture = Fixture::new();
    let vault = fixture.peer("legacy", &uuid::Uuid::new_v4().to_string());
    let credential = vault.save("credentials", json!({"label":"key","username":"user","kind":"identityKey","privateKey":"fixture-key","savesPassphrase":true,"passphrase":"fixture-passphrase"}), None).unwrap();
    let id = credential["id"].as_str().unwrap();
    projection::write_row(
        &vault.db,
        &vault.key,
        "ssh_credentials",
        "id",
        id,
        &json!({"saves_passphrase":null}),
    )
    .unwrap();
    let stored = vault
        .get("credentials", &credential["id"])
        .unwrap()
        .unwrap();
    assert_eq!(stored["savesPassphrase"], true);
    assert_eq!(stored["privateKey"], "fixture-key");
    projection::write_row(
        &vault.db,
        &vault.key,
        "ssh_credentials",
        "id",
        id,
        &json!({"saves_passphrase":null,"passphrase":null}),
    )
    .unwrap();
    assert_eq!(
        vault
            .get("credentials", &credential["id"])
            .unwrap()
            .unwrap()["savesPassphrase"],
        false
    );
    projection::write_row(
        &vault.db,
        &vault.key,
        "ssh_credentials",
        "id",
        id,
        &json!({"saves_passphrase":null,"passphrase":"fixture-restored"}),
    )
    .unwrap();
    let stored = vault
        .get("credentials", &credential["id"])
        .unwrap()
        .unwrap();
    assert_eq!(stored["savesPassphrase"], true);
    assert_eq!(stored["passphrase"], "fixture-restored");
}
#[test]
fn four_real_vaults_merge_and_file_transport_is_incremental() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let peers = (0..4)
        .map(|i| fixture.peer(&format!("peer{i}"), &library))
        .collect::<Vec<_>>();
    let mut cloud = transport::Backend::new(
        transport::Provider::Folder {
            path: fixture.0.join("cloud"),
        },
        &library,
    )
    .unwrap();
    for (i, peer) in peers.iter().enumerate() {
        for j in 0..10 {
            peer.save("hosts", host(&format!("host-{i}-{j}")), None)
                .unwrap();
        }
    }
    for peer in &peers {
        flush(peer, &mut cloud);
    }
    for peer in &peers {
        flush(peer, &mut cloud);
        assert_eq!(peer.list("hosts").unwrap().len(), 40);
    }
    for peer in &peers {
        flush(peer, &mut cloud);
    }
    let baseline = store::Store::new(&peers[0])
        .unwrap()
        .state("configuration")
        .unwrap();
    for peer in &peers {
        assert_eq!(
            store::Store::new(peer)
                .unwrap()
                .state("configuration")
                .unwrap(),
            baseline
        );
    }
    let before = std::fs::read_dir(fixture.0.join("cloud")).unwrap().count();
    flush(&peers[0], &mut cloud);
    assert_eq!(
        std::fs::read_dir(fixture.0.join("cloud")).unwrap().count(),
        before
    );
    for file in std::fs::read_dir(fixture.0.join("cloud")).unwrap() {
        let data = std::fs::read(file.unwrap().path()).unwrap();
        assert!(!String::from_utf8_lossy(&data).contains("never-on-wire"));
    }
}

/// Real server interoperability is opt-in; the runner owns the loopback Apache
/// instance and its disposable credentials/storage. Never point this at a vault.
#[test]
#[ignore = "run python3 scripts/test-webdav.py (real Apache, loopback only)"]
fn real_apache_webdav_auth_concurrency_conflicts_deletion_and_snapshot() {
    use transport::Objects;
    let root = std::env::var("TERMPILOT_TEST_WEBDAV_ROOT").expect("use test-webdav.py");
    let url = reqwest::Url::parse(&root).unwrap();
    assert_eq!(url.scheme(), "http");
    assert_eq!(url.host_str(), Some("127.0.0.1"));
    let password = std::env::var("TERMPILOT_TEST_WEBDAV_PASSWORD").unwrap();
    for auth in ["basic", "digest"] {
        let provider = transport::Provider::Webdav {
            endpoint: format!("{root}/{auth}/同步 空间"),
            username: "fixture".into(),
            password: password.clone(),
            auth_type: auth.into(),
            token: String::new(),
        };
        // Exercise real HTTP auth, DAV discovery, large objects and collisions.
        let contract_library = uuid::Uuid::new_v4().to_string();
        let mut contract = transport::Backend::new(provider.clone(), &contract_library).unwrap();
        assert!(contract.list().unwrap().is_empty());
        let name = format!("tp1-{contract_library}-chunk-contract.tps");
        let bytes = vec![0x9b; 384 * 1024];
        contract.put(&name, &bytes).unwrap();
        contract.put(&name, &bytes).unwrap();
        assert_eq!(contract.get(&name).unwrap().unwrap(), bytes);
        assert_eq!(contract.list().unwrap(), vec![name.clone()]);
        assert_eq!(
            contract.put(&name, b"collision").unwrap_err().code,
            "syncCollision"
        );
        assert!(contract.server_time().is_some());
        let mut rejected = provider.clone();
        if let transport::Provider::Webdav { password, .. } = &mut rejected {
            *password = "incorrect-fixture-password".into();
        }
        let mut rejected = transport::Backend::new(rejected, &contract_library).unwrap();
        assert_eq!(rejected.list().unwrap_err().code, "syncAuth");
        assert_eq!(rejected.get(&name).unwrap_err().code, "syncAuth");

        let fixture = Fixture::new();
        let library = uuid::Uuid::new_v4().to_string();
        let peers = (0..4)
            .map(|i| {
                let peer = fixture.peer(&format!("peer{i}"), &library);
                let store = store::Store::new(&peer).unwrap();
                let mut config = store.config().unwrap();
                config.provider = provider.clone();
                store.put("config", &config).unwrap();
                for j in 0..10 {
                    peer.save("hosts", host(&format!("real-webdav-host-{i}-{j}")), None)
                        .unwrap();
                }
                drop(store);
                peer
            })
            .collect::<Vec<_>>();
        // Four independent clients publish simultaneously, with no shared client
        // or mock transport mutex masking DAV/server concurrency behaviour.
        let peers = std::thread::scope(|scope| {
            let jobs = peers
                .into_iter()
                .map(|peer| {
                    let provider = provider.clone();
                    let library = library.clone();
                    scope.spawn(move || {
                        let mut cloud = transport::Backend::new(provider, &library).unwrap();
                        flush(&peer, &mut cloud);
                        peer
                    })
                })
                .collect::<Vec<_>>();
            jobs.into_iter()
                .map(|job| job.join().unwrap())
                .collect::<Vec<_>>()
        });
        let mut cloud = transport::Backend::new(provider.clone(), &library).unwrap();
        for _ in 0..2 {
            for peer in &peers {
                flush(peer, &mut cloud);
            }
        }
        for peer in &peers {
            assert_eq!(peer.list("hosts").unwrap().len(), 40);
        }
        let items = peers[0].list("hosts").unwrap();
        let common = items[0].clone();
        let deleted = items[1].clone();
        for (i, peer) in peers.iter().take(3).enumerate() {
            let mut change = peer
                .list("hosts")
                .unwrap()
                .into_iter()
                .find(|item| item["id"] == common["id"])
                .unwrap();
            if i == 2 {
                change["port"] = json!(2222);
            } else {
                change["label"] = json!(format!("offline-conflict-{i}"));
            }
            peer.save("hosts", change, None).unwrap();
        }
        let mut late_edit = peers[1]
            .list("hosts")
            .unwrap()
            .into_iter()
            .find(|item| item["id"] == deleted["id"])
            .unwrap();
        late_edit["label"] = json!("edited-without-seeing-deletion");
        peers[1].save("hosts", late_edit, None).unwrap();
        peers[3].delete("hosts", &deleted["id"]).unwrap();
        for i in [3, 1, 2, 0] {
            flush(&peers[i], &mut cloud);
        }
        for _ in 0..2 {
            for peer in &peers {
                flush(peer, &mut cloud);
            }
        }
        let baseline = store::Store::new(&peers[0])
            .unwrap()
            .state("configuration")
            .unwrap();
        let record = &baseline.records[&format!("hosts/{}", common["id"].as_str().unwrap())];
        assert!(record.conflicted());
        assert_eq!(record.fields["label"].len(), 2);
        assert_eq!(record.value()["port"], 2222);
        let record = &baseline.records[&format!("hosts/{}", deleted["id"].as_str().unwrap())];
        assert!(record.deleted() && record.conflicted());
        assert_eq!(baseline.recycle.len(), 1);
        for peer in &peers {
            assert_eq!(peer.list("hosts").unwrap().len(), 39);
            assert_eq!(
                store::Store::new(peer)
                    .unwrap()
                    .state("configuration")
                    .unwrap(),
                baseline
            );
        }
        let store = store::Store::new(&peers[0]).unwrap();
        store
            .transaction(|| runtime::maybe_snapshot(&store, true))
            .unwrap();
        runtime::exchange(&store, &mut cloud).unwrap();
        assert!(cloud
            .list()
            .unwrap()
            .iter()
            .any(|name| name.contains("-snapshot-")));
        let newcomer = fixture.peer("newcomer", &library);
        newcomer
            .save("hosts", host("newcomer-offline-addition"), None)
            .unwrap();
        flush(&newcomer, &mut cloud);
        assert_eq!(newcomer.list("hosts").unwrap().len(), 40);
        for _ in 0..2 {
            for peer in &peers {
                flush(peer, &mut cloud);
            }
            flush(&newcomer, &mut cloud);
        }
        let expected = store.state("configuration").unwrap();
        assert_eq!(
            store::Store::new(&newcomer)
                .unwrap()
                .state("configuration")
                .unwrap(),
            expected
        );
        let inventory = cloud.list().unwrap();
        drop(store);
        drop(peers);
        let restarted = crate::vault::Vault::open(&fixture.0.join("peer0"), None).unwrap();
        flush(&restarted, &mut cloud);
        assert_eq!(
            store::Store::new(&restarted)
                .unwrap()
                .state("configuration")
                .unwrap(),
            expected
        );
        assert_eq!(
            cloud.list().unwrap(),
            inventory,
            "restart/no-op must not upload full data"
        );
        eprintln!("{auth}: real DAV auth + 384 KiB object + four concurrent replicas + conflicts/delete + snapshot/new replica + restart passed");
    }
}
#[test]
fn native_sql_writes_are_atomic_encrypted_and_delete_is_recoverable_without_snapshot() {
    let fixture = Fixture::new();
    let vault = fixture.peer("A", &uuid::Uuid::new_v4().to_string());
    let saved = vault.save("hosts", host("sensitive-label"), None).unwrap();
    let count: i64 = vault
        .db
        .query_row("SELECT COUNT(*) FROM tp_sync_journal", [], |r| r.get(0))
        .unwrap();
    vault
        .db
        .execute_batch("BEGIN IMMEDIATE; UPDATE hosts SET label='rolled back'; ROLLBACK;")
        .unwrap();
    assert_eq!(
        count,
        vault
            .db
            .query_row::<i64, _, _>("SELECT COUNT(*) FROM tp_sync_journal", [], |r| r.get(0))
            .unwrap()
    );
    let bytes: Vec<u8> = vault
        .db
        .query_row("SELECT payload FROM tp_sync_journal LIMIT 1", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("sensitive-label"));
    vault.delete("hosts", &saved["id"]).unwrap();
    let store = store::Store::new(&vault).unwrap();
    store.transaction(|| store.drain(&vault.db)).unwrap();
    let state = store.state("configuration").unwrap();
    let deleted = state.recycle.values().next().unwrap();
    assert_eq!(
        deleted.recovery.as_ref().unwrap()["label"],
        "sensitive-label"
    );
    assert!(deleted.published_at.is_none());
    assert!(!serde_json::to_string(&state)
        .unwrap()
        .contains("never-on-wire"));
}
#[test]
fn snapshot_excludes_pending_changes() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let vault = fixture.peer("A", &library);
    let saved = vault.save("hosts", host("published"), None).unwrap();
    let mut cloud = transport::Backend::new(
        transport::Provider::Folder {
            path: fixture.0.join("cloud"),
        },
        &library,
    )
    .unwrap();
    flush(&vault, &mut cloud);
    let mut changed = saved;
    changed["label"] = json!("pending");
    vault.save("hosts", changed, None).unwrap();
    let store = store::Store::new(&vault).unwrap();
    store.transaction(|| store.drain(&vault.db)).unwrap();
    let snapshot = store.published_state("configuration").unwrap();
    assert_eq!(
        snapshot.records.values().next().unwrap().value()["label"],
        "published"
    );
    assert_eq!(
        store
            .state("configuration")
            .unwrap()
            .records
            .values()
            .next()
            .unwrap()
            .value()["label"],
        "pending"
    );
}

#[derive(Default)]
struct MemoryCloud {
    files: BTreeMap<String, Vec<u8>>,
    fail_after_put: bool,
    uploads: Vec<(String, Vec<u8>)>,
    reads: Vec<String>,
}
impl transport::Objects for MemoryCloud {
    fn list(&mut self) -> Result<Vec<String>> {
        Ok(self.files.keys().cloned().collect())
    }
    fn get(&mut self, name: &str) -> Result<Option<Vec<u8>>> {
        self.reads.push(name.into());
        Ok(self.files.get(name).cloned())
    }
    fn put(&mut self, name: &str, data: &[u8]) -> Result<()> {
        self.uploads.push((name.into(), data.into()));
        self.files.insert(name.into(), data.into());
        if self.fail_after_put {
            self.fail_after_put = false;
            return Err(err("offline", "test lost acknowledgement"));
        }
        Ok(())
    }
    fn server_time(&self) -> Option<i64> {
        Some(1_791_504_000)
    }
}
#[test]
fn lost_upload_ack_reuses_identical_ciphertext_after_restart() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let vault = fixture.peer("A", &library);
    vault.save("hosts", host("retry"), None).unwrap();
    let store = store::Store::new(&vault).unwrap();
    store.transaction(|| store.drain(&vault.db)).unwrap();
    let mut cloud = MemoryCloud {
        fail_after_put: true,
        ..Default::default()
    };
    assert!(runtime::exchange(&store, &mut cloud).is_err());
    let first = cloud.uploads[0].clone();
    drop(store);
    drop(vault);
    let vault = crate::vault::Vault::open(&fixture.0.join("A"), None).unwrap();
    let store = store::Store::new(&vault).unwrap();
    runtime::exchange(&store, &mut cloud).unwrap();
    assert!(cloud.uploads.iter().skip(1).any(|entry| entry == &first));
    let pending: i64 = store
        .db
        .query_row(
            "SELECT COUNT(*) FROM tp_sync_operations WHERE published=0",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(pending, 0);
}
#[test]
fn corrupt_chunk_and_cloud_rollback_fail_closed() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("A", &library);
    let b = fixture.peer("B", &library);
    a.save("hosts", host("protected"), None).unwrap();
    let mut cloud = MemoryCloud::default();
    flush(&a, &mut cloud);
    let chunk = cloud
        .files
        .keys()
        .find(|k| k.contains("-chunk-"))
        .unwrap()
        .clone();
    let original = cloud.files[&chunk].clone();
    cloud.files.get_mut(&chunk).unwrap()[0] ^= 1;
    let store = store::Store::new(&b).unwrap();
    assert!(runtime::exchange(&store, &mut cloud).is_err());
    assert!(store.state("configuration").unwrap().records.is_empty());
    cloud.files.insert(chunk.clone(), original);
    flush(&b, &mut cloud);
    cloud.files.remove(&chunk);
    assert_eq!(
        runtime::exchange(&store, &mut cloud).unwrap_err().code,
        "syncRollback"
    );
}
#[test]
fn snapshot_merge_does_not_remove_offline_additions_or_revive_purged_recycle() {
    let mut a = State::default();
    let op = edit("A", 1, Vector::new(), "one", "label", json!("one"));
    a.receive(op, "test", "configuration").unwrap();
    let delete = Operation {
        action: Action::Delete {
            recovery: json!({"label":"one"}),
            retention_days: Some(30),
            deleted_at: "2026-10-09".into(),
        },
        ..edit("A", 2, a.frontier.clone(), "one", "x", json!(0))
    };
    a.receive(delete, "test", "configuration").unwrap();
    let old = a.clone();
    a.receive(
        Operation {
            action: Action::Purge {
                recycle_ids: vec!["A:2".into()],
            },
            ..edit("A", 3, a.frontier.clone(), "purge", "x", json!(0))
        },
        "test",
        "configuration",
    )
    .unwrap();
    let mut b = State::default();
    b.receive(
        edit("B", 1, Vector::new(), "offline", "label", json!("saved")),
        "test",
        "configuration",
    )
    .unwrap();
    b.merge(a).unwrap();
    b.merge(old).unwrap();
    assert!(b.records.contains_key("hosts/offline"));
    assert!(b.recycle["A:2"].purged);
    assert!(b.recycle["A:2"].recovery.is_none());
    assert!(b.records["hosts/one"].deleted());
}

fn local_request(vault: &crate::vault::Vault, mut request: serde_json::Value) -> serde_json::Value {
    request["directory"] = json!(vault.directory);
    runtime::dispatch(&request, Some(&vault.key)).unwrap()
}
#[test]
fn recycle_restore_is_idempotent_and_preserves_local_unsynced_password() {
    let fixture = Fixture::new();
    let vault = fixture.peer("A", &uuid::Uuid::new_v4().to_string());
    let saved = vault
        .save("hosts", host("recover local secret"), None)
        .unwrap();
    vault.delete("hosts", &saved["id"]).unwrap();
    let store = store::Store::new(&vault).unwrap();
    store.transaction(|| store.drain(&vault.db)).unwrap();
    let state = store.state("configuration").unwrap();
    let id = state.recycle.keys().next().unwrap();
    let request = json!({"method":"sync.restore","ids":[id],"scope":"configuration","actionId":uuid::Uuid::new_v4().to_string(),"confirmed":true});
    let first = local_request(&vault, request.clone());
    let second = local_request(&vault, request);
    assert_eq!(first, second);
    assert_eq!(vault.list("hosts").unwrap().len(), 1);
    let restored = &vault.list("hosts").unwrap()[0];
    assert_ne!(restored["id"], saved["id"]);
    assert_eq!(restored["password"], "never-on-wire");
    assert!(
        !serde_json::to_string(&store.state("configuration").unwrap())
            .unwrap()
            .contains("never-on-wire")
    );
    assert!(store.state("configuration").unwrap().records
        [&record_key("hosts", saved["id"].as_str().unwrap())]
        .deleted());
}
#[test]
fn retention_never_expires_unpublished_or_conflicted_deletions_and_extension_survives_shortening() {
    let fixture = Fixture::new();
    let vault = fixture.peer("A", &uuid::Uuid::new_v4().to_string());
    let saved = vault.save("hosts", host("retention"), None).unwrap();
    vault.delete("hosts", &saved["id"]).unwrap();
    let store = store::Store::new(&vault).unwrap();
    store.transaction(|| store.drain(&vault.db)).unwrap();
    let id = store
        .state("configuration")
        .unwrap()
        .recycle
        .keys()
        .next()
        .unwrap()
        .clone();
    store
        .transaction(|| runtime::expire_recycle(&store, Some(i64::MAX / 2)))
        .unwrap();
    assert!(!store.state("configuration").unwrap().recycle[&id].purged);
    let start = 1_791_504_000;
    let mut state = store.state("configuration").unwrap();
    state.publication(&id, start);
    store.save_state("configuration", &state).unwrap();
    local_request(&vault, json!({"method":"sync.retention","days":90}));
    local_request(&vault, json!({"method":"sync.retention","days":7}));
    store
        .transaction(|| runtime::expire_recycle(&store, Some(start + 60 * 86400)))
        .unwrap();
    assert!(!store.state("configuration").unwrap().recycle[&id].purged);
    store
        .transaction(|| runtime::expire_recycle(&store, Some(start + 91 * 86400)))
        .unwrap();
    assert!(store.state("configuration").unwrap().recycle[&id].purged);
    // An unobserved edit cannot be silently expired, even with a published delete receipt.
    let saved = vault.save("hosts", host("conflicted"), None).unwrap();
    vault.delete("hosts", &saved["id"]).unwrap();
    store.transaction(|| store.drain(&vault.db)).unwrap();
    let mut state = store.state("configuration").unwrap();
    let id = state
        .recycle
        .iter()
        .find(|(_, v)| v.record == saved["id"])
        .unwrap()
        .0
        .clone();
    state.publication(&id, start);
    store.save_state("configuration", &state).unwrap();
    store
        .append(
            "configuration",
            "offline-editor",
            &Vector::new(),
            "hosts",
            saved["id"].as_str().unwrap(),
            Action::Patch {
                fields: BTreeMap::from([("label".into(), json!("still needed"))]),
            },
        )
        .unwrap();
    store
        .transaction(|| runtime::expire_recycle(&store, Some(start + 1000 * 86400)))
        .unwrap();
    assert!(!store.state("configuration").unwrap().recycle[&id].purged);
}
#[test]
fn disabling_secret_scope_stops_already_staged_objects() {
    let fixture = Fixture::new();
    let vault = fixture.peer("A", &uuid::Uuid::new_v4().to_string());
    let store = store::Store::new(&vault).unwrap();
    let mut config = store.config().unwrap();
    config.scopes.push("credentials".into());
    config.scope_keys.insert("credentials".into(), vec![8; 32]);
    store.put("config", &config).unwrap();
    vault.save("hosts", host("scopes"), None).unwrap();
    store.transaction(|| store.drain(&vault.db)).unwrap();
    let mut cloud = MemoryCloud {
        fail_after_put: true,
        ..Default::default()
    };
    assert!(runtime::exchange(&store, &mut cloud).is_err());
    cloud.uploads.clear();
    local_request(
        &vault,
        json!({"method":"sync.configure","scopes":["configuration"],"confirmed":true}),
    );
    runtime::exchange(&store, &mut cloud).unwrap();
    assert!(cloud
        .uploads
        .iter()
        .all(|(name, _)| !name.contains("-credentials-")));
    let pending: i64 = vault
        .db
        .query_row(
            "SELECT COUNT(*) FROM tp_sync_objects WHERE scope='credentials' AND published=0",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(pending > 0);
}
#[test]
fn verified_snapshot_catalog_is_portable_and_restore_creates_copies_once() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("A", &library);
    let b = fixture.peer("B", &library);
    let mut cloud = MemoryCloud::default();
    a.save("hosts", host("snapshot copy"), None).unwrap();
    flush(&a, &mut cloud);
    let store = store::Store::new(&a).unwrap();
    store
        .transaction(|| runtime::maybe_snapshot(&store, true))
        .unwrap();
    runtime::exchange(&store, &mut cloud).unwrap();
    flush(&b, &mut cloud);
    let status = local_request(&b, json!({"method":"sync.status"}));
    assert_eq!(status["snapshots"].as_array().unwrap().len(), 1);
    assert_eq!(status["snapshots"][0]["verified"], true);
    let id = &status["snapshots"][0]["id"];
    let preview = local_request(&b, json!({"method":"sync.snapshot.preview","id":id}));
    assert_eq!(preview["copies"], 1);
    let request = json!({"method":"sync.snapshot.restore","id":id,"confirmed":true,"actionId":uuid::Uuid::new_v4().to_string()});
    let first = local_request(&b, request.clone());
    assert_eq!(first, local_request(&b, request));
    assert_eq!(b.list("hosts").unwrap().len(), 2);
    flush(&b, &mut cloud);
    flush(&a, &mut cloud);
    assert_eq!(a.list("hosts").unwrap().len(), 2);
}
#[test]
fn no_op_sync_does_not_rewrite_native_rows_or_timestamps() {
    let fixture = Fixture::new();
    let vault = fixture.peer("A", &uuid::Uuid::new_v4().to_string());
    let mut cloud = MemoryCloud::default();
    vault.save("hosts", host("unchanged"), None).unwrap();
    flush(&vault, &mut cloud);
    let before = vault.list("hosts").unwrap();
    let changes = vault.db.total_changes();
    flush(&vault, &mut cloud);
    assert_eq!(vault.list("hosts").unwrap(), before); // including credential and timestamps
    assert!(vault.db.total_changes() > changes); // sync bookkeeping can still change
    assert_eq!(
        store::Store::new(&vault)
            .unwrap()
            .operations("configuration", false)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn cloned_database_uses_a_new_writer_and_keeps_original_pending_operations() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("A", &library);
    a.save("hosts", host("before clone"), None).unwrap();
    let old_writer = store::Store::new(&a).unwrap().writer().unwrap();
    std::fs::create_dir_all(fixture.0.join("clone")).unwrap();
    a.db.backup(
        rusqlite::DatabaseName::Main,
        fixture.0.join("clone/vault.sqlite"),
        None,
    )
    .unwrap();
    std::fs::write(fixture.0.join("clone/credential.key"), a.key.as_slice()).unwrap();
    let clone = crate::vault::Vault::open(&fixture.0.join("clone"), None).unwrap();
    let new_writer = store::Store::new(&clone).unwrap().writer().unwrap();
    assert_ne!(old_writer, new_writer);
    a.save("hosts", host("original new"), None).unwrap();
    clone.save("hosts", host("clone new"), None).unwrap();
    let mut cloud = MemoryCloud::default();
    flush(&a, &mut cloud);
    flush(&clone, &mut cloud);
    flush(&a, &mut cloud);
    assert_eq!(a.list("hosts").unwrap().len(), 3);
    assert_eq!(clone.list("hosts").unwrap().len(), 3);
}
#[test]
fn authentication_conflicts_block_connection_and_explicit_delete_resolution_releases_conflict() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", &uuid::Uuid::new_v4().to_string());
    let saved = a.save("hosts", host("guard"), None).unwrap();
    let store = store::Store::new(&a).unwrap();
    store.transaction(|| store.drain(&a.db)).unwrap();
    store
        .append(
            "configuration",
            "offline-device",
            &Vector::new(),
            "hosts",
            saved["id"].as_str().unwrap(),
            Action::Patch {
                fields: BTreeMap::from([(
                    "$authentication".into(),
                    json!({"username":"other","authentication":"identityFile"}),
                )]),
            },
        )
        .unwrap();
    assert_eq!(
        runtime::dispatch(
            &json!({"method":"sync.checkConnection","directory":a.directory,"host":saved}),
            Some(&a.key)
        )
        .unwrap_err()
        .code,
        "syncAuthenticationConflict"
    );
    a.delete("hosts", &saved["id"]).unwrap();
    store.transaction(|| store.drain(&a.db)).unwrap();
    let key = record_key("hosts", saved["id"].as_str().unwrap());
    local_request(
        &a,
        json!({"method":"sync.resolve","scope":"configuration","id":key,"keepDeleted":true}),
    );
    let state = store.state("configuration").unwrap();
    assert!(state.records[&key].deleted());
    assert!(!state.records[&key].conflicted());
}
#[test]
fn stale_editor_is_rejected_without_losing_new_remote_fields() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", &uuid::Uuid::new_v4().to_string());
    let mut saved = a.save("hosts", host("old"), None).unwrap();
    a.db.execute(
        "UPDATE hosts SET label='remote change',updated_at='2030-01-01 00:00:00.000'",
        [],
    )
    .unwrap();
    saved["username"] = json!("my draft");
    assert_eq!(a.save("hosts", saved, None).unwrap_err().code, "staleEdit");
    assert_eq!(a.list("hosts").unwrap()[0]["label"], "remote change");
}
#[test]
fn compressed_snapshot_and_small_increment_stay_incremental() {
    let fixture = Fixture::new();
    let a = fixture.peer("A", &uuid::Uuid::new_v4().to_string());
    let mut cloud = MemoryCloud::default();
    for i in 0..100 {
        a.save("hosts", host(&format!("host {i}")), None).unwrap();
    }
    flush(&a, &mut cloud);
    let store = store::Store::new(&a).unwrap();
    store
        .transaction(|| runtime::maybe_snapshot(&store, true))
        .unwrap();
    runtime::exchange(&store, &mut cloud).unwrap();
    let full_bytes = cloud.uploads.iter().map(|(_, v)| v.len()).sum::<usize>();
    cloud.uploads.clear();
    let mut saved = a.list("hosts").unwrap()[0].clone();
    saved["label"] = json!("one field changed");
    a.save("hosts", saved, None).unwrap();
    flush(&a, &mut cloud);
    let incremental = cloud.uploads.iter().map(|(_, v)| v.len()).sum::<usize>();
    assert!(
        incremental < full_bytes / 5,
        "incremental={incremental} full={full_bytes}"
    );
    assert!(cloud.uploads.iter().all(|(n, _)| !n.contains("-snapshot-")));
}

fn put_ai(vault: &crate::vault::Vault, collection: &str, id: &str, value: serde_json::Value) {
    let db = rusqlite::Connection::open(vault.directory.join("ai.sqlite")).unwrap();
    db.execute_batch("CREATE TABLE IF NOT EXISTS records(collection TEXT NOT NULL,id TEXT NOT NULL,payload BLOB NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(collection,id));").unwrap();
    journal::register(&db, &vault.key).unwrap();
    journal::install(&db, true).unwrap();
    let sealed = crate::vault::crypto::seal(
        &vault.key,
        &serde_json::to_vec(&value).unwrap(),
        format!("TermPilot:AI:v1:{collection}:{id}").as_bytes(),
    )
    .unwrap();
    db.execute("INSERT INTO records VALUES(?1,?2,?3,0) ON CONFLICT(collection,id) DO UPDATE SET payload=excluded.payload",rusqlite::params![collection,id,sealed]).unwrap();
}
fn get_ai(vault: &crate::vault::Vault, collection: &str, id: &str) -> serde_json::Value {
    let db = rusqlite::Connection::open(vault.directory.join("ai.sqlite")).unwrap();
    let bytes: Vec<u8> = db
        .query_row(
            "SELECT payload FROM records WHERE collection=?1 AND id=?2",
            rusqlite::params![collection, id],
            |r| r.get(0),
        )
        .unwrap();
    serde_json::from_slice(
        &crate::vault::crypto::unseal(
            &vault.key,
            &bytes,
            format!("TermPilot:AI:v1:{collection}:{id}").as_bytes(),
        )
        .unwrap(),
    )
    .unwrap()
}
#[test]
fn late_ai_store_completed_messages_are_incremental_and_running_session_is_not_overwritten() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("A", &library);
    let b = fixture.peer("B", &library);
    for vault in [&a, &b] {
        let store = store::Store::new(vault).unwrap();
        let mut config = store.config().unwrap();
        config.scopes.push("aiHistory".into());
        config.scope_keys.insert("aiHistory".into(), vec![9; 32]);
        store.put("config", &config).unwrap();
    }
    let id = uuid::Uuid::new_v4().to_string();
    let conversation = json!({"id":id,"title":"history","scope":"host:test","agent":"fixture","model":"fixture","messages":[{"id":"first","role":"user","content":"one"}],"draft":"local draft","attachments":[],"skills":[],"externalId":null,"status":"idle","updated":0,"usage":null});
    put_ai(&a, "conversations", &id, conversation.clone());
    put_ai(
        &b,
        "settings",
        "main",
        json!({"providers":[],"mode":"confirm"}),
    );
    local_request(&a, json!({"method":"sync.run"}));
    local_request(&b, json!({"method":"sync.run"}));
    let received = get_ai(&b, "conversations", &id);
    assert_eq!(received["messages"][0]["content"], "one");
    assert_eq!(received["draft"], "");
    assert_eq!(received["status"], "idle");
    let mut running = received.clone();
    running["status"] = json!("running");
    running["draft"] = json!("on this device");
    put_ai(&b, "conversations", &id, running);
    let mut next = conversation;
    next["messages"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":"second","role":"assistant","content":"two"}));
    put_ai(&a, "conversations", &id, next);
    local_request(&a, json!({"method":"sync.run"}));
    local_request(&b, json!({"method":"sync.run"}));
    assert_eq!(
        get_ai(&b, "conversations", &id)["messages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(get_ai(&b, "conversations", &id)["status"], "running");
    let state = store::Store::new(&b).unwrap().state("aiHistory").unwrap();
    assert_eq!(
        state.records["ai:messages/second"].value()["message"]["content"],
        "two"
    );
    let store = store::Store::new(&a).unwrap();
    let ops = store.operations("aiHistory", false).unwrap();
    assert_eq!(
        ops.iter()
            .filter(|op| op.collection == "ai:messages" && op.record == "first")
            .count(),
        1
    );
}

#[test]
fn verified_checkpoint_skips_covered_batch_bodies() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("A", &library);
    let b = fixture.peer("B", &library);
    a.save("hosts", host("checkpoint"), None).unwrap();
    let mut cloud = MemoryCloud::default();
    flush(&a, &mut cloud);
    let old_chunks = cloud
        .files
        .keys()
        .filter(|k| k.contains("-chunk-"))
        .cloned()
        .collect::<Vec<_>>();
    let store = store::Store::new(&a).unwrap();
    store
        .transaction(|| runtime::maybe_snapshot(&store, true))
        .unwrap();
    runtime::exchange(&store, &mut cloud).unwrap();
    cloud.reads.clear();
    flush(&b, &mut cloud);
    assert_eq!(
        a.list("hosts").unwrap()[0]["label"],
        b.list("hosts").unwrap()[0]["label"]
    );
    assert!(
        old_chunks.iter().all(|name| !cloud.reads.contains(name)),
        "covered batch bodies must not be downloaded again"
    );
}

#[test]
fn provider_migration_backs_up_and_preserves_offline_changes_and_source() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("A", &library);
    a.save("hosts", host("published"), None).unwrap();
    local_request(&a, json!({"method":"sync.run"}));
    let source = std::fs::read_dir(fixture.0.join("cloud"))
        .unwrap()
        .map(|p| {
            let p = p.unwrap();
            (p.file_name(), std::fs::read(p.path()).unwrap())
        })
        .collect::<BTreeMap<_, _>>();
    a.save("hosts", host("offline"), None).unwrap();
    let destination = fixture.0.join("cloud-new");
    local_request(
        &a,
        json!({"method":"sync.provider","provider":{"kind":"folder","path":destination},"confirmed":true}),
    );
    local_request(&a, json!({"method":"sync.run"}));
    let b = fixture.peer("B", &library);
    let store = store::Store::new(&b).unwrap();
    let mut config = store.config().unwrap();
    config.provider = transport::Provider::Folder { path: destination };
    store.put("config", &config).unwrap();
    local_request(&b, json!({"method":"sync.run"}));
    assert_eq!(b.list("hosts").unwrap().len(), 2);
    assert!(std::fs::read_dir(&a.directory).unwrap().any(|p| p
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with("vault.before-sync-provider-")));
    for (name, content) in source {
        assert_eq!(
            std::fs::read(fixture.0.join("cloud").join(name)).unwrap(),
            content
        );
    }
}

#[test]
fn committed_journal_pruning_and_offline_projection_recovery() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("A", &library);
    let b = fixture.peer("B", &library);
    a.save("hosts", host("recovered"), None).unwrap();
    let store = store::Store::new(&a).unwrap();
    assert!(
        local_request(&a, json!({"method":"sync.status"}))["pending"]
            .as_i64()
            .unwrap()
            > 0
    );
    assert!(store
        .transaction(|| {
            store.drain(&a.db)?;
            Err::<(), _>(err("test", "forced rollback"))
        })
        .is_err());
    store.prune_journal(&a.db).unwrap();
    assert_eq!(
        a.db.query_row("SELECT COUNT(*) FROM tp_sync_journal", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
    let mut cloud = MemoryCloud::default();
    flush(&a, &mut cloud);
    store.prune_journal(&a.db).unwrap();
    assert_eq!(
        a.db.query_row("SELECT COUNT(*) FROM tp_sync_journal", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    let store_b = store::Store::new(&b).unwrap();
    runtime::exchange(&store_b, &mut cloud).unwrap();
    store_b.put("projectionPending", &true).unwrap();
    assert!(b.list("hosts").unwrap().is_empty());
    // Recovery must work without contacting the cloud, including when automatic sync is off.
    local_request(&b, json!({"method":"sync.recover"}));
    assert_eq!(b.list("hosts").unwrap().len(), 1);
    assert_eq!(
        store_b.get::<bool>("projectionPending").unwrap(),
        Some(false)
    );
}

#[test]
fn storage_catalog_and_unavailable_provider_migration_preserve_the_local_library() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("A", &library);
    a.save("hosts", host("offline-kept"), None).unwrap();
    let metadata = local_request(&a, json!({"method":"sync.describe"}));
    let providers = metadata["providers"].as_array().unwrap();
    assert_eq!(
        providers
            .iter()
            .map(|p| p["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["webdav", "s3", "r2"]
    );
    assert!(!providers[2]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .any(|f| f[0] == "region"));
    let store = store::Store::new(&a).unwrap();
    let original = store.config().unwrap();
    let mut old = serde_json::to_value(&original).unwrap();
    old["provider"] = json!({"kind":"removed-provider", "token":"old-local-only-token"});
    old["auto"] = json!(true);
    store.put("config", &old).unwrap();
    let status = local_request(&a, json!({"method":"sync.status"}));
    assert_eq!(status["providerUnavailable"], true);
    assert_eq!(status["auto"], false);
    assert!(!status.to_string().contains("old-local-only-token"));
    assert_eq!(status["library"], library);
    assert_eq!(
        local_request(&a, json!({"method":"sync.tick"}))["skipped"],
        true
    );
    assert_eq!(a.list("hosts").unwrap().len(), 1);
    let new_provider = json!({"kind":"r2","endpoint":"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com", "bucket":"termpilot-sync", "access_key":"fixture-access", "secret_key":"fixture-secret", "prefix":"sync"});
    let result = local_request(
        &a,
        json!({"method":"sync.provider", "provider":new_provider, "confirmed":true}),
    );
    assert_eq!(result["provider"]["kind"], "r2");
    assert_eq!(result["providerUnavailable"], false);
    assert_eq!(result["auto"], false);
    assert!(result["pending"].as_u64().unwrap() > 0);
    assert_eq!(a.list("hosts").unwrap().len(), 1);
    assert_eq!(store.config().unwrap().scope_keys, original.scope_keys);
    let backups: Vec<_> = std::fs::read_dir(&a.directory)
        .unwrap()
        .filter_map(|entry| {
            let entry = entry.unwrap();
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("vault.before-sync-provider-")
                .then_some(entry.path())
        })
        .collect();
    assert_eq!(backups.len(), 1);
    let backup = rusqlite::Connection::open(&backups[0]).unwrap();
    let backup_store = store::Store {
        db: &backup,
        key: &a.key,
    };
    assert_eq!(
        backup_store
            .get::<serde_json::Value>("config")
            .unwrap()
            .unwrap(),
        old
    );
}

#[test]
fn invalid_provider_configuration_never_enables_sync_or_discards_the_previous_connection() {
    let fixture = Fixture::new();
    let vault = crate::vault::Vault::open(&fixture.0.join("new"), None).unwrap();
    let mut request = json!({"method":"sync.configure", "directory":vault.directory, "provider":{"kind":"removed-provider","token":"fixture"}, "confirmed":true,"passphrase":"test-only-passphrase"});
    assert_eq!(
        dispatch(&request, Some(&vault.key)).unwrap_err().code,
        "syncProviderUnavailable"
    );
    assert_eq!(
        local_request(&vault, json!({"method":"sync.status"}))["configured"],
        false
    );
    request["provider"] = json!({"kind":"r2","endpoint":"https://public.r2.dev","bucket":"sync-bucket","access_key":"access","secret_key":"secret"});
    assert_eq!(
        dispatch(&request, Some(&vault.key)).unwrap_err().code,
        "syncR2Endpoint"
    );
    assert_eq!(
        local_request(&vault, json!({"method":"sync.status"}))["configured"],
        false
    );
    let peer = fixture.peer("configured", &uuid::Uuid::new_v4().to_string());
    let store = store::Store::new(&peer).unwrap();
    let before = serde_json::to_value(store.config().unwrap()).unwrap();
    request["method"] = json!("sync.provider");
    request["directory"] = json!(peer.directory);
    assert!(dispatch(&request, Some(&peer.key)).is_err());
    assert_eq!(
        serde_json::to_value(store.config().unwrap()).unwrap(),
        before
    );
}

fn add_profile(
    vault: &crate::vault::Vault,
    title: &str,
    cloud: &str,
    library: &str,
) -> serde_json::Value {
    let status = local_request(
        vault,
        json!({"method":"sync.profile.add","title":title,"provider":{"kind":"folder","path":vault.directory.parent().unwrap().join(cloud)},"library":library,"name":"fixture","passphrase":"profile-test-password","scopes":["configuration","preferences"],"auto":false,"confirmed":true}),
    );
    if status["activeProfile"].is_null() {
        local_request(
            vault,
            json!({"method":"sync.profile.use","id":status["profiles"][0]["id"],"confirmed":true}),
        )
    } else {
        status
    }
}
#[test]
fn named_profiles_switch_preserves_pending_edits_deletes_and_independent_clouds() {
    let fixture = Fixture::new();
    let a = crate::vault::Vault::open(&fixture.0.join("device"), None).unwrap();
    let library_a = uuid::Uuid::new_v4().to_string();
    let library_b = uuid::Uuid::new_v4().to_string();
    let status = add_profile(&a, "Home", "home-cloud", &library_a);
    let id_a = status["activeProfile"].as_str().unwrap().to_owned();
    let removed = a.save("hosts", host("delete while away"), None).unwrap();
    let edited = a.save("hosts", host("edit while away"), None).unwrap();
    local_request(&a, json!({"method":"sync.run"}));
    let offline = a.save("hosts", host("pending A"), None).unwrap();
    let status = add_profile(&a, "Office", "office-cloud", &library_b);
    assert_eq!(status["profiles"].as_array().unwrap().len(), 2);
    assert_eq!(status["activeProfile"], id_a);
    let id_b = status["profiles"][1]["id"].as_str().unwrap().to_owned();
    local_request(
        &a,
        json!({"method":"sync.profile.use","id":id_b,"confirmed":true}),
    );
    a.delete("hosts", &removed["id"]).unwrap();
    let mut modified = edited.clone();
    modified["label"] = json!("updated on B");
    a.save("hosts", modified, None).unwrap();
    a.save("hosts", host("only B until switch"), None).unwrap();
    local_request(
        &a,
        json!({"method":"sync.preferences","values":{"theme":"light"}}),
    );
    put_ai(
        &a,
        "providers",
        "new-provider",
        json!({"id":"new-provider","name":"Offline AI","kind":"openai"}),
    );
    local_request(&a, json!({"method":"sync.run"}));
    local_request(
        &a,
        json!({"method":"sync.profile.use","id":id_a,"confirmed":true}),
    );
    let status = local_request(&a, json!({"method":"sync.run"}));
    assert_eq!(status["library"], library_a);
    assert_eq!(status["preferences"]["theme"], "light");
    assert!(status["recycle"]
        .as_array()
        .unwrap()
        .iter()
        .any(|r| r["record"] == removed["id"]));
    let peer = crate::vault::Vault::open(&fixture.0.join("peer"), None).unwrap();
    add_profile(&peer, "Home", "home-cloud", &library_a);
    local_request(&peer, json!({"method":"sync.run"}));
    let hosts = peer.list("hosts").unwrap();
    assert_eq!(hosts.len(), 3);
    assert!(hosts.iter().any(|h| h["id"] == offline["id"]));
    assert!(hosts
        .iter()
        .any(|h| h["id"] == edited["id"] && h["label"] == "updated on B"));
    assert!(!hosts.iter().any(|h| h["id"] == removed["id"]));
    local_request(
        &a,
        json!({"method":"sync.profile.use","id":id_b,"confirmed":true}),
    );
    let status = local_request(&a, json!({"method":"sync.run"}));
    assert_eq!(status["library"], library_b);
    assert_eq!(status["conflicts"], json!([]));
    let store = store::Store::new(&a).unwrap();
    for operation in store.operations("configuration", false).unwrap() {
        assert_eq!(operation.library, library_b);
    }
    assert_eq!(
        get_ai(&a, "providers", "new-provider")["name"],
        "Offline AI"
    );
}
#[test]
fn profile_edits_preserve_credentials_and_reject_cross_endpoint_reuse() {
    let fixture = Fixture::new();
    let vault = crate::vault::Vault::open(&fixture.0.join("device"), None).unwrap();
    let provider = json!({"kind":"r2","endpoint":"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com","bucket":"termpilot","prefix":"one","access_key":"test-access","secret_key":"test-secret"});
    let request = json!({"method":"sync.profile.add","title":"R2 One","provider":provider,"name":"Mac","passphrase":"profile-test-password","scopes":["configuration"],"confirmed":true});
    let status = local_request(&vault, request.clone());
    assert_eq!(status["configured"], false);
    let status = local_request(
        &vault,
        json!({"method":"sync.profile.use","id":status["profiles"][0]["id"],"confirmed":true}),
    );
    let id = status["activeProfile"].as_str().unwrap();
    assert!(!status.to_string().contains("test-secret"));
    let public = status["profiles"][0]["provider"].clone();
    let mut update = json!({"method":"sync.profile.update","id":id,"title":"Renamed","provider":public,"name":"Mac","scopes":["configuration"],"auto":false,"confirmed":true});
    local_request(&vault, update.clone());
    let store = store::Store::new(&vault).unwrap();
    assert_eq!(
        serde_json::to_value(store.config().unwrap().provider).unwrap()["secret_key"],
        "test-secret"
    );
    update["provider"]["endpoint"] =
        json!("https://11111111111111111111111111111111.r2.cloudflarestorage.com");
    update["directory"] = json!(vault.directory);
    assert!(runtime::dispatch(&update, Some(&vault.key)).is_err());
    assert_eq!(
        store.config().unwrap().provider.public()["endpoint"],
        public["endpoint"]
    );
    let mut other = request;
    other["title"] = json!("R2 Two");
    let status = local_request(&vault, other);
    assert_eq!(status["profiles"].as_array().unwrap().len(), 2);
}
#[test]
fn profiles_migrate_legacy_delete_without_deleting_hosts_and_block_rekey() {
    let fixture = Fixture::new();
    let vault = fixture.peer("legacy", &uuid::Uuid::new_v4().to_string());
    vault.save("hosts", host("keep me"), None).unwrap();
    let status = local_request(&vault, json!({"method":"sync.status"}));
    let id = status["activeProfile"].as_str().unwrap();
    assert!(vault
        .directory
        .join("vault.before-sync-profiles.sqlite")
        .is_file());
    let store = store::Store::new(&vault).unwrap();
    store.put("passwordJob", &json!({"fixture":true})).unwrap();
    let mut remove = json!({"method":"sync.profile.delete","id":id,"confirmed":true,"directory":vault.directory});
    assert_eq!(
        runtime::dispatch(&remove, Some(&vault.key))
            .unwrap_err()
            .code,
        "syncPasswordBusy"
    );
    store.remove("passwordJob").unwrap();
    remove["confirmed"] = json!(false);
    assert!(runtime::dispatch(&remove, Some(&vault.key)).is_err());
    remove["confirmed"] = json!(true);
    let status = local_request(&vault, remove);
    assert_eq!(status["configured"], false);
    assert_eq!(status["profiles"], json!([]));
    assert_eq!(vault.list("hosts").unwrap().len(), 1);
    let status = add_profile(&vault, "New", "new-cloud", "");
    assert_eq!(status["configured"], true);
    local_request(&vault, json!({"method":"sync.run"}));
    assert_eq!(vault.list("hosts").unwrap().len(), 1);
}

#[test]
fn profile_switch_rollback_and_remote_concurrent_edit_keep_both_candidates() {
    let fixture = Fixture::new();
    let a = crate::vault::Vault::open(&fixture.0.join("A"), None).unwrap();
    let peer = crate::vault::Vault::open(&fixture.0.join("peer"), None).unwrap();
    let library = uuid::Uuid::new_v4().to_string();
    let status = add_profile(&a, "A", "cloud-a", &library);
    let id_a = status["activeProfile"].clone();
    a.save("hosts", host("original"), None).unwrap();
    local_request(&a, json!({"method":"sync.run"}));
    add_profile(&peer, "A peer", "cloud-a", &library);
    local_request(&peer, json!({"method":"sync.run"}));
    let status = add_profile(&a, "B", "cloud-b", "");
    let id_b = status["profiles"][1]["id"].clone();
    // Fault in the middle of restoring the target must roll back working tables,
    // selected ID, pending operations and archive together.
    a.db.execute_batch("CREATE TRIGGER fail_profile_switch BEFORE INSERT ON tp_sync_selection BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
    let request =
        json!({"method":"sync.profile.use","id":id_b,"confirmed":true,"directory":a.directory});
    assert!(runtime::dispatch(&request, Some(&a.key)).is_err());
    assert_eq!(
        local_request(&a, json!({"method":"sync.status"}))["activeProfile"],
        id_a
    );
    assert_eq!(a.list("hosts").unwrap().len(), 1);
    a.db.execute_batch("DROP TRIGGER fail_profile_switch")
        .unwrap();
    local_request(&a, request);
    let mut remote = peer.list("hosts").unwrap()[0].clone();
    remote["label"] = json!("remote edit while A inactive");
    peer.save("hosts", remote, None).unwrap();
    local_request(&peer, json!({"method":"sync.run"}));
    let mut local = a.list("hosts").unwrap()[0].clone();
    local["label"] = json!("local edit while using B");
    a.save("hosts", local, None).unwrap();
    local_request(
        &a,
        json!({"method":"sync.profile.use","id":id_a,"confirmed":true}),
    );
    let state = local_request(&a, json!({"method":"sync.run"}));
    let conflicts = state["conflicts"].as_array().unwrap();
    assert!(conflicts.iter().any(|c| c["fields"]["label"]
        .as_array()
        .is_some_and(|v| v.len() == 2)));
}

#[test]
fn inactive_profile_edit_moves_snapshot_and_password_change_stays_isolated() {
    let fixture = Fixture::new();
    let a = crate::vault::Vault::open(&fixture.0.join("A"), None).unwrap();
    let status = add_profile(&a, "A", "cloud-a", "");
    let id_a = status["activeProfile"].clone();
    a.save("hosts", host("published before moving"), None)
        .unwrap();
    local_request(&a, json!({"method":"sync.run"}));
    let status = add_profile(&a, "B", "cloud-b", "");
    let id_b = status["profiles"][1]["id"].clone();
    local_request(
        &a,
        json!({"method":"sync.profile.use","id":id_b,"confirmed":true}),
    );
    let before = std::fs::read_dir(fixture.0.join("cloud-a"))
        .unwrap()
        .map(|p| {
            let p = p.unwrap();
            (p.file_name(), std::fs::read(p.path()).unwrap())
        })
        .collect::<BTreeMap<_, _>>();
    local_request(
        &a,
        json!({"method":"sync.profile.update","id":id_a,"title":"Moved A","provider":{"kind":"folder","path":fixture.0.join("cloud-a-new")},"scopes":["configuration","preferences"],"name":"A","auto":false,"confirmed":true}),
    );
    assert_eq!(
        local_request(&a, json!({"method":"sync.status"}))["activeProfile"],
        id_b
    );
    local_request(
        &a,
        json!({"method":"sync.profile.use","id":id_a,"confirmed":true}),
    );
    local_request(&a, json!({"method":"sync.run"}));
    for (name, bytes) in before {
        assert_eq!(
            std::fs::read(fixture.0.join("cloud-a").join(name)).unwrap(),
            bytes
        );
    }
    local_request(
        &a,
        json!({"method":"sync.password.begin","oldPassphrase":"profile-test-password","newPassphrase":"new-profile-password","confirmPassphrase":"new-profile-password","confirmed":true,"clientsUpdated":true}),
    );
    let switch =
        json!({"method":"sync.profile.use","id":id_b,"confirmed":true,"directory":a.directory});
    assert_eq!(
        runtime::dispatch(&switch, Some(&a.key)).unwrap_err().code,
        "syncPasswordBusy"
    );
    let state = local_request(&a, json!({"method":"sync.password.resume"}));
    assert_eq!(state["keyVersion"], 1);
    local_request(&a, switch);
    assert_eq!(
        local_request(&a, json!({"method":"sync.run"}))["keyVersion"],
        0
    );
    local_request(
        &a,
        json!({"method":"sync.profile.use","id":id_a,"confirmed":true}),
    );
    let state = local_request(&a, json!({"method":"sync.run"}));
    assert_eq!(state["keyVersion"], 1);
    let peer = crate::vault::Vault::open(&fixture.0.join("peer"), None).unwrap();
    let status = local_request(
        &peer,
        json!({"method":"sync.profile.add","title":"Join moved A","provider":{"kind":"folder","path":fixture.0.join("cloud-a-new")},"library":state["library"],"name":"peer","passphrase":"new-profile-password","scopes":["configuration"],"confirmed":true}),
    );
    local_request(
        &peer,
        json!({"method":"sync.profile.use","id":status["profiles"][0]["id"],"confirmed":true}),
    );
    local_request(&peer, json!({"method":"sync.run"}));
    assert_eq!(peer.list("hosts").unwrap().len(), 1);
}

#[test]
fn duplicate_connections_to_same_library_have_distinct_operation_ids() {
    let fixture = Fixture::new();
    let vault = crate::vault::Vault::open(&fixture.0.join("device"), None).unwrap();
    let library = uuid::Uuid::new_v4().to_string();
    let a = add_profile(&vault, "same library A", "cloud", &library)["activeProfile"].clone();
    vault.save("hosts", host("first"), None).unwrap();
    local_request(&vault, json!({"method":"sync.run"}));
    let status = add_profile(&vault, "same library B", "cloud", &library);
    let b = status["profiles"][1]["id"].clone();
    local_request(
        &vault,
        json!({"method":"sync.profile.use","id":b,"confirmed":true}),
    );
    vault.save("hosts", host("second"), None).unwrap();
    local_request(&vault, json!({"method":"sync.run"}));
    local_request(
        &vault,
        json!({"method":"sync.profile.use","id":a,"confirmed":true}),
    );
    let status = local_request(&vault, json!({"method":"sync.run"}));
    assert_eq!(status["gaps"], 0);
    assert_eq!(vault.list("hosts").unwrap().len(), 2);
}

#[test]
fn profile_activation_rebases_stale_ai_context_after_interrupted_commit() {
    let fixture = Fixture::new();
    let vault = crate::vault::Vault::open(&fixture.0.join("device"), None).unwrap();
    add_profile(&vault, "Selected", "cloud", "");
    put_ai(
        &vault,
        "providers",
        "first",
        json!({"id":"first","name":"First","kind":"openai"}),
    );
    local_request(&vault, json!({"method":"sync.run"}));
    let ai = runtime::ai_database(&vault).unwrap().unwrap();
    // Simulate the AI database retaining the old context after the main database
    // committed a switch. Cover both an old tagged context and a legacy one.
    for (id, context) in [
        (
            "tagged",
            json!({"_profile":"previous-profile","configuration":{"unrelated-writer":700}}),
        ),
        ("legacy", json!({"configuration":{"unrelated-writer":700}})),
    ] {
        journal::set_context(&ai, &context, true).unwrap();
        put_ai(
            &vault,
            "providers",
            id,
            json!({"id":id,"name":id,"kind":"openai"}),
        );
        let status = local_request(&vault, json!({"method":"sync.run"}));
        assert_eq!(status["gaps"], 0);
        let store = store::Store::new(&vault).unwrap();
        assert!(!store
            .state("configuration")
            .unwrap()
            .frontier
            .contains_key("unrelated-writer"));
        assert_eq!(get_ai(&vault, "providers", id)["name"], id);
    }
}

#[test]
fn progress_reports_real_transfers_failure_and_retry_without_secret_data() {
    let fixture = Fixture::new();
    let library = uuid::Uuid::new_v4().to_string();
    let a = fixture.peer("progress-a", &library);
    let b = fixture.peer("progress-b", &library);
    for i in 0..205 {
        a.save("hosts", host(&format!("private-host-{i}")), None)
            .unwrap();
    }
    b.save("hosts", host("offline-local-host"), None).unwrap();
    let sa = store::Store::new(&a).unwrap();
    let sb = store::Store::new(&b).unwrap();
    let mut cloud = MemoryCloud::default();
    let run = |vault: &crate::vault::Vault, store: &store::Store<'_>, cloud: &mut MemoryCloud| {
        progress::track(vault.directory.clone(), "sync.run", || {
            store.transaction(|| {
                store.drain(store.db)?;
                Ok(())
            })?;
            runtime::exchange(store, cloud)?;
            runtime::project_current(vault, store)?;
            Ok(json!({}))
        })
    };
    run(&a, &sa, &mut cloud).unwrap();
    let first = progress::read(&a.directory);
    assert_eq!(first["phase"], "completed");
    assert_eq!(first["percent"], 100);
    assert!(first["uploadedBytes"].as_u64().unwrap() > 0);
    assert_eq!(first["uploadedBytes"], first["verifiedBytes"]);
    cloud.fail_after_put = true;
    assert!(run(&b, &sb, &mut cloud).is_err());
    let failed = progress::read(&b.directory);
    assert_eq!(failed["phase"], "failed");
    assert_eq!(failed["active"], false);
    assert!(failed["downloadedBytes"].as_u64().unwrap() > 0);
    assert_ne!(failed["percent"], 100);
    assert!(!failed.to_string().contains("private-host"));
    assert!(!failed.to_string().contains("never-on-wire"));
    run(&b, &sb, &mut cloud).unwrap();
    let retried = progress::read(&b.directory);
    assert_ne!(retried["id"], failed["id"]);
    assert_eq!(retried["phase"], "completed");
    assert_eq!(b.list("hosts").unwrap().len(), 206);
    run(&b, &sb, &mut cloud).unwrap();
    let noop = progress::read(&b.directory);
    assert_eq!(noop["uploadedBytes"], 0);
    assert_eq!(noop["downloadedBytes"], 0);
    assert_eq!(noop["percent"], 100);
}

#[test]
fn progress_reads_do_not_wait_for_a_worker_or_database_transaction() {
    let fixture = Fixture::new();
    let vault = fixture.peer("progress-live", &uuid::Uuid::new_v4().to_string());
    let path = vault.directory.clone();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (finish_tx, finish_rx) = std::sync::mpsc::channel();
    let worker_path = path.clone();
    let worker = std::thread::spawn(move || {
        let db = rusqlite::Connection::open(worker_path.join("vault.sqlite")).unwrap();
        db.execute_batch("BEGIN EXCLUSIVE").unwrap();
        progress::track(worker_path, "sync.run", || {
            progress::stage("downloading", 2, Some(8));
            progress::bytes("downloadedBytes", 384 * 1024);
            ready_tx.send(()).unwrap();
            finish_rx.recv().unwrap();
            db.execute_batch("COMMIT").unwrap();
            Ok(json!({}))
        })
        .unwrap();
    });
    ready_rx
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    let start = std::time::Instant::now();
    let live = dispatch(&json!({"method":"sync.progress","directory":path}), None).unwrap();
    finish_tx.send(()).unwrap();
    worker.join().unwrap();
    assert!(start.elapsed() < std::time::Duration::from_secs(1));
    assert_eq!(live["active"], true);
    assert_eq!(live["percent"], 25);
    assert_eq!(live["downloadedBytes"], 384 * 1024);
    assert_eq!(progress::read(&path)["phase"], "completed");
}

#[test]
fn connection_check_is_readonly_and_does_not_wait_for_wal_writer() {
    let fixture = Fixture::new();
    let vault = fixture.peer("A", "readonly-check");
    let saved = vault.save("hosts", host("read only"), None).unwrap();
    let writer = rusqlite::Connection::open(vault.directory.join("vault.sqlite")).unwrap();
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();
    let started = std::time::Instant::now();
    let response = super::dispatch(&json!({"method":"sync.checkConnection", "directory":vault.directory, "host":saved}), None).unwrap();
    assert_eq!(response["allowed"], true);
    assert!(started.elapsed() < std::time::Duration::from_secs(1), "read-only check waited for the writer");
    writer.execute_batch("ROLLBACK").unwrap();
}

#[test]
fn connection_check_does_not_install_sync_tables() {
    let fixture = Fixture::new();
    let directory = fixture.0.join("no-sync");
    let vault = crate::vault::Vault::open(&directory, None).unwrap();
    let count = || vault.db.query_row("SELECT count(*) FROM sqlite_master", [], |row| row.get::<_, i64>(0)).unwrap();
    let before = count();
    let response = super::dispatch(&json!({"method":"sync.checkConnection", "directory":directory, "host":host("fixture")}), None).unwrap();
    assert_eq!(response["allowed"], true);
    assert_eq!(before, count());
    assert!(super::dispatch(&json!({"method":"sync.checkConnection", "directory":directory, "host":{}}), Some(&[0; 3])).is_err());
}

#[test]
fn connection_check_uses_native_database_and_key_paths_and_fails_closed() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(&fixture.0).unwrap();
    let database = fixture.0.join("native.sqlite");
    let key = fixture.0.join("native.key");
    std::fs::write(&key, [0u8; 32]).unwrap();
    let db = rusqlite::Connection::open(&database).unwrap();
    db.execute_batch("CREATE TABLE fixture (id INTEGER)").unwrap();
    let request = json!({"method":"sync.checkConnection", "directory":fixture.0,
        "databasePath":database, "keyPath":key, "host":{}});
    assert_eq!(super::dispatch(&request, None).unwrap()["allowed"], true);
    let mut invalid = request.clone();
    invalid["databasePath"] = json!("relative.sqlite");
    assert!(super::dispatch(&invalid, None).is_err());
    invalid["databasePath"] = json!(fixture.0.join("missing.sqlite"));
    assert!(super::dispatch(&invalid, None).is_err());
    std::fs::remove_file(key).unwrap();
    assert!(super::dispatch(&request, None).is_err());
}
