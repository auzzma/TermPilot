use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use std::io::Write;
use termpilot_core::batch::BackgroundTask;

const RUNNER: &str = include_str!("runner.py");

pub(super) struct Run {
    pub tasks: Vec<BackgroundTask>,
    pub(super) action: String,
    report: PathBuf,
}

pub(super) fn prepare(request: &Request, job_id: &str, report: &Path) -> Result<Option<Arc<Run>>> {
    let resume = !request.background_action.is_empty();
    if !resume && request.job.execution_mode != "background" {
        return Ok(None);
    }
    let tasks = if resume {
        let saved = termpilot_core::batch::background_tasks(&request.history_directory, job_id)
            .map_err(anyhow::Error::msg)?;
        ensure!(!saved.is_empty(), "No background tasks in this history");
        for target in &request.targets {
            let task = saved
                .iter()
                .find(|t| t.target_id == target.id)
                .context("Target is not in this background history")?;
            ensure!(
                task.hostname
                    .eq_ignore_ascii_case(text(&target.config, "hostname"))
                    && u64::from(task.port) == target.config["port"].as_u64().unwrap_or(22)
                    && task.username == text(&target.config, "username"),
                "Reconnect using the original host and login account"
            );
        }
        saved
    } else {
        let tasks: Vec<_> = request
            .targets
            .iter()
            .map(|target| BackgroundTask {
                target_id: target.id.clone(),
                remote_task_id: uuid::Uuid::new_v4().to_string(),
                hostname: text(&target.config, "hostname").into(),
                port: target.config["port"].as_u64().unwrap_or(22) as u16,
                username: text(&target.config, "username").into(),
                credential_id: target.config["batchCredentialId"]
                    .as_str()
                    .map(str::to_owned),
                proxy_profile_id: target.config["batchProxyProfileId"]
                    .as_str()
                    .map(str::to_owned),
                elevation: if request.job.script.elevation.is_empty() {
                    text(&target.config, "batchElevation").into()
                } else {
                    request.job.script.elevation.clone()
                },
            })
            .collect();
        // Write and fsync the recovery receipt before any remote command is sent.
        let mut file = private_file(&report.join("background.json"))?;
        serde_json::to_writer(&mut file, &tasks)?;
        file.sync_all()?;
        tasks
    };
    Ok(Some(Arc::new(Run {
        tasks,
        action: if resume {
            request.background_action.clone()
        } else {
            "submit".into()
        },
        report: report.to_path_buf(),
    })))
}

fn command(action: &str, id: &str) -> String {
    format!("command -v python3 >/dev/null 2>&1 || {{ printf '%s\\n' 'Background execution requires Python 3.8+ on the remote host' >&2; exit 127; }}; exec python3 -c {} {} {} -", q(RUNNER), q(action), q(id))
}

async fn remote(
    session: &Session,
    action: &str,
    task: &BackgroundTask,
    payload: Value,
    options: &Value,
    timeout: u64,
    cancel: &CancellationToken,
) -> Result<Value> {
    let input = format!("{}\n", STANDARD.encode(serde_json::to_vec(&payload)?));
    let marker = format!("__TERMPILOT_BATCH_INPUT_{}__\n", task.remote_task_id);
    let response = session
        .exec_cancellable_with_input(
            &command(action, &task.remote_task_id),
            Duration::from_secs(timeout),
            options,
            cancel,
            &marker,
            input.as_bytes(),
        )
        .await?;
    let value = text(&response, "stdout")
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok());
    ensure!(
        response["exitCode"] == 0,
        "{}",
        value
            .as_ref()
            .and_then(|v| v["error"].as_str())
            .unwrap_or(text(&response, "stderr"))
    );
    let value = value.context("Background runner returned no status")?;
    ensure!(value["error"].is_null(), "{}", text(&value, "error"));
    Ok(value)
}

