use crate::{
    commands::AppServices,
    worker::{self, Worker},
};
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{atomic::Ordering, Arc},
};
use tauri::{AppHandle, Emitter, Manager, State};
#[derive(Default)]
pub struct AI {
    worker: Mutex<Option<Arc<Worker>>>,
    contexts: Arc<Mutex<HashMap<String, Value>>>,
}
impl AI {
    pub fn feed(&self, session: &str, data: &Value) {
        if let Some(w) = self.worker.lock().as_ref() {
            let _ = w.send(
                &json!({"method":"terminal.output","params":{"sessionId":session,"data":data}}),
            );
        }
    }
    pub fn close_window(&self, label: &str) {
        let sessions: Vec<Value> = {
            let mut contexts = self.contexts.lock();
            contexts.remove(label);
            contexts
                .values()
                .filter_map(|c| c["sessions"].as_array())
                .flatten()
                .cloned()
                .collect()
        };
        if let Some(w) = self.worker.lock().as_ref() {
            let _ = w.send(&json!({"method":"context.update","params":{"sessions":sessions}}));
        }
    }
    pub fn close(&self) {
        if let Some(w) = self.worker.lock().take() {
            w.close();
        }
    }
}
#[tauri::command]
pub async fn ai_request(
    app: AppHandle,
    window: tauri::WebviewWindow,
    state: State<'_, AI>,
    services: State<'_, AppServices>,
    method: String,
    params: Option<Value>,
) -> Result<Value, String> {
    let worker = {
        let mut slot = state.worker.lock();
        if slot
            .as_ref()
            .is_none_or(|w| !w.live.load(Ordering::Acquire))
        {
            let sink_app = app.clone();
            let contexts = state.contexts.clone();
            let w = Worker::spawn(
                &worker::engine_path(&app)?,
                "ai",
                Arc::new(move |v| {
                    if v["type"] == "toolRequest" {
                        let all = contexts.lock();
                        let owner = tool_owner(&all, &v);
                        let _ = sink_app.emit_to(owner.as_str(), "ai-event", v);
                    } else {
                        let _ = sink_app.emit("ai-event", v);
                    }
                }),
            )?;
            w.request(json!({"method":"initialize","params":{"directory":services.vault.directory,"context":{"sessions":[]},"tools":["host_open","session_close","portforward_start","portforward_stop","portforward_tunnels_list","terminal_execute","terminal_start","terminal_poll","terminal_stop","terminal_read_context","sftp_list","sftp_read_file","sftp_write_file","sftp_download","sftp_upload","sftp_stat","sftp_home","sftp_mkdir","sftp_delete","sftp_rename","sftp_chmod"]}}),false)?;
            *slot = Some(w);
        }
        slot.as_ref().unwrap().clone()
    };
    let mut params = params.unwrap_or(json!({}));
    if method == "context.update" {
        let mut contexts = state.contexts.lock();
        contexts.retain(|label, _| app.get_webview_window(label).is_some());
        contexts.insert(window.label().into(), params);
        let sessions: Vec<Value> = contexts
            .values()
            .filter_map(|c| c["sessions"].as_array())
            .flatten()
            .cloned()
            .collect();
        params = json!({"sessions":sessions});
    }
    tauri::async_runtime::spawn_blocking(move || {
        worker.request(json!({"method":method,"params":params}), false)
    })
    .await
    .map_err(|e| e.to_string())?
}
pub fn feed(app: &AppHandle, session: &str, data: &Value) {
    if let Some(ai) = app.try_state::<AI>() {
        ai.feed(session, data);
    }
}

fn tool_owner(contexts: &HashMap<String, Value>, event: &Value) -> String {
    let sid = event["payload"]["arguments"]["sessionId"].as_str();
    let scope = event["payload"]["scope"].as_str();
    contexts
        .iter()
        .find(|(_, context)| {
            context["sessions"].as_array().is_some_and(|sessions| {
                sessions.iter().any(|s| {
                    if let Some(sid) = sid {
                        s["sessionId"] == sid
                    } else {
                        scope.is_some() && s["scope"].as_str() == scope
                    }
                })
            })
        })
        .map(|(owner, _)| owner.clone())
        .unwrap_or_else(|| "main".into())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tools_execute_once_in_the_window_owning_the_target_session() {
        let contexts = HashMap::from([
            (
                "main".into(),
                json!({"sessions":[{"sessionId":"one","scope":"host:server"}]}),
            ),
            (
                "terminal-second".into(),
                json!({"sessions":[{"sessionId":"two","scope":"host:server"}]}),
            ),
        ]);
        assert_eq!(
            tool_owner(
                &contexts,
                &json!({"payload":{"scope":"host:server","arguments":{"sessionId":"two"}}})
            ),
            "terminal-second"
        );
        assert_eq!(
            tool_owner(
                &contexts,
                &json!({"payload":{"scope":"workspace","arguments":{}}})
            ),
            "main"
        );
    }
}
