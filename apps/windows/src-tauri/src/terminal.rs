use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::thread;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use parking_lot::Mutex;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::{AppHandle, Emitter, State};

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalLaunch {
    pub session_id: String,
    pub program: String,
    #[serde(default)]
    pub arguments: Vec<String>,
    pub working_directory: Option<String>,
    #[serde(default = "default_columns")]
    pub columns: u16,
    #[serde(default = "default_rows")]
    pub rows: u16,
    #[serde(default)]
    pub environment: HashMap<String, String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TerminalOutputPayload {
    session_id: String,
    data: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TerminalExitPayload {
    session_id: String,
    exit_code: Option<u32>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TerminalErrorPayload {
    session_id: String,
    message: String,
}

pub struct TerminalManager {
    sessions: Mutex<HashMap<String, Arc<TerminalProcess>>>,
}

struct TerminalProcess {
    live: Arc<AtomicBool>,
    owner: String,
    master: Option<Mutex<Box<dyn MasterPty + Send>>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: TerminalKiller,
    framed_input: bool,
}

enum TerminalKiller {
    Pty(Mutex<Box<dyn ChildKiller + Send + Sync>>),
}

impl Default for TerminalManager {
    fn default() -> Self {
        Self {
            sessions: Mutex::new(HashMap::new()),
        }
    }
}

impl TerminalManager {
    pub fn start(
        &self,
        app: AppHandle,
        owner: String,
        launch: TerminalLaunch,
    ) -> Result<(), String> {
        if self.sessions.lock().contains_key(&launch.session_id) {
            return Ok(());
        }

        let pair = native_pty_system()
            .openpty(PtySize {
                rows: launch.rows.max(2),
                cols: launch.columns.max(2),
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(error_message)?;

        let mut command = CommandBuilder::new(&launch.program);
        command.args(&launch.arguments);
        if let Some(directory) = &launch.working_directory {
            command.cwd(directory);
        }
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
        command.env("TERM_PROGRAM", "TermPilot");
        for (key, value) in &launch.environment {
            command.env(key, value);
        }

        let mut child = pair.slave.spawn_command(command).map_err(error_message)?;
        let killer = child.clone_killer();
        let mut reader = pair.master.try_clone_reader().map_err(error_message)?;
        let writer = pair.master.take_writer().map_err(error_message)?;
        drop(pair.slave);

        let live = Arc::new(AtomicBool::new(true));
        self.sessions.lock().insert(
            launch.session_id.clone(),
            Arc::new(TerminalProcess {
                live: live.clone(),
                owner,
                master: Some(Mutex::new(pair.master)),
                writer: Mutex::new(writer),
                killer: TerminalKiller::Pty(Mutex::new(killer)),
                framed_input: false,
            }),
        );

        let output_live = live.clone();
        let output_app = app.clone();
        let output_session_id = launch.session_id.clone();
        thread::spawn(move || {
            let mut buffer = [0_u8; 16 * 1024];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        if !output_live.load(Ordering::Acquire) {
                            break;
                        }
                        let _ = output_app.emit(
                            "terminal-output",
                            TerminalOutputPayload {
                                session_id: output_session_id.clone(),
                                data: BASE64.encode(&buffer[..count]),
                            },
                        );
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(error) => {
                        if !output_live.load(Ordering::Acquire) {
                            break;
                        }
                        let _ = output_app.emit(
                            "terminal-error",
                            TerminalErrorPayload {
                                session_id: output_session_id.clone(),
                                message: error.to_string(),
                            },
                        );
                        break;
                    }
                }
            }
        });

        let exit_session_id = launch.session_id;
        thread::spawn(move || {
            let status = child.wait();
            if !live.load(Ordering::Acquire) {
                return;
            }
            let _ = app.emit(
                "terminal-exit",
                TerminalExitPayload {
                    session_id: exit_session_id,
                    exit_code: status.ok().map(|value| value.exit_code()),
                },
            );
        });
        Ok(())
    }

    fn write(&self, session_id: &str, encoded: &str) -> Result<(), String> {
        let process = self
            .sessions
            .lock()
            .get(session_id)
            .cloned()
            .ok_or_else(|| "terminal session does not exist".to_string())?;
        let mut writer = process.writer.lock();
        if process.framed_input {
            serde_json::to_writer(&mut *writer, &json!({ "type": "data", "data": encoded }))
                .map_err(error_message)?;
            writer.write_all(b"\n").map_err(error_message)?;
        } else {
            let bytes = BASE64.decode(encoded).map_err(error_message)?;
            writer.write_all(&bytes).map_err(error_message)?;
        }
        writer.flush().map_err(error_message)
    }

    fn resize_process(
        process: Arc<TerminalProcess>,
        columns: u16,
        rows: u16,
    ) -> Result<(), String> {
        if !process.live.load(Ordering::Acquire) {
            return Ok(());
        }
        if process.framed_input {
            let mut writer = process.writer.lock();
            serde_json::to_writer(
                &mut *writer,
                &json!({
                    "type": "resize",
                    "columns": columns.max(2),
                    "rows": rows.max(2),
                }),
            )
            .map_err(error_message)?;
            writer.write_all(b"\n").map_err(error_message)?;
            return writer.flush().map_err(error_message);
        }
        let result = process
            .master
            .as_ref()
            .ok_or_else(|| "terminal PTY is unavailable".to_string())?
            .lock()
            .resize(PtySize {
                rows: rows.max(2),
                cols: columns.max(2),
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(error_message);
        result
    }

    fn terminate(&self, session_id: &str) -> Result<(), String> {
        if let Some(process) = self.sessions.lock().remove(session_id) {
            kill_terminal_process(&process)?;
        }
        Ok(())
    }

    pub fn close_window(&self, owner: &str) {
        let ids: Vec<String> = self
            .sessions
            .lock()
            .iter()
            .filter(|(_, p)| p.owner == owner)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            let _ = self.terminate(&id);
        }
    }
    pub fn terminate_all(&self) {
        let sessions = std::mem::take(&mut *self.sessions.lock());
        for (_, process) in sessions {
            let _ = kill_terminal_process(&process);
        }
    }
}

fn kill_terminal_process(process: &TerminalProcess) -> Result<(), String> {
    process.live.store(false, Ordering::Release);
    match &process.killer {
        TerminalKiller::Pty(killer) => killer.lock().kill().map_err(error_message),
    }
}

#[tauri::command]
pub fn terminal_start(
    app: AppHandle,
    window: tauri::WebviewWindow,
    state: State<'_, TerminalManager>,
    launch: TerminalLaunch,
) -> Result<(), String> {
    state.start(app, window.label().into(), launch)
}

#[tauri::command]
pub fn terminal_write(
    state: State<'_, TerminalManager>,
    connections: State<'_, crate::bridge::Connections>,
    session_id: String,
    data: String,
) -> Result<(), String> {
    if let Some(w) = connections.get(&session_id) {
        w.send(&json!({"type":"data","data":data}))
    } else {
        state.write(&session_id, &data)
    }
}

#[tauri::command]
pub async fn terminal_resize(
    state: State<'_, TerminalManager>,
    connections: State<'_, crate::bridge::Connections>,
    session_id: String,
    columns: u16,
    rows: u16,
) -> Result<(), String> {
    // Capture this process generation before moving pipe/ConPTY work off the UI
    // thread, so a late resize cannot affect a replacement session with this ID.
    let remote = connections.get(&session_id);
    let process = state.sessions.lock().get(&session_id).cloned();
    tauri::async_runtime::spawn_blocking(move || {
        if let Some(w) = remote {
            w.send(&json!({"type":"resize","cols":columns,"rows":rows}))
        } else {
            TerminalManager::resize_process(
                process.ok_or("terminal session does not exist")?,
                columns,
                rows,
            )
        }
    })
    .await
    .map_err(|e| format!("Terminal resize worker failed: {e}"))?
}

#[tauri::command]
pub fn terminal_terminate(
    state: State<'_, TerminalManager>,
    connections: State<'_, crate::bridge::Connections>,
    session_id: String,
) -> Result<(), String> {
    connections.close(&session_id);
    state.terminate(&session_id)
}

fn default_columns() -> u16 {
    80
}

fn default_rows() -> u16 {
    24
}

fn error_message(error: impl std::fmt::Display) -> String {
    error.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_pty_runs_a_real_process() {
        let pair = native_pty_system()
            .openpty(PtySize::default())
            .expect("open PTY");
        #[cfg(unix)]
        let mut command = CommandBuilder::new("/bin/sh");
        #[cfg(windows)]
        let mut command = CommandBuilder::new("powershell.exe");
        #[cfg(windows)]
        command.args([
            "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
            // Test PTY input/output without PSReadLine's interactive VT/Win32
            // input negotiation; this harness is not a terminal emulator.
            "$value = [Console]::ReadLine(); [Console]::WriteLine('termpilot-' + $value)",
        ]);
        #[cfg(unix)]
        command.arg("-i");
        let mut child = pair.slave.spawn_command(command).expect("spawn shell");
        let mut reader = pair.master.try_clone_reader().expect("reader");
        let mut writer = pair.master.take_writer().expect("writer");
        drop(pair.slave);
        pair.master
            .resize(PtySize {
                cols: 120,
                rows: 40,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("resize");
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut buf = [0; 4096];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let _ = tx.send(String::from_utf8_lossy(&buf[..n]).into_owned());
            }
        });
        #[cfg(unix)]
        let input = b"printf 'termpilot-%s\\n' 'pty-ok'; exit\n".as_slice();
        #[cfg(windows)]
        let input = b"pty-ok\r\n".as_slice();
        writer.write_all(input).expect("input");
        writer.flush().expect("flush");
        let until = std::time::Instant::now() + std::time::Duration::from_secs(20);
        let mut output = String::new();
        while std::time::Instant::now() < until {
            if let Ok(chunk) = rx.recv_timeout(std::time::Duration::from_millis(100)) {
                output.push_str(&chunk);
                #[cfg(windows)]
                if chunk.contains("\x1b[6n") {
                    writer.write_all(b"\x1b[1;1R").expect("cursor report");
                    writer.flush().expect("cursor report flush");
                }
                if output.contains("termpilot-pty-ok") {
                    break;
                }
            }
        }
        let observed = output.contains("termpilot-pty-ok");
        drop(writer);
        let _ = child.kill();
        let _ = child.wait();
        drop(pair.master);
        assert!(observed, "PTY did not produce expected output: {output:?}");
    }
}
