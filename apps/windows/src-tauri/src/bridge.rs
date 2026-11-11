use crate::{
    commands::AppServices,
    domain::{Host, PortForwardRule},
    worker::{self, Worker},
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{atomic::Ordering, Arc},
};
use tauri::{AppHandle, Emitter, State};
#[derive(Clone, Default)]
pub struct Connections(
    pub Arc<Mutex<HashMap<String, Arc<Worker>>>>,
    Arc<Mutex<HashMap<String, String>>>,
);
impl Connections {
    pub fn register(&self, id: &str, owner: &str, worker: Arc<Worker>) {
        self.close(id);
        self.0.lock().insert(id.into(), worker);
        self.1.lock().insert(id.into(), owner.into());
    }
    pub fn owns(&self, id: &str, owner: &str) -> bool {
        self.1.lock().get(id).is_some_and(|label| label == owner)
    }
    pub fn get(&self, id: &str) -> Option<Arc<Worker>> {
        self.0
            .lock()
            .get(id)
            .filter(|w| w.live.load(Ordering::Acquire))
            .cloned()
    }
    pub fn close(&self, id: &str) {
        self.1.lock().remove(id);
        if let Some(w) = self.0.lock().remove(id) {
            w.close();
        }
    }
    pub fn close_window(&self, label: &str) {
        let ids: Vec<String> = self
            .1
            .lock()
            .iter()
            .filter(|(_, owner)| *owner == label)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            self.close(&id);
        }
    }
    pub fn close_all(&self) {
        self.1.lock().clear();
        for (_, w) in std::mem::take(&mut *self.0.lock()) {
            w.close();
        }
    }
}
fn sink(app: AppHandle, id: String, owner: String) -> worker::Sink {
    Arc::new(move |v| {
        let mut frame = v.clone();
        frame["sessionId"] = json!(id);
        match v["type"].as_str().unwrap_or("") {
            "data" => {
                crate::ai::feed(&app, &id, &v["data"]);
                let _ = app.emit("terminal-output", json!({"sessionId":id,"data":v["data"]}));
            }
            "log" | "cwd" | "user" => {
                let (status, message) = if v["type"] == "cwd" {
                    ("cwd", v["directory"].as_str().unwrap_or(""))
                } else if v["type"] == "user" {
                    ("user", v["username"].as_str().unwrap_or(""))
                } else {
                    (
                        v["status"].as_str().unwrap_or("status"),
                        v["message"].as_str().unwrap_or(""),
                    )
                };
                let text = format!("\x1e[ssh2:{status}] {message}\x1f");
                let _ = app.emit(
                    "terminal-output",
                    json!({"sessionId":id,"data":B64.encode(text)}),
                );
                if id.starts_with("forward:") && status == "connected" {
                    let _ = app.emit("forward-status", json!({"id":&id[8..],"status":"active"}));
                }
            }
            "hostKeyPrompt" | "credentialPrompt" => {
                let _ = app.emit_to(owner.as_str(), "engine-prompt", frame);
            }
            "sftpResponse" if v["message"]["event"] == "progress" => {
                let _ = app.emit("sftp-progress", &v["message"]);
            }
            "error" => {
                let _ = app.emit(
                    "terminal-error",
                    json!({"sessionId":id,"message":v["message"]}),
                );
                if id.starts_with("forward:") {
                    let _ = app.emit(
                        "forward-status",
                        json!({"id":&id[8..],"status":"error","error":v["message"]}),
                    );
                }
            }
            "exit" => {
                let _ = app.emit(
                    "terminal-exit",
                    json!({"sessionId":id,"exitCode":Value::Null}),
                );
                if id.starts_with("forward:") {
                    let _ = app.emit("forward-status", json!({"id":&id[8..],"status":"inactive"}));
                }
            }
            _ => {
                let _ = app.emit("engine-event", frame);
            }
        }
    })
}
pub fn start(
    app: &AppHandle,
    services: &AppServices,
    connections: &Connections,
    id: &str,
    host: &Host,
    mut first: Value,
    auto: bool,
    owner: &str,
) -> Result<Arc<Worker>, String> {
    let mut config = services.vault.resolve(host)?;
    config["sessionID"] = json!(id);
    config["autoAcceptHostKeys"] = json!(auto);
    first["config"] = config;
    let w = Worker::spawn(
        &worker::engine_path(app)?,
        "ssh",
        sink(app.clone(), id.into(), owner.into()),
    )?;
    connections.register(id, owner, w.clone());
    if let Err(e) = w.send(&first) {
        connections.close(id);
        return Err(e);
    }
    Ok(w)
}
#[tauri::command]
pub fn ssh_terminal_start(
    app: AppHandle,
    window: tauri::WebviewWindow,
    services: State<'_, AppServices>,
    connections: State<'_, Connections>,
    session_id: String,
    host: Host,
    columns: u16,
    rows: u16,
    auto_accept_host_keys: Option<bool>,
) -> Result<(), String> {
    start(
        &app,
        &services,
        &connections,
        &session_id,
        &host,
        json!({"type":"connect","cols":columns,"rows":rows}),
        auto_accept_host_keys.unwrap_or(false),
        window.label(),
    )
    .map(|_| ())
}
#[tauri::command]
pub fn engine_prompt_reply(
    window: tauri::WebviewWindow,
    connections: State<'_, Connections>,
    session_id: String,
    prompt_id: String,
    accepted: Option<bool>,
    value: Option<String>,
) -> Result<(), String> {
    if !connections.owns(&session_id, window.label()) { return Err("Wrong session owner".into()); }
    connections
        .get(&session_id)
        .ok_or("Session ended")?
        .send(&if let Some(accepted) = accepted {
            json!({"type":"hostKeyResponse","promptID":prompt_id,"accepted":accepted})
        } else {
            json!({"type":"credentialResponse","promptID":prompt_id,"value":value})
        })
}
#[tauri::command]
pub async fn sftp_request(
    app: AppHandle,
    window: tauri::WebviewWindow,
    services: State<'_, AppServices>,
    connections: State<'_, Connections>,
    host: Host,
    source_session_id: Option<String>,
    idle_seconds: Option<u64>,
    request: Value,
) -> Result<Value, String> {
    let id = source_session_id
        .clone()
        .unwrap_or_else(|| format!("files:{}:{}", window.label(), host.id));
    let mut config = services.vault.resolve(&host)?;
    config["fileProtocol"] = json!(host.sftp_file_protocol);
    config["filenameEncoding"] = json!(host.sftp_filename_encoding);
    let elevated_tools = (host.server_tools_use_root || host.sftp_uses_sudo)
        && config["username"].as_str() != Some("root");
    config["usesSudo"] = json!(elevated_tools
        && !matches!(host.sftp_file_protocol, crate::domain::SftpFileProtocol::Scp));
    config["persistentElevation"] = json!(elevated_tools);
    if elevated_tools
        && config["elevationPassword"].as_str().unwrap_or("").is_empty()
        && config["authentication"] == "password"
    {
        config["elevationPassword"] = config["password"].clone();
    }
    config["elevationMethod"] = json!(host.server_tools_elevation_method);
    let w = if let Some(w) = connections.get(&id) {
        if !connections.owns(&id, window.label()) { return Err("Wrong session owner".into()); }
        w
    } else {
        start(
            &app,
            &services,
            &connections,
            &id,
            &host,
            json!({"type":"execOpen"}),
            services.vault.auto_accept_ssh_host_keys()?,
            window.label(),
        )?
    };
    let channel = if matches!(request["action"].as_str(), Some("exec" | "systemInfo" | "systemMonitor")) {
        "exec"
    } else {
        "files"
    };
    let transfer = matches!(request["action"].as_str(), Some("upload" | "download"));
    tauri::async_runtime::spawn_blocking(move || {
        let frame = json!({"type":"sftpRequest","channel":channel,"request":request});
        if channel == "files" {
            return w.files_request(&config, frame, transfer, idle_seconds.unwrap_or(900).min(86400));
        }
        w.open_channel(channel, &config)?;
        w.request(frame, transfer)
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub fn sftp_close(
    window: tauri::WebviewWindow,
    connections: State<'_, Connections>,
    host_id: String,
    source_session_id: Option<String>,
) {
    if source_session_id.is_none() {
        connections.close(&format!("files:{}:{host_id}", window.label()));
    }
}
#[tauri::command]
pub async fn generate_credential_key(app: AppHandle, request: Value) -> Result<Value, String> {
    let path = worker::engine_path(&app)?;
    tauri::async_runtime::spawn_blocking(move || {
        use std::io::Write;
        let mut c = worker::command(&path, "keygen")
            .spawn()
            .map_err(|e| e.to_string())?;
        let mut input = c.stdin.take().ok_or("Missing input")?;
        writeln!(input, "{request}").map_err(|e| e.to_string())?;
        drop(input);
        let output = c.wait_with_output().map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Err("SSH key generation failed".into());
        }
        serde_json::from_slice(&output.stdout).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub fn forward_start(
    app: AppHandle,
    window: tauri::WebviewWindow,
    services: State<'_, AppServices>,
    connections: State<'_, Connections>,
    host: Host,
    mut rule: PortForwardRule,
    auto_accept_host_keys: bool,
) -> Result<(), String> {
    rule.validate().map_err(|e| e.to_string())?;
    let id = format!("forward:{}", rule.id);
    let _ = app.emit(
        "forward-status",
        json!({"id":rule.id,"status":"connecting"}),
    );
    start(
        &app,
        &services,
        &connections,
        &id,
        &host,
        json!({"type":"forwardOpen","forwardRule":rule}),
        auto_accept_host_keys,
        window.label(),
    )
    .map(|_| ())
}
#[tauri::command]
pub fn forward_stop(connections: State<'_, Connections>, id: String) {
    connections.close(&format!("forward:{id}"));
}