pub(super) async fn run_host(
    job: Arc<Job>,
    target: Target,
    job_id: String,
    events: Events,
    prompts: Prompts,
    cancel: CancellationToken,
    run: Arc<Run>,
) -> bool {
    let task = run
        .tasks
        .iter()
        .find(|t| t.target_id == target.id)
        .expect("validated background target");
    let (raw, mut rx) = mpsc::channel(64);
    let (e, t) = (events.clone(), target.clone());
    let relay = tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            if ipc::event(&e, json!({"type":"batchEvent","targetId":t.id,"ip":text(&t.config,"hostname"),"event":event})).await.is_err() { break; }
        }
    });
    let mut stage = "authenticate";
    let _ = host_event(&events, &target, stage, json!({"status":"running"})).await;
    let connected = tokio::select! {
        _ = cancel.cancelled() => Err(anyhow!("Stopped observing background tasks")),
        result = tokio::time::timeout(Duration::from_secs(job.connect_timeout), Session::connect(target.config.clone(), raw, prompts)) => result.context("Connection timed out").and_then(|r| r),
    };
    let result = match connected {
        Err(error) => Err(error),
        Ok(session) => {
            let _ = host_event(
                &events,
                &target,
                stage,
                json!({"status":"success","message":""}),
            )
            .await;
            stage = "elevation";
            let password = if task.elevation == "sudo"
                && text(&target.config, "elevationPassword").is_empty()
            {
                &target.config["password"]
            } else {
                &target.config["elevationPassword"]
            };
            let options = json!({"elevated":task.elevation!="none","elevationMethod":task.elevation,"elevationPassword":password});
            let operation = async {
                let check = session.exec_cancellable("id -u", Duration::from_secs(job.connect_timeout), &options, &cancel).await?;
                ensure!(check["exitCode"] == 0, "Elevation failed: {}", text(&check, "stderr"));
                host_event(&events, &target, "elevation", json!({"status":"success","message":""})).await?;
                stage = "execute";
                let payload = json!({"script":job.script,"timeout":job.step_timeout,"jobId":job_id,"ip":task.hostname});
                let action = if run.action == "logs" { "status" } else { &run.action };
                let mut value = remote(&session, action, task, payload, &options, job.connect_timeout, &cancel).await?;
                if run.action == "cancel" {
                    for _ in 0..25 {
                        if !["pending", "running"].contains(&text(&value, "status")) { break; }
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        value = remote(&session, "status", task, json!({}), &options, job.connect_timeout, &cancel).await?;
                    }
                }
                if run.action == "logs" {
                    for stream in ["stdout", "stderr"] {
                        let path = download_log(&session, task, stream, &options, &job, &cancel, &run.report, &secret_values(std::slice::from_ref(&target))).await?;
                        host_event(&events, &target, "logs", json!({"status":"success","stepId":stream,"localPath":path,"background":true})).await?;
                    }
                }
                Ok::<_, anyhow::Error>(value)
            }.await;
            session.close().await;
            operation
        }
    };
    relay.abort();
    let _ = relay.await;
    match result {
        Ok(mut value) => {
            value["background"] = json!(true);
            value["remoteStateUnknown"] = json!(value["status"] == "unknown");
            if value["message"].is_null() {
                value["message"] = json!("");
            }
            value["remoteTaskId"] = json!(task.remote_task_id);
            // Pending is a remote state, not a task waiting in the local scheduler.
            if value["status"] == "pending" {
                value["status"] = json!("running");
            }
            let success = !["failed", "unknown", "cancelled"].contains(&text(&value, "status"));
            let _ = host_event(&events, &target, "execute", value.clone()).await;
            if !text(&value, "remoteWorkDirectory").is_empty() {
                let _ = host_event(&events, &target, "workspace", json!({"status":if value["cleanupStatus"]=="failed"{"failed"}else{"success"}, "background":true,"remoteWorkDirectory":value["remoteWorkDirectory"],"cleanupStatus":value["cleanupStatus"],"remoteLogDirectory":value["remoteLogDirectory"]})).await;
            }
            value.as_object_mut().unwrap().remove("stdout");
            value.as_object_mut().unwrap().remove("stderr");
            let _ = host_event(&events, &target, "finished", value).await;
            success
        }
        Err(error) => {
            let _ = host_event(
                &events,
                &target,
                stage,
                json!({"status":"failed","message":error.to_string(),"background":true}),
            )
            .await;
            let unknown = run.action != "submit" || stage == "execute";
            let _ = host_event(&events, &target, "finished", json!({"status":if unknown{"unknown"}else{"failed"},"background":true,"remoteTaskId":task.remote_task_id,"message":error.to_string(),"remoteStateUnknown":unknown})).await;
            false
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn download_log(
    session: &Session,
    task: &BackgroundTask,
    stream: &str,
    options: &Value,
    job: &Job,
    cancel: &CancellationToken,
    report: &Path,
    secrets: &[String],
) -> Result<PathBuf> {
    let path = report.join(format!("{}-{stream}.log", task.remote_task_id));
    let temp = report.join(format!(".log-{}", uuid::Uuid::new_v4()));
    let result = async {
        let mut file = std::io::BufWriter::new(private_file(&temp)?);
        let mut offset = 0;
        let mut end = None;
        let mut buffer = Vec::new();
        loop {
            let part = remote(
                session,
                "logs",
                task,
                json!({"stream":stream,"offset":offset}),
                options,
                job.connect_timeout,
                cancel,
            )
            .await?;
            let size = *end.get_or_insert(part["size"].as_u64().context("Invalid log length")?);
            let bytes = STANDARD.decode(text(&part, "data"))?;
            let count = bytes.len().min(size.saturating_sub(offset) as usize);
            buffer.extend_from_slice(&bytes[..count]);
            offset += count as u64;
            write_redacted(&mut file, &mut buffer, secrets, offset >= size)?;
            if offset >= size {
                break;
            }
            ensure!(count > 0, "Remote log changed while downloading");
        }
        file.flush()?;
        file.get_ref().sync_all()?;
        drop(file);
        std::fs::rename(&temp, &path)?;
        Ok::<_, anyhow::Error>(path)
    }
    .await;
    let _ = std::fs::remove_file(temp);
    result
}

fn write_redacted(
    output: &mut impl Write,
    buffer: &mut Vec<u8>,
    secrets: &[String],
    last: bool,
) -> Result<()> {
    let reserve = if last {
        0
    } else {
        secrets
            .iter()
            .map(String::len)
            .max()
            .unwrap_or(1)
            .saturating_sub(1)
    };
    let safe = buffer.len().saturating_sub(reserve);
    let mut index = 0;
    while index < safe {
        if let Some(secret) = secrets
            .iter()
            .find(|s| !s.is_empty() && buffer[index..].starts_with(s.as_bytes()))
        {
            output.write_all(b"[redacted]")?;
            index += secret.len();
        } else {
            output.write_all(&buffer[index..index + 1])?;
            index += 1;
        }
    }
    buffer.drain(..index);
    Ok(())
}
