//! Encrypted incremental synchronization shared by all TermPilot clients.
mod control;
mod digest_auth;
mod invite;
pub mod journal;
pub mod model;
pub mod policy;
mod profiles;
mod progress;
mod projection;
mod qr;
mod rekey;
#[cfg(test)]
mod rekey_tests;
mod runtime;
pub mod store;
#[cfg(test)]
mod tests;
pub mod transport;

use crate::connection::CoreError;
use serde_json::Value;
pub type Result<T> = std::result::Result<T, CoreError>;
pub(crate) fn err(code: &'static str, message: &'static str) -> CoreError {
    CoreError::new(code, message)
}
pub(crate) fn db_error(_error: rusqlite::Error) -> CoreError {
    #[cfg(test)]
    if let rusqlite::Error::SqliteFailure(code, message) = &_error {
        eprintln!("Sync SQLite failure: {code:?} {message:?}");
    }
    err("syncDatabase", "同步事务未完成；数据已保留，稍后可重试。")
}
pub fn dispatch(request: &Value, key: Option<&[u8]>) -> Result<Value> {
    // A local, read-only policy check does not construct reqwest or a Tokio runtime.
    // Keep the synchronous API contract without spawning and joining a thread.
    if request["method"] == "sync.checkConnection" {
        return runtime::dispatch(request, key);
    }
    if request["method"] == "sync.qr.decode" {
        return qr::decode(request);
    }
    // Independent profiles/replicas must not block each other. Serialize only the
    // network/projection worker for a single vault; SQLite serializes local edits.
    use std::sync::{Arc, Mutex, OnceLock, Weak};
    static RUNNING: OnceLock<
        Mutex<std::collections::HashMap<std::path::PathBuf, Weak<Mutex<()>>>>,
    > = OnceLock::new();
    let path = std::path::PathBuf::from(request["directory"].as_str().unwrap_or(""));
    let path = path.canonicalize().unwrap_or(path);
    if request["method"] == "sync.progress" {
        return Ok(progress::read(&path));
    }
    let running = {
        let mut locks = RUNNING
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| err("syncBusy", "同步正在进行。"))?;
        locks.retain(|_, lock| lock.strong_count() > 0);
        let lock = locks
            .get(&path)
            .and_then(Weak::upgrade)
            .unwrap_or_else(|| Arc::new(Mutex::new(())));
        locks.insert(path.clone(), Arc::downgrade(&lock));
        lock
    };
    let _guard = if !matches!(
        request["method"].as_str(),
        Some(
            "sync.prepare"
                | "sync.status"
                | "sync.describe"
                | "sync.preferences"
                | "sync.checkConnection"
        )
    ) {
        Some(
            running
                .try_lock()
                .map_err(|_| err("syncBusy", "同步正在进行。"))?,
        )
    } else {
        None
    };
    // reqwest's blocking client owns a runtime; keep it outside callers' Tokio runtimes.
    std::thread::scope(|scope| {
        scope
            .spawn(|| {
                progress::track(path, request["method"].as_str().unwrap_or(""), || {
                    runtime::dispatch(request, key)
                })
            })
            .join()
            .unwrap_or_else(|_| Err(err("syncInternal", "同步未完成，本机数据已保留。")))
    })
}
