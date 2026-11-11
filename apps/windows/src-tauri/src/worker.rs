//! Bounded private pipes to the shared Rust executable. No Node/Python, shell or secrets in argv.
use parking_lot::{Condvar, Mutex};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tauri::{AppHandle, Manager};
pub type Result<T> = std::result::Result<T, String>;
pub type Sink = Arc<dyn Fn(Value) + Send + Sync>;
type Reply = std::sync::mpsc::Sender<Result<Value>>;
#[derive(Default)]
struct FileChannelIdle {
    requests: usize,
    generation: u64,
    timer: Option<tauri::async_runtime::JoinHandle<()>>,
}
pub struct Worker {
    files_idle: Mutex<FileChannelIdle>,
    child: Mutex<Child>,
    input: Mutex<ChildStdin>,
    pub live: AtomicBool,
    deliver: AtomicBool,
    next: AtomicU64,
    pending: Mutex<HashMap<String, Reply>>,
    ready: Mutex<HashMap<String, Result<()>>>,
    changed: Condvar,
    transfers: Mutex<HashMap<String, u64>>,
    activity: Mutex<HashMap<String, Instant>>,
    channel_gate: Mutex<()>,
    paused: Mutex<HashSet<u64>>,
}
pub fn engine_path(app: &AppHandle) -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("TERMPILOT_ENGINE") {
        let p = PathBuf::from(path);
        if p.is_file() {
            return Ok(p);
        }
    }
    let name = if cfg!(windows) {
        "termpilot-engine.exe"
    } else {
        "termpilot-engine"
    };
    let mut paths = vec![
        std::env::current_exe()
            .map_err(err)?
            .parent()
            .unwrap()
            .join("engine")
            .join(name),
        app.path()
            .resource_dir()
            .map_err(err)?
            .join("engine")
            .join(name),
    ];
    #[cfg(debug_assertions)]
    paths.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../target/release")
            .join(name),
    );
    paths
        .into_iter()
        .find(|p| p.is_file())
        .ok_or("TermPilot Rust engine is missing from app/engine".into())
}
pub fn command(path: &std::path::Path, mode: &str) -> Command {
    let mut c = Command::new(path);
    c.arg(mode)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x08000000);
    }
    c
}
pub fn read_line(reader: &mut impl BufRead) -> Result<Option<Value>> {
    let mut data = Vec::new();
    let count = reader
        .take(64 * 1024 * 1024 + 1)
        .read_until(b'\n', &mut data)
        .map_err(err)?;
    if count == 0 {
        return Ok(None);
    }
    if data.len() > 64 * 1024 * 1024 || data.last() != Some(&b'\n') {
        return Err("Engine frame exceeds the limit or is truncated".into());
    }
    serde_json::from_slice(&data).map(Some).map_err(err)
}
impl Worker {
    pub fn spawn(path: &std::path::Path, mode: &str, sink: Sink) -> Result<Arc<Self>> {
        let mut child = command(path, mode).spawn().map_err(err)?;
        let input = child.stdin.take().ok_or("Missing engine input")?;
        let output = child.stdout.take().ok_or("Missing engine output")?;
        if let Some(mut stderr) = child.stderr.take() {
            std::thread::spawn(move || {
                let _ = std::io::copy(&mut stderr, &mut std::io::sink());
            });
        }
        let w = Arc::new(Self {
            files_idle: Mutex::default(),
            child: Mutex::new(child),
            input: Mutex::new(input),
            live: AtomicBool::new(true),
            deliver: AtomicBool::new(true),
            next: AtomicU64::new(1),
            pending: Mutex::new(HashMap::new()),
            ready: Mutex::new(HashMap::new()),
            changed: Condvar::new(),
            transfers: Mutex::new(HashMap::new()),
            activity: Mutex::new(HashMap::new()),
            channel_gate: Mutex::new(()),
            paused: Mutex::new(HashSet::new()),
        });
        let weak = Arc::downgrade(&w);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(output);
            let reason = loop {
                match read_line(&mut reader) {
                    Ok(Some(mut v)) => {
                        let Some(w) = weak.upgrade() else {
                            break "Session closed".into();
                        };
                        let kind = v["type"].as_str().unwrap_or("").to_string();
                        if kind == "sftpReady" || kind == "execReady" {
                            w.ready
                                .lock()
                                .insert(v["channel"].as_str().unwrap_or("files").into(), Ok(()));
                            w.changed.notify_all();
                        }
                        if kind == "log" && v["status"] == "connected" {
                            w.ready.lock().insert("connected".into(), Ok(()));
                            w.changed.notify_all();
                        }
                        if kind == "error" {
                            w.ready.lock().insert(
                                v["channel"].as_str().unwrap_or("connected").into(),
                                Err(v["message"].as_str().unwrap_or("Connection failed").into()),
                            );
                            w.changed.notify_all();
                        }
                        let message = if kind == "sftpResponse" {
                            &mut v["message"]
                        } else {
                            &mut v
                        };
                        if !message["id"].is_null() {
                            let id = id_string(&message["id"]);
                            if message["event"] == "progress" {
                                w.activity.lock().insert(id.clone(), Instant::now());
                                let transfer = w
                                    .transfers
                                    .lock()
                                    .iter()
                                    .find(|(_, n)| n.to_string() == id)
                                    .map(|(k, _)| k.clone());
                                if let Some(key) = transfer {
                                    message["transferKey"] = json!(key);
                                }
                            } else if let Some(sender) = w.pending.lock().remove(&id) {
                                let result = if message["ok"] == true {
                                    Ok(message["result"].clone())
                                } else {
                                    Err(message["error"]
                                        .as_str()
                                        .unwrap_or("Engine request failed")
                                        .into())
                                };
                                let _ = sender.send(result);
                                continue;
                            }
                        }
                        if w.deliver.load(Ordering::Acquire) {
                            sink(v);
                        }
                    }
                    Ok(None) => break "Connection ended".to_string(),
                    Err(e) => break e,
                }
            };
            if let Some(w) = weak.upgrade() {
                w.live.store(false, Ordering::Release);
                for (_, tx) in std::mem::take(&mut *w.pending.lock()) {
                    let _ = tx.send(Err(reason.clone()));
                }
                w.changed.notify_all();
                if w.deliver.load(Ordering::Acquire) {
                    sink(json!({"type":"exit","message":reason}));
                }
            }
        });
        Ok(w)
    }
    pub fn send(&self, v: &Value) -> Result<()> {
        let bytes = serde_json::to_vec(v).map_err(err)?;
        if bytes.len() > 16 * 1024 * 1024 {
            return Err("Input exceeds limit".into());
        }
        let mut input = self.input.lock();
        input
            .write_all(&bytes)
            .and_then(|_| input.write_all(b"\n"))
            .and_then(|_| input.flush())
            .map_err(err)
    }
    pub fn wait_ready(&self, channel: &str) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(150);
        let mut ready = self.ready.lock();
        loop {
            if let Some(r) = ready.get(channel) {
                return r.clone();
            }
            if !self.live.load(Ordering::Acquire) {
                return Err("Engine disconnected".into());
            }
            if Instant::now() >= deadline {
                return Err("Connection timed out".into());
            }
            self.changed
                .wait_for(&mut ready, Duration::from_millis(200));
        }
    }
    pub fn open_channel(&self, channel: &str, config: &Value) -> Result<()> {
        let _lock = self.channel_gate.lock();
        if self.ready.lock().get(channel).is_some_and(|v| v.is_ok()) {
            return Ok(());
        }
        self.ready.lock().remove(channel);
        self.send(&json!({"type":if channel=="exec"{"execOpen"}else{"sftpOpen"},"config":config}))?;
        self.wait_ready(channel)
    }
    pub fn request(&self, mut v: Value, transfer: bool) -> Result<Value> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = std::sync::mpsc::channel();
        let key = id.to_string();
        let request = if v["type"] == "sftpRequest" {
            &mut v["request"]
        } else {
            &mut v
        };
        if let Some(target) = request["transferKey"]
            .as_str()
            .and_then(|k| self.transfers.lock().get(k).copied())
        {
            request["targetID"] = json!(target);
            if request["action"] == "pause" {
                self.paused.lock().insert(target);
            }
            if request["action"] == "resume" {
                self.paused.lock().remove(&target);
                self.activity
                    .lock()
                    .insert(target.to_string(), Instant::now());
            }
        }
        request["id"] = json!(id);
        if transfer {
            if let Some(k) = request["transferKey"].as_str() {
                self.transfers.lock().insert(k.into(), id);
            }
            self.activity.lock().insert(key.clone(), Instant::now());
        }
        self.pending.lock().insert(key.clone(), tx);
        let result = (|| {
            self.send(&v)?;
            let started = Instant::now();
            loop {
                match rx.recv_timeout(Duration::from_secs(1)) {
                    Ok(r) => return r,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                        return Err("Engine disconnected".into())
                    }
                    Err(_) => {
                        let last = self.activity.lock().get(&key).copied().unwrap_or(started);
                        if (!transfer && started.elapsed() > Duration::from_secs(180))
                            || (transfer
                                && !self.paused.lock().contains(&id)
                                && last.elapsed() > Duration::from_secs(180))
                        {
                            let _=self.send(&json!({"type":"sftpRequest","channel":v["channel"],"request":{"id":self.next.fetch_add(1,Ordering::Relaxed),"action":"cancel","targetID":id}}));
                            return Err(
                                "Operation stopped after 180 seconds without progress".into()
                            );
                        }
                    }
                }
            }
        })();
        self.pending.lock().remove(&key);
        self.activity.lock().remove(&key);
        self.paused.lock().remove(&id);
        self.transfers.lock().retain(|_, n| *n != id);
        result
    }
    pub fn files_request(self: &Arc<Self>, config: &Value, frame: Value, transfer: bool, seconds: u64) -> Result<Value> {
        {
            let mut idle = self.files_idle.lock();
            idle.requests += 1;
            idle.generation += 1;
            if let Some(timer) = idle.timer.take() { timer.abort(); }
        }
        let result = self.open_channel("files", config).and_then(|_| self.request(frame, transfer));
        let mut idle = self.files_idle.lock();
        idle.requests -= 1;
        if idle.requests == 0 && seconds > 0 {
            let generation = idle.generation;
            let weak = Arc::downgrade(self);
            idle.timer = Some(tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_secs(seconds)).await;
                if let Some(worker) = weak.upgrade() {
                    let idle = worker.files_idle.lock();
                    if idle.requests == 0 && idle.generation == generation && worker.live.load(Ordering::Acquire) {
                        worker.ready.lock().remove("files");
                        let _ = worker.send(&json!({"type":"close","channel":"files"}));
                    }
                }
            }));
        }
        result
    }
    pub fn close(&self) {
        if let Some(timer) = self.files_idle.lock().timer.take() { timer.abort(); }
        self.deliver.store(false, Ordering::Release);
        self.live.store(false, Ordering::Release);
        let mut c = self.child.lock();
        let _ = c.kill();
        let _ = c.wait();
        self.changed.notify_all();
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.child.get_mut().kill();
        let _ = self.child.get_mut().wait();
    }
}
fn id_string(v: &Value) -> String {
    v.as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| v.to_string())
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parser_rejects_truncated_frames() {
        assert!(read_line(&mut std::io::Cursor::new(b"{\"x\":1}")).is_err());
        assert_eq!(
            read_line(&mut std::io::Cursor::new(b"{\"x\":1}\n")).unwrap(),
            Some(json!({"x":1}))
        );
    }
}
