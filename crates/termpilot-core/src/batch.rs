//! Shared batch-job contract. Credentials are resolved by native vault adapters,
//! never embedded in reusable job definitions or reports.
use crate::connection::CoreError;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashSet},
    net::{IpAddr, SocketAddr},
    path::Path,
};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Endpoint {
    pub hostname: String,
    pub port: u16,
}

pub fn parse_targets(input: &str, port: u16) -> Result<Vec<Endpoint>, String> {
    if port == 0 {
        return Err("SSH port must be between 1 and 65535".into());
    }
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for token in input
        .split(|c: char| c.is_whitespace() || c == ',' || c == ';')
        .filter(|s| !s.is_empty())
    {
        let (ip, p) = if let Ok(ip) = token.parse::<IpAddr>() {
            (ip, port)
        } else if let Ok(address) = token.parse::<SocketAddr>() {
            (address.ip(), address.port())
        } else {
            return Err(format!("Invalid IP address or IP:port: {token}"));
        };
        if p == 0 {
            return Err("SSH port must be between 1 and 65535".into());
        }
        if seen.insert((ip, p)) {
            result.push(Endpoint {
                hostname: ip.to_string(),
                port: p,
            });
        }
        if result.len() > 1000 {
            return Err("A batch supports at most 1000 hosts".into());
        }
    }
    Ok(result)
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct Script {
    pub body: String,
    pub shell: String,
    pub cwd: String,
    pub args: Vec<String>,
    pub environment: BTreeMap<String, String>,
    /// Empty inherits the target's elevation; otherwise none/sudo/su.
    pub elevation: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct Job {
    pub kind: String,
    pub execution_mode: String,
    pub concurrency: usize,
    pub connect_timeout: u64,
    pub step_timeout: u64,
    pub stop_on_failure: bool,
    pub script: Script,
    pub before: Script,
    pub after: Script,
    pub cleanup_policy: String,
    pub local_paths: Vec<String>,
    pub remote_directory: String,
    pub overwrite: String,
    pub file_mode: String,
    pub directory_mode: String,
    pub recursive_permissions: bool,
    pub owner: String,
    pub group: String,
    pub remote_paths: Vec<String>,
    pub local_directory: String,
    /// A retained legacy workspace for explicit download-only retries.
    /// Current jobs always finalize their workspace; direct-file retries create a new one.
    pub remote_work_directory: String,
    pub source_task_id: String,
}
impl Default for Job {
    fn default() -> Self {
        Self {
            kind: "execute".into(),
            execution_mode: "foreground".into(),
            concurrency: 5,
            connect_timeout: 120,
            step_timeout: 600,
            stop_on_failure: false,
            script: Script::default(),
            before: Script::default(),
            after: Script::default(),
            cleanup_policy: "success".into(),
            local_paths: vec![],
            remote_directory: String::new(),
            overwrite: "skip".into(),
            file_mode: "0644".into(),
            directory_mode: "0755".into(),
            recursive_permissions: false,
            owner: String::new(),
            group: String::new(),
            remote_paths: vec![],
            local_directory: String::new(),
            remote_work_directory: String::new(),
            source_task_id: String::new(),
        }
    }
}
fn plain(value: &str) -> bool {
    !value.contains('\0')
}
/// Only one generated directory directly below /tmp may be reused or removed.
/// The old prefix is accepted for explicitly selected historical retries.
pub fn is_managed_work_directory(path: &str) -> bool {
    ["/tmp/ssh-batch-", "/tmp/termpilot-batch-"]
        .iter()
        .find_map(|prefix| path.strip_prefix(prefix))
        .is_some_and(|suffix| {
            uuid::Uuid::parse_str(suffix).is_ok_and(|id| id.hyphenated().to_string() == suffix)
        })
}
pub fn mode(value: &str) -> Result<u32, String> {
    if value.is_empty() || value.len() > 4 || !value.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
        return Err("Permissions must be octal, for example 0644 or 0755".into());
    }
    u32::from_str_radix(value, 8).map_err(|_| "Invalid permissions".into())
}
impl Job {
    pub fn validate(&self) -> Result<(), String> {
        if !["execute", "upload", "collect", "check"].contains(&self.kind.as_str()) {
            return Err("Invalid batch kind".into());
        }
        if !["foreground", "background"].contains(&self.execution_mode.as_str())
            || (self.execution_mode == "background" && self.kind != "execute")
        {
            return Err("Background execution is available for commands and scripts only".into());
        }
        if !(1..=32).contains(&self.concurrency)
            || !(10..=600).contains(&self.connect_timeout)
            || self.step_timeout > 86400
        {
            return Err("Invalid concurrency or timeout".into());
        }
        if !["success", "failure", "always"].contains(&self.cleanup_policy.as_str()) {
            return Err("Invalid cleanup policy".into());
        }
        for s in [&self.script, &self.before, &self.after] {
            if s.body.len() > 128 * 1024
                || !plain(&s.body)
                || !plain(&s.cwd)
                || (!s.shell.is_empty() && (!s.shell.starts_with('/') || !plain(&s.shell)))
                || !["", "none", "sudo", "su"].contains(&s.elevation.as_str())
                || s.args.iter().any(|s| !plain(s))
            {
                return Err("Invalid script, interpreter, argument or elevation".into());
            }
            for (k, v) in &s.environment {
                if k.is_empty()
                    || k.starts_with(|c: char| c.is_ascii_digit())
                    || !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                    || !plain(v)
                    || ["TASK_ID", "HOST_IP", "REMOTE_WORK_DIR"].contains(&k.as_str())
                {
                    return Err("Invalid or reserved environment variable".into());
                }
            }
        }
        if self.kind == "execute" && self.script.body.trim().is_empty() {
            return Err("Enter a command or script".into());
        }
        if self.kind == "upload" {
            if self.local_paths.is_empty()
                || self.local_paths.len() > 1000
                || self
                    .local_paths
                    .iter()
                    .any(|p| !Path::new(p).is_absolute() || !plain(p))
            {
                return Err("Select local files or directories".into());
            }
            if !self.remote_directory.starts_with('/') || !plain(&self.remote_directory) {
                return Err("An absolute remote directory is required".into());
            }
            if !["skip", "overwrite", "backup"].contains(&self.overwrite.as_str()) {
                return Err("Invalid overwrite policy".into());
            }
            mode(&self.file_mode)?;
            mode(&self.directory_mode)?;
            for s in [&self.owner, &self.group] {
                if !s
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_-.".contains(c))
                    || s.starts_with('-')
                {
                    return Err("Invalid owner or group".into());
                }
            }
        }
        if self.kind == "collect" {
            if self.remote_paths.is_empty()
                || self.remote_paths.len() > 1000
                || self.remote_paths.iter().any(|p| {
                    (!p.starts_with('/') && !p.starts_with("${REMOTE_WORK_DIR}/"))
                        || !plain(p)
                        || p.ends_with('/')
                })
            {
                return Err("Enter absolute file paths (one per line); directories must be archived in preparation".into());
            }
            if !Path::new(&self.local_directory).is_absolute() || !plain(&self.local_directory) {
                return Err("Select a local collection directory".into());
            }
        }
        if !self.remote_work_directory.is_empty()
            && (self.kind != "collect" || !is_managed_work_directory(&self.remote_work_directory))
        {
            return Err("Invalid retry work directory".into());
        }
        if !self.source_task_id.is_empty()
            && (self.kind != "collect" || uuid::Uuid::parse_str(&self.source_task_id).is_err())
        {
            return Err("Invalid source task ID".into());
        }
        Ok(())
    }
    pub fn should_cleanup(&self, success: bool) -> bool {
        !self.after.body.trim().is_empty()
            && (self.cleanup_policy == "always" || (self.cleanup_policy == "success") == success)
    }
}

/// A portable filename component. Preserve extensions, avoid Windows reserved
/// names, path traversal, IPv6 colons, and UTF-8 truncation.
pub fn component(value: &str) -> String {
    let mut s: String = value
        .chars()
        .map(|c| {
            if c.is_control() || "<>:\"/\\|?*".contains(c) {
                '_'
            } else {
                c
            }
        })
        .take(140)
        .collect();
    while s.len() > 100 {
        s.pop();
    }
    s = s.trim_matches([' ', '.']).to_string();
    if s.is_empty() {
        s = "file".into();
    }
    let stem = s.split('.').next().unwrap_or("").to_ascii_uppercase();
    if [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]
    .contains(&stem.as_str())
    {
        s.insert(0, '_');
    }
    s
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackgroundTask {
    pub target_id: String,
    pub remote_task_id: String,
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub credential_id: Option<String>,
    pub proxy_profile_id: Option<String>,
    pub elevation: String,
}

pub fn background_tasks(directory: &Path, id: &str) -> Result<Vec<BackgroundTask>, String> {
    uuid::Uuid::parse_str(id).map_err(|_| "Invalid history ID")?;
    let parent = directory.join(id);
    if std::fs::symlink_metadata(&parent)
        .map_err(|e| e.to_string())?
        .file_type()
        .is_symlink()
    {
        return Err("History links are not supported".into());
    }
    let path = parent.join("background.json");
    let metadata = match std::fs::symlink_metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        value => value.map_err(|e| e.to_string())?,
    };
    if !metadata.is_file() || metadata.len() > 2 * 1024 * 1024 {
        return Err("Invalid background history".into());
    }
    let tasks: Vec<BackgroundTask> =
        serde_json::from_slice(&std::fs::read(path).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    if tasks.is_empty()
        || tasks.len() > 1000
        || tasks.iter().any(|t| {
            uuid::Uuid::parse_str(&t.remote_task_id).is_err()
                || !["none", "sudo", "su"].contains(&t.elevation.as_str())
        })
    {
        return Err("Invalid background history".into());
    }
    Ok(tasks)
}

/// Read only job UUIDs below the caller's application data directory.
pub fn history(directory: &Path, job_id: Option<&str>) -> Result<Value, String> {
    if let Some(id) = job_id {
        uuid::Uuid::parse_str(id).map_err(|_| "Invalid history ID")?;
        let path = directory.join(id).join("events.jsonl");
        if std::fs::symlink_metadata(&path)
            .map_err(|e| e.to_string())?
            .file_type()
            .is_symlink()
        {
            return Err("History links are not supported".into());
        }
        use std::io::{BufRead, BufReader};
        let reader = BufReader::new(std::fs::File::open(path).map_err(|e| e.to_string())?);
        let mut events = std::collections::VecDeque::new();
        let mut conflicts: BTreeMap<(String, String), Value> = BTreeMap::new();
        let mut results: BTreeMap<String, Value> = BTreeMap::new();
        let mut checks: BTreeMap<(String, String), Value> = BTreeMap::new();
        let mut steps: BTreeMap<(String, String, String), Value> = BTreeMap::new();
        for line in reader.lines() {
            let line = line.map_err(|e| e.to_string())?;
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                let target = value["targetId"].as_str().unwrap_or("").to_string();
                let key = (
                    target.clone(),
                    value["remotePath"].as_str().unwrap_or("").to_string(),
                );
                if value["stage"] == "conflict" {
                    conflicts.insert(key.clone(), value.clone());
                }
                if value["stage"] == "upload" && value["status"] != "running" {
                    if let Some(c) = conflicts.get_mut(&key) {
                        c["status"] = value["status"].clone();
                        c["backupPath"] = value["backupPath"].clone();
                    }
                }
                if value["type"] == "batchHost"
                    && matches!(
                        value["stage"].as_str(),
                        Some("connect" | "authenticate" | "elevation" | "finished")
                    )
                {
                    checks.insert(
                        (target.clone(), value["stage"].as_str().unwrap().to_string()),
                        value.clone(),
                    );
                }
                if value["type"] == "batchHost" {
                    let step_key = (
                        target.clone(),
                        value["stage"].as_str().unwrap_or("").to_owned(),
                        value["stepId"]
                            .as_str()
                            .or_else(|| value["remotePath"].as_str())
                            .unwrap_or("")
                            .to_owned(),
                    );
                    let step = steps.entry(step_key).or_insert_with(|| json!({}));
                    if let (Some(old), Some(new)) = (step.as_object_mut(), value.as_object()) {
                        old.extend(new.clone());
                    }
                }
                if value["stage"] == "finished" {
                    results.insert(target, value.clone());
                }
                events.push_back(value);
                if events.len() > 3000 {
                    events.pop_front();
                }
            }
        }
        return Ok(
            json!({"backgroundTasks":background_tasks(directory, id)?,"historyJobId":id,"events":events,"conflicts":conflicts.into_values().collect::<Vec<_>>(),"results":results.into_values().collect::<Vec<_>>(),"checks":checks.into_values().collect::<Vec<_>>(),"steps":steps.into_values().collect::<Vec<_>>(),"reportDirectory":directory.join(id)}),
        );
    }
    let mut jobs = vec![];
    if directory.exists() {
        for entry in std::fs::read_dir(directory).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let id = entry.file_name().to_string_lossy().into_owned();
            if uuid::Uuid::parse_str(&id).is_ok()
                && entry.file_type().map_err(|e| e.to_string())?.is_dir()
            {
                let time = entry
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                jobs.push(json!({"id":id,"time":time,"background":entry.path().join("background.json").is_file(),"directory":entry.path()}));
            }
        }
    }
    jobs.sort_by_key(|v| std::cmp::Reverse(v["time"].as_u64().unwrap_or(0)));
    // A long-lived background task must remain recoverable even after many
    // newer foreground jobs. Background receipts are retained until removed.
    let mut foreground = 0;
    jobs.retain(|job| {
        if job["background"] == true {
            true
        } else {
            foreground += 1;
            foreground <= 100
        }
    });
    Ok(json!({"jobs":jobs}))
}
pub fn dispatch(v: &Value) -> Result<Value, CoreError> {
    let result = match v["method"].as_str().unwrap_or("") {
        "batch.storageSchema" => return Ok(json!({"schema":crate::vault::batch_library::SCHEMA})),
        "batch.validateConfiguration" => return Ok(json!({"configuration":crate::vault::batch_library::configuration(v["configuration"].as_str().unwrap_or(""))?})),
        "batch.parseTargets" => parse_targets(
            v["text"].as_str().unwrap_or(""),
            v["port"].as_u64().filter(|p| *p <= 65535).unwrap_or(0) as u16,
        )
        .map(|targets| json!({"targets":targets})),
        "batch.history" => history(
            Path::new(v["directory"].as_str().unwrap_or("")),
            v["jobId"].as_str(),
        ),
        "batch.validate" => serde_json::from_value::<Job>(v["job"].clone())
            .map_err(|_| "Invalid job definition".to_string())
            .and_then(|job| job.validate().map(|_| json!({"valid":true}))),
        _ => Err("Unknown batch operation".into()),
    };
    Ok(result.unwrap_or_else(|s| json!({"valid":false,"error":s})))
}

