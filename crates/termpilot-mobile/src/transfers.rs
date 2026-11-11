//! Durable, credential-free transfer ledger. Checkpoints live beside staged files;
//! restoring this ledger never connects or replays a transfer automatically.
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::{io::Write, path::Path};
const FIELDS: &[&str] = &[
    "id",
    "hostID",
    "label",
    "protocol",
    "name",
    "upload",
    "localPath",
    "remotePath",
    "resumeDirectory",
    "status",
    "total",
    "transferred",
    "error",
    "updated",
];
pub fn dispatch(root: &Path, r: &Value) -> Result<Value> {
    let path = root.join("transfers.json");
    let mut rows: Vec<Value> = if path.exists() {
        ensure!(
            std::fs::metadata(&path)?.len() < 4 * 1024 * 1024,
            "Transfer history limit"
        );
        serde_json::from_slice(&std::fs::read(&path)?)?
    } else {
        vec![]
    };
    let method = r["method"].as_str().unwrap_or("");
    if method == "mobile.transfers" {
        if r["recover"] == true {
            for row in &mut rows {
                if matches!(row["status"].as_str(), Some("active" | "paused")) {
                    row["status"] = json!("interrupted");
                }
            }
        } else {
            return Ok(json!({"items":rows}));
        }
    } else if method == "mobile.transfer.save" {
        let id = r["item"]["id"].as_str().unwrap_or("");
        ensure!(!id.is_empty() && id.len() < 128, "Invalid task ID");
        let mut row = serde_json::Map::new();
        for key in FIELDS {
            if let Some(v) = r["item"].get(key) {
                row.insert((*key).into(), v.clone());
            }
        }
        let value = Value::Object(row);
        ensure!(value.to_string().len() < 16384, "Transfer record limit");
        rows.retain(|v| v["id"] != id);
        rows.insert(0, value);
        if rows.len() > 500 {
            rows.truncate(500);
        }
    } else {
        let id = &r["id"];
        rows.retain(|v| &v["id"] != id);
    }
    let temp = root.join("transfers.json.new");
    let mut options = std::fs::OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temp)?;
    file.write_all(&serde_json::to_vec(&rows)?)?;
    file.sync_all()?;
    #[cfg(not(target_os = "windows"))]
    std::fs::rename(&temp, &path)?;
    #[cfg(target_os = "windows")]
    {
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
        std::fs::rename(&temp, &path)?;
    }
    Ok(json!({"items":rows}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovered_tasks_do_not_resume_or_store_secrets() {
        let root = std::env::temp_dir().join(format!("tp-ledger-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        dispatch(&root,&json!({"method":"mobile.transfer.save","item":{"id":"one","status":"active","password":"never-save","privateKey":"never-save"}})).unwrap();
        let r = dispatch(&root, &json!({"method":"mobile.transfers","recover":true})).unwrap();
        assert_eq!(r["items"][0]["status"], "interrupted");
        assert!(r["items"][0].get("password").is_none());
        std::fs::remove_dir_all(root).unwrap();
    }
}
