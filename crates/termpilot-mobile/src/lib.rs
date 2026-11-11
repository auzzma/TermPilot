//! Native mobile entry point. Protocols remain in the same desktop Rust libraries.
#[cfg(target_os = "android")]
mod android;
mod events;
mod tools;
mod transfers;
use anyhow::{bail, ensure, Context, Result};
use events::{Events, Packet};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    sync::mpsc,
};
use zeroize::{Zeroize, Zeroizing};

static NEXT: AtomicU64 = AtomicU64::new(1);
static CLIENTS: OnceLock<Mutex<HashMap<u64, Arc<Client>>>> = OnceLock::new();
static EXECUTOR: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
fn executor() -> &'static tokio::runtime::Runtime {
    EXECUTOR.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .thread_name("TermPilot")
            .build()
            .expect("mobile runtime")
    })
}
fn clients() -> &'static Mutex<HashMap<u64, Arc<Client>>> {
    CLIENTS.get_or_init(Mutex::default)
}
fn client(id: u64) -> Result<Arc<Client>> {
    clients()
        .lock()
        .unwrap()
        .get(&id)
        .cloned()
        .context("Runtime is closed")
}
struct Session {
    tx: mpsc::Sender<Value>,
    terminal: Option<String>,
    kind: String,
}
impl Session {
    fn send(&self, command: Value) -> Result<()> {
        self.tx.try_send(command).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => {
                anyhow::anyhow!("Command queue is busy; retry after pending commands complete")
            }
            mpsc::error::TrySendError::Closed(_) => anyhow::anyhow!("Session is closed"),
        })
    }
}
pub struct Client {
    directory: PathBuf,
    key: Zeroizing<Vec<u8>>,
    transfer_lock: Mutex<()>,
    sessions: Mutex<HashMap<u64, Session>>,
    events: Arc<Events>,
}
impl Client {
    fn new(directory: PathBuf, key: &[u8]) -> Result<Arc<Self>> {
        // SSH/AI and RDP are linked into one process on mobile. They enable both
        // rustls providers; choose the same provider as the standalone RDP client.
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        ensure!(
            directory.is_absolute() && key.len() == 32,
            "Absolute data directory and 32-byte key required"
        );
        termpilot_core::vault::Vault::open_with_key(&directory, key)
            .map_err(|e| anyhow::anyhow!(e.message))?;
        termpilot_core::sync::dispatch(
            &json!({"method":"sync.recover","directory":directory}),
            Some(key),
        )
        .map_err(|e| anyhow::anyhow!(e.message))?;
        Ok(Arc::new(Self {
            directory,
            key: Zeroizing::new(key.to_vec()),
            transfer_lock: Mutex::new(()),
            sessions: Mutex::default(),
            events: Arc::new(Events::new()),
        }))
    }
    fn dispatch(self: &Arc<Self>, mut request: Value) -> Result<Value> {
        // Native mobile callers use the linked core's version. Set it before
        // routing so guarded paths (such as resolveConnection) carry it too.
        request["apiVersion"] = json!(termpilot_core::API_VERSION);
        let method = request["method"].as_str().unwrap_or("").to_owned();
        match method.as_str() {
            "capabilities" => Ok(
                json!({"version":1,"ssh":true,"sftp":true,"vnc":true,"rdp":true,"highPerformance":cfg!(any(target_os="ios",target_os="android")),"externalLocalAgents":false,"localShell":false,"backgroundPersistentConnections":false}),
            ),
            "session.open" => self.open(request),
            "mobile.serverTool" => tools::plan(&request),
            "mobile.transfers" | "mobile.transfer.save" | "mobile.transfer.delete" => {
                let _guard = self
                    .transfer_lock
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Transfer journal is unavailable"))?;
                transfers::dispatch(&self.directory, &request)
            }
            "session.send" => {
                let sessions = self.sessions.lock().unwrap();
                let session = sessions
                    .get(&request["session"].as_u64().unwrap_or(0))
                    .context("Session is closed")?;
                let mut command = request["command"].clone();
                if session.kind == "screen" && command["kind"] == "text" {
                    ensure!(
                        command["text"].as_str().is_some_and(|s| s.len() <= 65536),
                        "Text input limit"
                    );
                    command["kind"] = json!("mobileText");
                }
                // Desktop executables and shell-backed proxies are not mobile capabilities.
                if session.kind == "ai" {
                    validate_ai(&command)?;
                }
                session.send(command)?;
                Ok(json!({"queued":true}))
            }
            "session.close" => {
                let id = request["session"].as_u64().unwrap_or(0);
                let session = self.sessions.lock().unwrap().remove(&id);
                if let Some(s) = session {
                    if let Some(t) = s.terminal {
                        let _ = termpilot_core::terminal::dispatch(
                            &json!({"method":"terminal.close","id":t}),
                        );
                    }
                }
                Ok(json!({"closed":true}))
            }
            "lifecycle.background" => {
                // No automatic replay. iOS/Android adapters end sessions when their OS task expires.
                Ok(json!({"reconnectRequiresUserAction":true}))
            }
            "vault.prepareDirectory" => bail!("Mobile storage is managed by the app sandbox"),
            m if m.starts_with("vault.") => {
                request["directory"] = json!(self.directory);
                termpilot_core::vault::dispatch_with_key(&request, Some(&self.key))
                    .map_err(|e| anyhow::anyhow!(e.message))
            }
            m if m.starts_with("sync.") => {
                request["directory"] = json!(self.directory);
                termpilot_core::sync::dispatch(&request, Some(&self.key))
                    .map_err(|e| anyhow::anyhow!(e.message))
            }
            "resolveConnection" => {
                termpilot_core::sync::dispatch(&json!({"method":"sync.checkConnection","directory":self.directory,"host":request["host"]}),Some(&self.key)).map_err(|e|anyhow::anyhow!(e.message))?;
                termpilot_core::dispatch(&request).map_err(|e| anyhow::anyhow!(e.message))
            }
            _ => termpilot_core::dispatch(&request).map_err(|e| anyhow::anyhow!(e.message)),
        }
    }
    fn open(self: &Arc<Self>, request: Value) -> Result<Value> {
        let kind = request["protocol"].as_str().unwrap_or("ssh").to_owned();
        ensure!(
            ["ssh", "screen", "rdp", "ai"].contains(&kind.as_str()),
            "Unknown session protocol"
        );
        let mut sessions = self.sessions.lock().unwrap();
        ensure!(
            sessions.len() < 16,
            "Close an existing connection before opening another"
        );
        let mut initial = request["command"].clone();
        ensure!(initial.is_object(), "Connection command required");
        if kind == "ai" {
            initial["params"]["directory"] = json!(self.directory);
            // Imported desktop tool access must not open a listener on a phone.
            initial["params"]["mobile"] = json!(true);
        } else {
            ensure!(initial["config"]["authentication"] != "agent", "SSH Agent requires a desktop client; select a password or imported private-key credential");
            for config in [&initial, &initial["config"]] {
                for p in ["proxy", "proxyConfiguration"] {
                    ensure!(
                        !["command", "proxyCommand"]
                            .contains(&config[p]["kind"].as_str().unwrap_or(""))
                            && config[p]["type"] != "command"
                            && config[p]["command"].as_str().unwrap_or("").is_empty(),
                        "Executable proxies are unavailable on mobile; use SOCKS5 or HTTP CONNECT"
                    );
                }
            }
        }
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let terminal = if kind == "ssh" {
            Some(
                termpilot_core::terminal::dispatch(
                    &json!({"method":"terminal.create","rows":24,"columns":80}),
                )
                .map_err(|e| anyhow::anyhow!(e.message))?["id"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
            )
        } else {
            None
        };
        let (tx, mut rx) = mpsc::channel::<Value>(64);
        let replies = tx.downgrade();
        let terminal_replies = request["terminalReplies"].as_bool().unwrap_or(false);
        tx.try_send(initial)?;
        sessions.insert(
            id,
            Session {
                tx,
                terminal: terminal.clone(),
                kind: kind.clone(),
            },
        );
        let events = self.events.clone();
        let key = self.key.clone();
        let task_terminal = terminal.clone();
        executor().spawn(async move {
            let (native,engine)=tokio::io::duplex(256*1024);
            let (mut native_read,mut native_write)=tokio::io::split(native);
            let (engine_read,engine_write)=tokio::io::split(engine);
            let sender=tokio::spawn(async move {
                while let Some(command)=rx.recv().await {
                    if command["kind"] == "mobileText" {
                        for c in command["text"].as_str().unwrap_or("").chars() {
                            let key = match c {'\n'|'\r'=>0xff0d,'\t'=>0xff09,_ if (c as u32) <= 255 => c as u32,_=>0x01000000 | c as u32};
                            for down in [true, false] {
                                let mut bytes=serde_json::to_vec(&json!({"kind":"key","key":key,"down":down}))?;
                                bytes.push(b'\n');native_write.write_all(&bytes).await?;
                            }
                        }
                        continue;
                    }
                    let mut bytes=serde_json::to_vec(&command)?; bytes.push(b'\n');
                    native_write.write_all(&bytes).await?;
                    bytes.zeroize();
                }
                native_write.shutdown().await?;
                Ok::<_,anyhow::Error>(())
            });
            let result_events=events.clone();
            let binary=kind=="screen" || kind=="rdp";
            let mut receiver=tokio::spawn(async move {
                let mut reader=BufReader::new(&mut native_read);
                loop {
                    let (mut header,payload)=if binary {
                        let n=match reader.read_u32().await {Ok(n)=>n as usize,Err(e) if e.kind()==std::io::ErrorKind::UnexpectedEof=>break,Err(e)=>return Err(e.into())};
                        ensure!((2..=65536).contains(&n),"Invalid frame header");
                        let mut data=vec![0;n];reader.read_exact(&mut data).await?;
                        let length=termpilot_core::frame::validate_header(&data).map_err(|e|anyhow::anyhow!(e.message))?;
                        let header:Value=serde_json::from_slice(&data)?;
                        let mut payload=vec![0;length];reader.read_exact(&mut payload).await?;
                        (header,payload)
                    } else {
                        match termpilot_engine::ipc::read_json(&mut reader).await? { Some(v)=>(v,vec![]),None=>break }
                    };
                    if header["type"]=="data" {
                        if let Some(t)=&task_terminal {
                            if let Ok(fed) = termpilot_core::terminal::dispatch(&json!({"method":"terminal.feed","id":t,"data":header["data"]})) {
                                if terminal_replies && fed["reply"].as_str().is_some_and(|r| !r.is_empty()) {
                                    if let Some(tx) = replies.upgrade() {
                                        let _ = tx.send(json!({"type":"data","data":fed["reply"]})).await;
                                    }
                                }
                            }
                        }
                    }
                    header["session"]=json!(id);
                    events.push(Packet{header,payload}).await;
                }
                Ok::<_,anyhow::Error>(())
            });
            let result=match kind.as_str() {
                "ssh"=>termpilot_engine::worker::serve(engine_read,engine_write,None,None).await,
                "screen"=>termpilot_engine::screen::serve(engine_read,engine_write).await,
                "rdp"=>termpilot_rdp::serve(engine_read,engine_write).await,
                _=>termpilot_ai::serve_io(engine_read,engine_write,Some(key)).await,
            };
            sender.abort();
            if tokio::time::timeout(Duration::from_secs(3), &mut receiver).await.is_err() {
                receiver.abort();
            }
            result_events.push(Packet{header:json!({"session":id,"type":"sessionEnded","error":result.err().map(|e|e.to_string())}),payload:vec![]}).await;
        });
        Ok(json!({"session":id,"terminal":terminal}))
    }
    fn close(&self) {
        for (_, s) in self.sessions.lock().unwrap().drain() {
            if let Some(t) = s.terminal {
                let _ =
                    termpilot_core::terminal::dispatch(&json!({"method":"terminal.close","id":t}));
            }
        }
        self.events.close();
    }
}
fn validate_ai(command: &Value) -> Result<()> {
    let method = command["method"].as_str().unwrap_or("");
    ensure!(
        !method.starts_with("agent.install")
            && !method.starts_with("agent.login")
            && !method.starts_with("mcp.enable"),
        "This desktop operation is unavailable on mobile"
    );
    Ok(())
}
fn response(result: Result<Value>) -> String {
    match result {
        Ok(v) => json!({"ok":true,"value":v}),
        Err(e) => json!({"ok":false,"error":{"message":e.to_string()}}),
    }
    .to_string()
}
fn call(id: u64, bytes: &[u8]) -> String {
    response((|| {
        ensure!(
            bytes.len() <= termpilot_core::MAX_REQUEST,
            "Request too large"
        );
        client(id)?.dispatch(serde_json::from_slice(bytes).context("Invalid request")?)
    })())
}
/// # Safety
/// Directory is a NUL-terminated UTF-8 string; key points to 32 readable bytes.
#[no_mangle]
pub unsafe extern "C" fn tp_mobile_create(
    directory: *const c_char,
    key: *const u8,
    length: usize,
) -> u64 {
    std::panic::catch_unwind(|| {
        if directory.is_null() || key.is_null() || length != 32 {
            return 0;
        }
        let Ok(dir) = (unsafe { CStr::from_ptr(directory) }).to_str() else {
            return 0;
        };
        let Ok(c) = Client::new(PathBuf::from(dir), unsafe {
            std::slice::from_raw_parts(key, length)
        }) else {
            return 0;
        };
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        clients().lock().unwrap().insert(id, c);
        id
    })
    .unwrap_or(0)
}
/// # Safety
/// JSON points to length readable bytes. Free result with tp_mobile_free_string.
#[no_mangle]
pub unsafe extern "C" fn tp_mobile_call(id: u64, data: *const u8, length: usize) -> *mut c_char {
    let out = std::panic::catch_unwind(|| {
        if data.is_null() || length > termpilot_core::MAX_REQUEST {
            response(Err(anyhow::anyhow!("Invalid request")))
        } else {
            call(id, unsafe { std::slice::from_raw_parts(data, length) })
        }
    })
    .unwrap_or_else(|_| response(Err(anyhow::anyhow!("Runtime operation failed"))));
    CString::new(out).unwrap().into_raw()
}
/// # Safety
/// length is writable; returned buffer must be released with its exact length.
#[no_mangle]
pub unsafe extern "C" fn tp_mobile_poll(id: u64, timeout_ms: u32, length: *mut usize) -> *mut u8 {
    if length.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *length = 0;
    }
    let result = std::panic::catch_unwind(|| {
        client(id)
            .ok()?
            .events
            .poll(Duration::from_millis(timeout_ms.min(1000) as u64))
            .map(Packet::encode)
    })
    .ok()
    .flatten();
    match result {
        Some(bytes) => {
            let mut bytes = bytes.into_boxed_slice();
            unsafe {
                *length = bytes.len();
            }
            let p = bytes.as_mut_ptr();
            std::mem::forget(bytes);
            p
        }
        None => std::ptr::null_mut(),
    }
}
/// # Safety
/// value must be null or a live string allocated by this library, freed once.
#[no_mangle]
pub unsafe extern "C" fn tp_mobile_free_string(value: *mut c_char) {
    if !value.is_null() {
        let mut data = unsafe { CString::from_raw(value) }.into_bytes_with_nul();
        data.zeroize();
    }
}
/// # Safety
/// value/length must match a live tp_mobile_poll result, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn tp_mobile_free_buffer(value: *mut u8, length: usize) {
    if !value.is_null() {
        let mut data = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(value, length)) };
        data.zeroize();
    }
}
#[no_mangle]
pub extern "C" fn tp_mobile_destroy(id: u64) {
    if let Ok(mut all) = clients().lock() {
        if let Some(c) = all.remove(&id) {
            c.close();
        }
    }
}

#[cfg(test)]
mod session_tests {
    use super::*;

    #[test]
    fn closed_worker_is_not_reported_as_queue_pressure() {
        let (tx, rx) = mpsc::channel(1);
        let session = Session {
            tx,
            terminal: None,
            kind: "ssh".into(),
        };
        session.send(json!({"type":"resize"})).unwrap();
        assert!(session
            .send(json!({"type":"resize"}))
            .unwrap_err()
            .to_string()
            .contains("queue is busy"));
        drop(rx);
        assert_eq!(
            session
                .send(json!({"type":"resize"}))
                .unwrap_err()
                .to_string(),
            "Session is closed"
        );
    }
}