#[cfg(test)]
mod tests {
    #[test]
    fn background_mode_is_opt_in_and_does_not_apply_to_file_operations() {
        let mut job: super::Job =
            serde_json::from_value(serde_json::json!({"kind":"execute","script":{"body":"true"}}))
                .unwrap();
        assert_eq!(job.execution_mode, "foreground");
        job.execution_mode = "background".into();
        assert!(job.validate().is_ok());
        job.kind = "collect".into();
        assert!(job
            .validate()
            .unwrap_err()
            .contains("commands and scripts only"));
    }

    use super::*;
    #[test]
    fn work_directory_requires_one_exact_generated_uuid() {
        let id = "a6e2a19e-6902-428d-bbcf-c50e9e85ace1";
        for prefix in ["/tmp/ssh-batch-", "/tmp/termpilot-batch-"] {
            let path = format!("{prefix}{id}");
            assert!(is_managed_work_directory(&path));
            for suffix in ["/", "/child", "/../other", "-extra"] {
                assert!(!is_managed_work_directory(&format!("{path}{suffix}")));
            }
        }
        for path in [
            "/tmp",
            "/tmp/ssh-batch-",
            "/tmp/ssh-batch-abc",
            "/tmp/ssh-batch-../../etc",
            "/tmp/other",
        ] {
            assert!(!is_managed_work_directory(path));
        }
        let mut job = Job {
            kind: "check".into(),
            remote_work_directory: format!("/tmp/ssh-batch-{id}"),
            ..Default::default()
        };
        assert!(job.validate().is_err());
        job.kind = "collect".into();
        job.remote_paths = vec!["/var/log/example".into()];
        job.local_directory = std::env::temp_dir().to_string_lossy().into();
        assert!(job.validate().is_ok());
    }
    #[test]
    fn targets_deduplicate_and_validate_ports_and_ipv6() {
        let t = parse_targets("10.0.0.1\n10.0.0.1:22, [::1]:2222;::1", 22).unwrap();
        assert_eq!(t.len(), 3);
        assert_eq!(t[1].port, 2222);
        assert!(parse_targets("10.0.0.1:0", 22).is_err());
        assert!(parse_targets("10.0.0.1; touch /tmp/x", 22).is_err());
    }
    #[test]
    fn zero_disables_only_the_step_timeout() {
        let mut j = Job::default();
        j.script.body = "id".into();
        j.step_timeout = 0;
        assert!(j.validate().is_ok());
        j.connect_timeout = 0;
        assert!(j.validate().is_err());
        j.connect_timeout = 120;
        j.step_timeout = 86401;
        assert!(j.validate().is_err());
    }
    #[test]
    fn cleanup_is_conditional() {
        let mut j = Job::default();
        j.after.body = "cleanup".into();
        assert!(j.should_cleanup(true));
        assert!(!j.should_cleanup(false));
        j.cleanup_policy = "failure".into();
        assert!(!j.should_cleanup(true));
        assert!(j.should_cleanup(false));
        j.cleanup_policy = "always".into();
        assert!(j.should_cleanup(true));
        assert!(j.should_cleanup(false));
    }
    #[test]
    fn unsafe_inputs_are_rejected_and_names_portable() {
        assert_eq!(component("../CON"), "_CON");
        assert_eq!(component("fe80::1"), "fe80__1");
        assert!(mode("0999").is_err());
        let mut j = Job::default();
        j.script.body = "id".into();
        assert!(j.validate().is_ok());
        j.script.environment.insert("X;touch".into(), "bad".into());
        assert!(j.validate().is_err());
    }
    #[test]
    fn histories_keep_conflicts_and_host_results_beyond_output_limit() {
        use std::io::Write;
        let root =
            std::env::temp_dir().join(format!("termpilot-history-test-{}", uuid::Uuid::new_v4()));
        let id = uuid::Uuid::new_v4().to_string();
        let directory = root.join(&id);
        std::fs::create_dir_all(&directory).unwrap();
        let mut file = std::fs::File::create(directory.join("events.jsonl")).unwrap();
        for value in [
            json!({"stage":"conflict","targetId":"first","remotePath":"/x","policy":"backup","status":"detected"}),
            json!({"stage":"upload","targetId":"first","remotePath":"/x","status":"success","backupPath":"/x.backup"}),
            json!({"type":"batchHost","stage":"authenticate","targetId":"first","status":"success"}),
            json!({"type":"batchHost","stage":"elevation","targetId":"first","status":"success"}),
            json!({"type":"batchHost","stage":"finished","targetId":"first","status":"success"}),
            json!({"type":"batchHost","stage":"collect","targetId":"first","stepId":"collect-0","remotePath":"/log","status":"running","localPath":"/saved/first.log"}),
            json!({"type":"batchHost","stage":"collect","targetId":"first","stepId":"collect-0","remotePath":"/log","status":"success"}),
            json!({"type":"batchHost","stage":"collect","targetId":"first","stepId":"collect-1","remotePath":"/log","status":"success","localPath":"/saved/second.log"}),
        ] {
            writeln!(file, "{value}").unwrap();
        }
        for n in 0..4000 {
            writeln!(
                file,
                "{}",
                json!({"stage":"execute","targetId":n.to_string()})
            )
            .unwrap();
        }
        drop(file);
        let read = history(&root, Some(&id)).unwrap();
        assert_eq!(read["events"].as_array().unwrap().len(), 3000);
        assert_eq!(read["conflicts"][0]["status"], "success");
        assert_eq!(read["conflicts"][0]["backupPath"], "/x.backup");
        assert_eq!(read["results"][0]["targetId"], "first");
        assert_eq!(read["checks"].as_array().unwrap().len(), 3);
        let steps = read["steps"].as_array().unwrap();
        assert_eq!(steps.len(), 5);
        let first = steps.iter().find(|s| s["stepId"] == "collect-0").unwrap();
        assert_eq!(first["status"], "success");
        assert_eq!(first["localPath"], "/saved/first.log");
        assert_eq!(read["reportDirectory"], directory.to_str().unwrap());
        assert!(history(&root, Some("../../outside")).is_err());
        std::fs::remove_dir_all(root).unwrap();
        assert!(component(&"中文".repeat(100)).len() <= 100);
    }
    #[test]
    fn background_receipts_remain_accessible_beyond_foreground_history_limit() {
        let root =
            std::env::temp_dir().join(format!("termpilot-recovery-test-{}", uuid::Uuid::new_v4()));
        let id = uuid::Uuid::new_v4().to_string();
        let directory = root.join(&id);
        std::fs::create_dir_all(&directory).unwrap();
        let task = json!({"targetId":"original","remoteTaskId":uuid::Uuid::new_v4().to_string(),"hostname":"192.0.2.1","port":22,"username":"ops","credentialId":"vault-reference","elevation":"sudo"});
        std::fs::write(
            directory.join("background.json"),
            json!([task.clone()]).to_string(),
        )
        .unwrap();
        std::fs::write(directory.join("events.jsonl"), "").unwrap();
        for _ in 0..105 {
            std::fs::create_dir(root.join(uuid::Uuid::new_v4().to_string())).unwrap();
        }
        let listed = history(&root, None).unwrap();
        assert_eq!(listed["jobs"].as_array().unwrap().len(), 101);
        assert!(listed["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|j| j["id"] == id && j["background"] == true));
        let loaded = history(&root, Some(&id)).unwrap();
        assert_eq!(
            loaded["backgroundTasks"][0]["remoteTaskId"],
            task["remoteTaskId"]
        );
        assert_eq!(
            loaded["backgroundTasks"][0]["credentialId"],
            "vault-reference"
        );
        assert!(loaded["backgroundTasks"][0]["password"].is_null());
        std::fs::remove_dir_all(root).unwrap();
    }
}
