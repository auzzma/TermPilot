//! Ephemeral, non-secret progress. Reading it never opens SQLite or waits for a
//! cloud request/transaction. Percentages describe the current phase, not time.
use super::Result;
use serde_json::{json, Value};
use std::{
    cell::RefCell,
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
};

type Progress = Arc<Mutex<Value>>;
static RUNS: OnceLock<Mutex<HashMap<PathBuf, Progress>>> = OnceLock::new();
thread_local! { static CURRENT: RefCell<Option<(PathBuf, Progress)>> = const { RefCell::new(None) }; }

pub(super) fn read(path: &Path) -> Value {
    let path = path.canonicalize().unwrap_or_else(|_| path.to_owned());
    let runs = RUNS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    runs.get(&path)
        .map(|p| p.lock().unwrap_or_else(|e| e.into_inner()).clone())
        .unwrap_or(Value::Null)
}

pub(super) fn track(
    path: PathBuf,
    method: &str,
    work: impl FnOnce() -> Result<Value>,
) -> Result<Value> {
    if !matches!(
        method,
        "sync.tick"
            | "sync.run"
            | "sync.configure"
            | "sync.profile.add"
            | "sync.profile.update"
            | "sync.profile.use"
            | "sync.invite.import"
            | "sync.snapshot"
            | "sync.snapshot.restore"
            | "sync.lock.inspect"
            | "sync.lock.recover"
            | "sync.restore"
    ) {
        return work();
    }
    let path = path.canonicalize().unwrap_or(path);
    let value = Arc::new(Mutex::new(
        json!({"id":uuid::Uuid::new_v4().to_string(), "active":false,
        "phase":"preparing", "completed":0, "total":null, "percent":null,
        "downloadedBytes":0, "uploadedBytes":0, "verifiedBytes":0}),
    ));
    CURRENT.with(|current| *current.borrow_mut() = Some((path, value)));
    struct Clear;
    impl Drop for Clear {
        fn drop(&mut self) {
            update(|p| {
                if p["active"] == true {
                    p["active"] = json!(false);
                    p["phase"] = json!("failed");
                    p["error"] = json!("同步工作已停止，请重试。");
                }
            });
            CURRENT.with(|current| *current.borrow_mut() = None);
        }
    }
    let _clear = Clear;
    if matches!(
        method,
        "sync.run"
            | "sync.configure"
            | "sync.profile.add"
            | "sync.profile.update"
            | "sync.profile.use"
            | "sync.invite.import"
            | "sync.snapshot"
            | "sync.snapshot.restore"
            | "sync.lock.inspect"
            | "sync.lock.recover"
            | "sync.restore"
    ) {
        stage("preparing", 0, None);
    }
    let result = work();
    update(|p| {
        if p["active"] != true {
            return;
        }
        p["active"] = json!(false);
        match &result {
            Ok(v) if v["synced"] != false => {
                p["phase"] = json!("completed");
                p["percent"] = json!(100);
                p["completed"] = json!(1);
                p["total"] = json!(1);
            }
            _ => {
                p["phase"] = json!("failed");
                p["error"] = match &result {
                    Err(e) => json!(e.message),
                    Ok(v) => v["error"].clone(),
                };
            }
        }
    });
    result
}

fn update(change: impl FnOnce(&mut Value)) {
    CURRENT.with(|current| {
        if let Some((_, value)) = current.borrow().as_ref() {
            change(&mut value.lock().unwrap_or_else(|e| e.into_inner()));
        }
    });
}

pub(super) fn stage(phase: &str, completed: usize, total: Option<usize>) {
    CURRENT.with(|current| {
        if let Some((path, value)) = current.borrow().as_ref() {
            RUNS.get_or_init(Default::default)
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(path.clone(), value.clone());
        }
    });
    update(|p| {
        p["active"] = json!(true);
        p["phase"] = json!(phase);
        p["completed"] = json!(completed);
        p["total"] = json!(total);
        p["percent"] = total
            .map(|n| {
                json!(if n == 0 {
                    100
                } else {
                    completed.min(n) * 100 / n
                })
            })
            .unwrap_or(Value::Null);
    });
}

pub(super) fn bytes(direction: &str, count: usize) {
    update(|p| {
        p[direction] = json!(p[direction]
            .as_u64()
            .unwrap_or(0)
            .saturating_add(count as u64));
    });
}
