use crate::{
    bridge::Connections,
    commands::AppServices,
    domain::Host,
    worker::{self, Worker},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BatchTarget {
    host: Host,
    elevation: String,
    elevation_password: Option<String>,
}

#[tauri::command]
pub fn batch_parse_targets(
    text: String,
    port: u16,
) -> Result<Vec<termpilot_core::batch::Endpoint>, String> {
    termpilot_core::batch::parse_targets(&text, port)
}
#[tauri::command]
pub fn batch_read_script(path: String) -> Result<String, String> {
    let meta = std::fs::metadata(&path).map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.len() > 128 * 1024 {
        return Err("Script must be a UTF-8 file up to 128 KiB".into());
    }
    std::fs::read_to_string(path).map_err(|e| e.to_string())
}
#[tauri::command]
pub fn batch_start(
    app: AppHandle,
    window: tauri::WebviewWindow,
    services: State<'_, AppServices>,
    connections: State<'_, Connections>,
    run_id: String,
    job: termpilot_core::batch::Job,
    targets: Vec<BatchTarget>,
    history_job_id: Option<String>,
    background_action: Option<String>,
    auto_accept_host_keys: Option<bool>,
) -> Result<(), String> {
    job.validate()?;
    if targets.is_empty() || targets.len() > 1000 {
        return Err("Select 1–1000 hosts".into());
    }
    let id = format!("batch:{run_id}");
    if connections.get(&id).is_some() {
        return Err("This batch is already running".into());
    }
    let resolved = targets
        .into_iter()
        .map(|target| {
            let mut config = services.vault.resolve(&target.host)?;
            config["autoAcceptHostKeys"] = json!(auto_accept_host_keys.unwrap_or(false));
            config["batchElevation"] = json!(target.elevation);
            config["batchCredentialId"] = json!(target.host.credential_id);
            config["batchProxyProfileId"] = json!(target.host.proxy_profile_id);
            if let Some(password) = target.elevation_password {
                config["elevationPassword"] = json!(password);
            }
            // Match existing sudo quick-fill, but never substitute the login
            // password for the root password used by su.
            if config["batchElevation"] == "sudo"
                && config["elevationPassword"]
                    .as_str()
                    .unwrap_or("")
                    .is_empty()
            {
                config["elevationPassword"] = config["password"].clone();
            }
            Ok(json!({"id":target.host.id,"config":config}))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let (handle, session_id) = (app.clone(), id.clone());
    let registry = connections.inner().clone();
    let owner = window.label().to_owned();
    let sink = Arc::new(move |mut v: Value| {
        if matches!(
            v["event"]["type"].as_str(),
            Some("hostKeyPrompt" | "credentialPrompt")
        ) {
            let mut prompt = v["event"].clone();
            prompt["sessionId"] = json!(session_id);
            prompt["targetId"] = v["targetId"].clone();
            prompt["ip"] = v["ip"].clone();
            let _ = handle.emit_to(owner.as_str(), "engine-prompt", prompt);
        }
        v["runId"] = json!(run_id);
        let ended = v["type"] == "exit";
        let _ = handle.emit_to(owner.as_str(), "batch-event", v);
        if ended {
            registry.close(&session_id);
        }
    });
    let w = Worker::spawn(&worker::engine_path(&app)?, "batch", sink)?;
    connections.register(&id, window.label(), w.clone());
    let request = json!({
        "job": job, "targets": resolved, "historyDirectory": services.vault.directory.join("batch-history"),
        "historyJobId": history_job_id.unwrap_or_default(), "backgroundAction": background_action.unwrap_or_default(),
    });
    if let Err(error) = w.send(&request) {
        connections.close(&id);
        return Err(error);
    }
    Ok(())
}
#[tauri::command]
pub fn batch_cancel(
    window: tauri::WebviewWindow,
    connections: State<'_, Connections>,
    run_id: String,
) -> Result<(), String> {
    if !connections.owns(&format!("batch:{run_id}"), window.label()) {
        return Err("Batch ended".into());
    }
    connections
        .get(&format!("batch:{run_id}"))
        .ok_or("Batch ended")?
        .send(&json!({"type":"cancel"}))
}
#[tauri::command]
pub fn batch_history(
    services: State<'_, AppServices>,
    job_id: Option<String>,
) -> Result<Value, String> {
    termpilot_core::batch::history(
        &services.vault.directory.join("batch-history"),
        job_id.as_deref(),
    )
}

#[tauri::command]
pub fn batch_save_csv(path: String, text: String) -> Result<(), String> {
    use std::{fs, io::Write, path::Path};
    let destination = Path::new(&path);
    if !destination.is_absolute()
        || !destination
            .extension()
            .is_some_and(|e| e.eq_ignore_ascii_case("csv"))
    {
        return Err("Choose a CSV file".into());
    }
    let temporary = destination.with_file_name(format!(".termpilot-{}.tmp", uuid::Uuid::new_v4()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|e| e.to_string())?;
    let result = file
        .write_all(text.as_bytes())
        .and_then(|_| file.sync_all());
    drop(file);
    let result = result.and_then(|_| fs::rename(&temporary, destination));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::batch_save_csv;
    use std::fs;

    #[test]
    fn csv_export_replaces_the_selected_file_and_preserves_utf8_bom() {
        let dir = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        fs::create_dir(&dir).unwrap();
        let path = dir.join("结果.CSV");
        fs::write(&path, "old").unwrap();
        let text = "\u{feff}\"主机 IP\",\"状态\"\r\n\"::1\",\"成功\"\r\n";
        batch_save_csv(path.to_string_lossy().into_owned(), text.into()).unwrap();
        assert_eq!(fs::read(&path).unwrap(), text.as_bytes());
        assert!(batch_save_csv(
            dir.join("bad.txt").to_string_lossy().into_owned(),
            "x".into()
        )
        .is_err());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        fs::remove_file(path).unwrap();
        fs::remove_dir(dir).unwrap();
    }
}

/// Storage always uses the application's vault directory and existing encryption key.
#[tauri::command]
pub fn batch_storage(window: tauri::WebviewWindow, services: State<'_, AppServices>, request: Value) -> Result<Value, String> {
    if request["operation"] == "workspace" {
        // Stable ordinal slots prevent separate application windows overwriting drafts.
        static SLOTS: std::sync::OnceLock<parking_lot::Mutex<std::collections::HashMap<String, usize>>> = std::sync::OnceLock::new();
        let mut slots = SLOTS.get_or_init(Default::default).lock();
        let next = slots.len();
        let slot = *slots.entry(window.label().to_owned()).or_insert(next);
        return Ok(json!({"workspace":format!("windows-{slot}")}));
    }
    services.vault.batch_storage(&request)
}
