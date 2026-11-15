use super::*;
use crate::{model::Settings, store::Store, terminal::Hub};
use std::path::PathBuf;
use tokio::sync::mpsc;

struct Fixture {
    runtime: Arc<Runtime>,
    events: mpsc::Receiver<Value>,
    directory: PathBuf,
}
impl Fixture {
    fn new(mobile: bool) -> Self {
        let directory =
            std::env::temp_dir().join(format!("TermPilot-automation-{}", uuid::Uuid::new_v4()));
        let (events, receiver) = mpsc::channel(128);
        Self {
            runtime: Arc::new(Runtime {
                mobile,
                store: Mutex::new(Store::open(&directory).unwrap()),
                events,
                settings: Mutex::new(Settings::default()),
                context: Mutex::new(json!({"sessions":[]})),
                supported: vec![],
                runs: Mutex::new(HashMap::new()),
                pending: Mutex::new(HashMap::new()),
                lifetime: CancellationToken::new(),
                mcp: Mutex::new(None),
                terminal: Hub::default(),
                scripts: Scheduler::default(),
            }),
            events: receiver,
            directory,
        }
    }
    async fn script(&self, id: &str, trigger: &str, extra: Value) {
        let mut record = json!({"id":id,"kind":"script","label":id,"trigger":trigger,"content":"nct.log('fixture');","triggerPattern":"READY"});
        record
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        self.runtime
            .store
            .lock()
            .await
            .put("automation", id, &record)
            .unwrap();
    }
    async fn host(&self) -> Value {
        self.runtime.store.lock().await.vault().unwrap().save("hosts", json!({
            "label":"Fixture", "hostname":"fixture.invalid", "username":"fixture", "port":22,
            "authentication":"agent"
        }), None).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.runtime.lifetime.cancel();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[tokio::test]
async fn automatic_scripts_skip_local_temporary_and_nonterminal_sessions_on_all_clients() {
    for mobile in [false, true] {
        let f = Fixture::new(mobile);
        f.script(
            "global-connect",
            "onConnect",
            json!({"targetsAllHosts":true}),
        )
        .await;
        f.script("global-output", "onOutput", json!({"targetsAllHosts":true}))
            .await;
        let saved = f.host().await;
        for session in [
            json!({"sessionId":"mac-local","kind":"local","hostId":"00000000-0000-0000-0000-000000000001","connected":true}),
            json!({"sessionId":"quick","kind":"ssh","hostId":uuid::Uuid::new_v4().to_string(),"connected":true}),
            json!({"sessionId":"settings","kind":"settings","hostId":"settings","connected":false}),
            json!({"sessionId":"screen","kind":"screen","hostId":saved["id"],"connected":true}),
            json!({"sessionId":"rdp","kind":"rdp","hostId":saved["id"],"connected":true}),
            json!({"sessionId":"offline","kind":"ssh","hostId":saved["id"],"connected":false}),
        ] {
            assert!(
                automatic_connection_queue(&f.runtime, &session)
                    .await
                    .unwrap()
                    .is_empty(),
                "{session}"
            );
            *f.runtime.context.lock().await = json!({"sessions":[session.clone()]});
            f.runtime
                .scripts
                .feed(text(&session, "sessionId"), b"READY")
                .await;
            Scheduler::output_triggers(&f.runtime, text(&session, "sessionId"))
                .await
                .unwrap();
            assert!(f.runtime.scripts.queues.lock().await.is_empty());
        }
    }
}

#[tokio::test]
async fn saved_host_keeps_global_group_and_manual_script_order() {
    let f = Fixture::new(false);
    let mut host = f.host().await;
    {
        let store = f.runtime.store.lock().await;
        let vault = store.vault().unwrap();
        let group = vault
            .save("groups", json!({"name":"Fixtures"}), None)
            .unwrap();
        host["groupID"] = group["id"].clone();
        vault.save("hosts", host.clone(), None).unwrap();
        store
            .put("scriptQueues", text(&host, "id"), &json!(["host-script"]))
            .unwrap();
    }
    f.script("global", "onConnect", json!({"targetsAllHosts":true}))
        .await;
    f.script("group", "onConnect", json!({"targetGroups":["Fixtures"]}))
        .await;
    f.script("host-script", "onConnect", json!({"targets":[host["id"]]}))
        .await;
    f.script("manual-only", "manual", json!({"targetsAllHosts":true}))
        .await;
    for metadata in [
        json!({"sessionId":"desktop","hostId":host["id"],"kind":"ssh","connected":true}),
        json!({"sessionId":"legacy","hostId":host["id"]}),
    ] {
        let queue = automatic_connection_queue(&f.runtime, &metadata)
            .await
            .unwrap();
        assert_eq!(
            queue.iter().map(|v| text(v, "id")).collect::<Vec<_>>(),
            ["global", "group", "host-script"]
        );
    }
}

#[tokio::test]
async fn deleted_host_is_skipped_automatically_but_explicit_queue_edit_stays_strict() {
    let f = Fixture::new(false);
    let host = f.host().await;
    f.script("global", "onConnect", json!({"targetsAllHosts":true}))
        .await;
    f.script("output", "onOutput", json!({"targetsAllHosts":true}))
        .await;
    f.runtime
        .store
        .lock()
        .await
        .vault()
        .unwrap()
        .delete("hosts", &host["id"])
        .unwrap();
    let metadata = json!({"sessionId":"open-session","hostId":host["id"],"kind":"ssh"});
    assert!(automatic_connection_queue(&f.runtime, &metadata)
        .await
        .unwrap()
        .is_empty());
    *f.runtime.context.lock().await = json!({"sessions":[metadata]});
    Scheduler::output_triggers(&f.runtime, "open-session")
        .await
        .unwrap();
    assert!(resolved_queue(&f.runtime, text(&host, "id"))
        .await
        .unwrap_err()
        .to_string()
        .contains("Host not found"));
    let c = Conversation::new("fixture".into(), "automation".into());
    let result = execute(
        &f.runtime,
        &c,
        "host_connect_scripts_set",
        &json!({"hostId":host["id"],"scriptIds":"[]"}),
        &f.runtime.lifetime,
        None,
    )
    .await;
    assert!(result.unwrap_err().to_string().contains("Host not found"));
}

#[tokio::test]
async fn real_vault_failure_is_reported_as_session_scoped_automation_warning() {
    let mut f = Fixture::new(false);
    let host = f.host().await;
    f.script("global", "onConnect", json!({"targetsAllHosts":true}))
        .await;
    std::fs::write(
        f.directory.join("vault.sqlite"),
        b"corrupted fixture database",
    )
    .unwrap();
    let metadata =
        json!({"sessionId":"affected","scope":"affected-scope","hostId":host["id"],"kind":"ssh"});
    let context = json!({"sessions":[metadata]});
    *f.runtime.context.lock().await = context.clone();
    Scheduler::context_changed(&f.runtime, &json!({"sessions":[]}), &context).await;
    let event = tokio::time::timeout(Duration::from_secs(3), f.events.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(event["type"], "automationError");
    assert_eq!(event["sessionId"], "affected");
    assert_eq!(event["hostId"], host["id"]);
    assert_eq!(event["scope"], "affected-scope");
    assert_eq!(event["stage"], "onConnect");
    assert!(!text(&event, "message").is_empty());
    assert!(!f.runtime.lifetime.is_cancelled());
}

#[tokio::test]
async fn no_connection_scripts_does_not_require_a_host_lookup() {
    let f = Fixture::new(false);
    std::fs::write(
        f.directory.join("vault.sqlite"),
        b"unneeded fixture database",
    )
    .unwrap();
    let metadata = json!({"sessionId":"fixture","hostId":uuid::Uuid::new_v4().to_string()});
    assert!(automatic_connection_queue(&f.runtime, &metadata)
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn connection_transition_schedules_once_and_context_refresh_does_not_repeat() {
    let f = Fixture::new(true);
    let host = f.host().await;
    f.script("global", "onConnect", json!({"targetsAllHosts":true}))
        .await;
    // Hold the worker so this test observes scheduling without executing commands.
    f.runtime
        .scripts
        .draining
        .lock()
        .await
        .insert("mobile".into());
    let before = json!({"sessions":[{"sessionId":"mobile","hostId":host["id"],"kind":"ssh","connected":false}]});
    let after = json!({"sessions":[{"sessionId":"mobile","hostId":host["id"],"kind":"ssh","connected":true}]});
    Scheduler::context_changed(&f.runtime, &before, &after).await;
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if f.runtime
                .scripts
                .queues
                .lock()
                .await
                .get("mobile")
                .is_some_and(|q| !q.is_empty())
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    Scheduler::context_changed(&f.runtime, &after, &after).await;
    tokio::task::yield_now().await;
    assert_eq!(
        f.runtime.scripts.trigger_times.lock().await["mobile"].len(),
        1
    );
}
