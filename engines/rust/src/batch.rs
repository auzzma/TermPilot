//! Desktop batch worker. One private process per job, independent SSH sessions,
//! bounded host concurrency, explicit cleanup policy and no automatic replay.
mod background;

use crate::{
    files::Files,
    ipc::{self, shell_quote as q, text, Events},
    ssh::{Prompts, Session},
};
use anyhow::{anyhow, bail, ensure, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
use termpilot_core::batch::{component, is_managed_work_directory, Job, Script};
use tokio::{
    io::{AsyncRead, AsyncWrite, BufReader},
    sync::mpsc,
    task::JoinSet,
};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Deserialize)]
pub struct Target {
    pub id: String,
    pub config: Value,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    job: Job,
    targets: Vec<Target>,
    history_directory: PathBuf,
    #[serde(default)]
    history_job_id: String,
    #[serde(default)]
    background_action: String,
}

pub async fn serve<R, W>(read: R, mut write: W) -> Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let mut input = ipc::JsonReader::new(BufReader::new(read));
    let first = input.read().await?.context("Missing batch job")?;
    let request: Request = serde_json::from_value(first).context("Invalid batch request")?;
    request.job.validate().map_err(anyhow::Error::msg)?;
    ensure!(
        !request.targets.is_empty() && request.targets.len() <= 1000,
        "Select 1–1000 hosts"
    );
    ensure!(
        request.history_directory.is_absolute(),
        "Absolute history directory required"
    );
    let mut ids = HashSet::new();
    let mut endpoints = HashSet::new();
    for t in &request.targets {
        ensure!(
            !t.id.is_empty() && ids.insert(t.id.clone()),
            "Duplicate host ID"
        );
        termpilot_core::connection::validate_endpoint(
            text(&t.config, "hostname"),
            t.config["port"].as_u64().unwrap_or(22),
        )
        .map_err(|e| anyhow!(e.message))?;
        ensure!(
            endpoints.insert((
                text(&t.config, "hostname").to_lowercase(),
                t.config["port"].as_u64().unwrap_or(22)
            )),
            "Duplicate host endpoint"
        );
        ensure!(
            ["none", "sudo", "su"].contains(&text(&t.config, "batchElevation")),
            "Invalid elevation method"
        );
    }
    let resuming = !request.background_action.is_empty();
    ensure!(
        ["", "status", "cancel", "logs"].contains(&request.background_action.as_str()),
        "Invalid background operation"
    );
    ensure!(
        resuming == !request.history_job_id.is_empty(),
        "Background history ID required"
    );
    let job_id = if resuming {
        uuid::Uuid::parse_str(&request.history_job_id)
            .context("Invalid history ID")?
            .to_string()
    } else {
        uuid::Uuid::new_v4().to_string()
    };
    // ISO UTC in manifests; filenames share one UTC instant across all hosts.
    let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S%3fZ").to_string();
    let report_dir = request.history_directory.join(&job_id);
    if !resuming {
        private_directory(&report_dir)?;
    }
    let background = background::prepare(&request, &job_id, &report_dir)?;
    let log_file = if resuming {
        let path = report_dir.join("events.jsonl");
        ensure!(
            !std::fs::symlink_metadata(&path)?.file_type().is_symlink(),
            "History links are not supported"
        );
        std::fs::OpenOptions::new().append(true).open(path)?
    } else {
        private_file(&report_dir.join("events.jsonl"))?
    };
    let mut log = tokio::fs::File::from_std(log_file);
    let secrets = secret_values(&request.targets);
    let (events, mut rx) = mpsc::channel::<Value>(128);
    let prompts = Prompts::default();
    let cancel = CancellationToken::new();
    let running = run(
        request.job,
        request.targets,
        job_id.clone(),
        stamp,
        events.clone(),
        prompts.clone(),
        cancel.clone(),
        background.clone(),
    );
    tokio::pin!(running);
    emit(
        &mut write,
        &mut log,
        json!({"type":"batchStarted","jobId":job_id,"reportDirectory":report_dir,"backgroundTasks":background.as_ref().map(|b| &b.tasks)}),
        &secrets,
    )
    .await?;
    let mut done = false;
    loop {
        tokio::select! {
            command=input.read(), if !done => match command {
                Ok(Some(c)) if matches!(text(&c,"type"),"hostKeyResponse"|"credentialResponse") => prompts.answer(&c).await,
                Ok(Some(c)) if matches!(text(&c,"type"),"cancel"|"close") => cancel.cancel(),
                Ok(Some(_)) => {},
                _ => { cancel.cancel(); done=true; }
            },
            result=&mut running => {
                while let Ok(v)=rx.try_recv() { emit(&mut write,&mut log,v,&secrets).await?; }
                let value=json!({"type":"batchFinished","jobId":job_id,"cancelled":cancel.is_cancelled(),"error":result.err().map(|e|e.to_string()),"reportDirectory":report_dir});
                emit(&mut write,&mut log,value,&secrets).await?; log.sync_all().await?; break;
            },
            Some(value)=rx.recv() => {
                if let Err(e)=emit(&mut write,&mut log,value,&secrets).await { cancel.cancel(); rx.close(); let _=tokio::time::timeout(Duration::from_secs(40),&mut running).await; return Err(e); }
            }
        }
    }
    Ok(())
}
fn private_directory(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
fn private_file(path: &Path) -> Result<std::fs::File> {
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    Ok(opts.open(path)?)
}
fn secret_values(targets: &[Target]) -> Vec<String> {
    let mut result = vec![];
    for t in targets {
        for k in [
            "password",
            "passphrase",
            "elevationPassword",
            "privateKey",
            "identityKey",
        ] {
            let s = text(&t.config, k);
            if !s.is_empty() {
                result.push(s.to_string());
            }
        }
        let p = text(&t.config["proxy"], "password");
        if !p.is_empty() {
            result.push(p.to_string());
        }
    }
    result.sort_by_key(|s| std::cmp::Reverse(s.len()));
    result.dedup();
    result
}
fn redact(value: &mut Value, secrets: &[String]) {
    match value {
        Value::String(s) => {
            for secret in secrets {
                *s = s.replace(secret, "[redacted]");
            }
        }
        Value::Array(a) => {
            for v in a {
                redact(v, secrets)
            }
        }
        Value::Object(o) => {
            for (k, v) in o.iter_mut() {
                if matches!(k.as_str(), "stdout" | "stderr" | "message" | "error") {
                    redact(v, secrets);
                } else if v.is_object() || v.is_array() {
                    redact(v, secrets);
                }
            }
        }
        _ => {}
    }
}
async fn emit<W: AsyncWrite + Unpin>(
    write: &mut W,
    log: &mut tokio::fs::File,
    mut value: Value,
    secrets: &[String],
) -> Result<()> {
    redact(&mut value, secrets);
    // Authentication prompts are transient, never part of persisted history.
    if !matches!(
        text(&value["event"], "type"),
        "hostKeyPrompt" | "credentialPrompt"
    ) && value["event"]["message"]["event"] != "progress"
    {
        value["time"] = json!(chrono::Utc::now().to_rfc3339());
        ipc::write_json(log, &value).await?;
        use tokio::io::AsyncWriteExt;
        log.flush().await?;
    }
    ipc::write_json(write, &value).await
}
async fn run(
    job: Job,
    targets: Vec<Target>,
    job_id: String,
    stamp: String,
    events: Events,
    prompts: Prompts,
    cancel: CancellationToken,
    background: Option<Arc<background::Run>>,
) -> Result<()> {
    let job = Arc::new(job);
    for target in &targets {
        host_event(&events, target, "authenticate", json!({"status":"pending"})).await?;
    }
    let mut pending = targets.into_iter();
    let mut tasks = JoinSet::new();
    let mut stopped = false;
    loop {
        while tasks.len() < job.concurrency && !stopped && !cancel.is_cancelled() {
            let Some(target) = pending.next() else { break };
            let (j, e, p, c, id, s) = (
                job.clone(),
                events.clone(),
                prompts.clone(),
                cancel.child_token(),
                job_id.clone(),
                stamp.clone(),
            );
            let background = background.clone();
            tasks.spawn(async move {
                if let Some(background) = background {
                    background::run_host(j, target, id, e, p, c, background).await
                } else {
                    run_host(j, target, id, s, e, p, c).await
                }
            });
        }
        if tasks.is_empty() {
            break;
        }
        let success = tasks.join_next().await.context("Missing host task")??;
        if !success && job.stop_on_failure {
            stopped = true;
        }
    }
    for t in pending {
        let value = if let Some(run) = background.as_ref().filter(|run| run.action != "submit") {
            json!({"status":"unknown","background":true,"remoteStateUnknown":true,
                "remoteTaskId":run.tasks.iter().find(|task| task.target_id == t.id).map(|task| &task.remote_task_id),
                "message":"Stopped observing background tasks"})
        } else {
            json!({"status":if cancel.is_cancelled(){"cancelled"}else{"skipped"},"message":"Not started"})
        };
        host_event(&events, &t, "finished", value).await?;
    }
    Ok(())
}
async fn host_event(events: &Events, target: &Target, stage: &str, mut data: Value) -> Result<()> {
    data["type"] = json!("batchHost");
    data["targetId"] = json!(target.id);
    data["ip"] = json!(text(&target.config, "hostname"));
    data["port"] = json!(target.config["port"].as_u64().unwrap_or(22));
    data["stage"] = json!(stage);
    ipc::event(events, data).await
}
async fn run_host(
    job: Arc<Job>,
    target: Target,
    job_id: String,
    stamp: String,
    events: Events,
    prompts: Prompts,
    cancel: CancellationToken,
) -> bool {
    let started = Instant::now();
    let (raw, mut receiver) = mpsc::channel::<Value>(64);
    let (e, t) = (events.clone(), target.clone());
    let relay = tokio::spawn(async move {
        while let Some(event) = receiver.recv().await {
            if ipc::event(&e,json!({"type":"batchEvent","targetId":t.id,"ip":text(&t.config,"hostname"),"event":event})).await.is_err(){break;}
        }
    });
    let _ = host_event(
        &events,
        &target,
        "authenticate",
        json!({"status":"running"}),
    )
    .await;
    let connected = tokio::select! {
        _=cancel.cancelled()=>Err(anyhow!("Cancelled before connection")),
        r=tokio::time::timeout(Duration::from_secs(job.connect_timeout),Session::connect(target.config.clone(),raw.clone(),prompts))=>r.context("Connection timed out").and_then(|r|r)
    };
    let outcome = match connected {
        Err(e) => {
            let status = if cancel.is_cancelled() {
                "cancelled"
            } else {
                "failed"
            };
            let _ = host_event(
                &events,
                &target,
                "authenticate",
                json!({"status":status,"message":e.to_string()}),
            )
            .await;
            let _ = host_event(&events, &target, "elevation", json!({"status":"skipped","message":"Authentication did not succeed; elevation was not checked."})).await;
            Err(e)
        }
        Ok(session) => {
            let workdir = if job.remote_work_directory.is_empty() {
                format!("/tmp/ssh-batch-{}", uuid::Uuid::new_v4())
            } else {
                job.remote_work_directory.clone()
            };
            let task_id = if job.source_task_id.is_empty() {
                job_id
            } else {
                job.source_task_id.clone()
            };
            let mut context = ContextData {
                job: job.clone(),
                target: target.clone(),
                session: session.clone(),
                events: events.clone(),
                raw: raw.clone(),
                cancel: cancel.clone(),
                job_id: task_id,
                stamp,
                workdir,
                workspace_cleanup_required: false,
            };
            let result = context.execute().await;
            // The worker owns this directory, independently of the user's
            // optional post-collection script and its success/failure policy.
            let cleanup = context.cleanup_workspace().await;
            session.close().await;
            match (result, cleanup) {
                (Ok(()), result) => result,
                (Err(error), Ok(())) => Err(error),
                (Err(error), Err(cleanup)) => Err(anyhow!("{error}; {cleanup}")),
            }
        }
    };
    drop(raw);
    relay.abort();
    let _ = relay.await;
    let status = if cancel.is_cancelled() {
        "cancelled"
    } else if outcome.is_ok() {
        "success"
    } else {
        "failed"
    };
    let _=host_event(&events,&target,"finished",json!({"status":status,"elapsedMs":started.elapsed().as_millis(),"message":outcome.as_ref().err().map(|e|e.to_string()),"remoteStateUnknown":cancel.is_cancelled() || outcome.as_ref().err().is_some_and(|e|e.to_string().to_lowercase().contains("timed out"))})).await;
    outcome.is_ok() && !cancel.is_cancelled()
}
struct ContextData {
    job: Arc<Job>,
    target: Target,
    session: Arc<Session>,
    events: Events,
    raw: Events,
    cancel: CancellationToken,
    job_id: String,
    stamp: String,
    workdir: String,
    workspace_cleanup_required: bool,
}
impl ContextData {
    async fn event(&self, stage: &str, data: Value) -> Result<()> {
        host_event(&self.events, &self.target, stage, data).await
    }
    fn elevation<'a>(&'a self, override_mode: &'a str) -> &'a str {
        if override_mode.is_empty() {
            text(&self.target.config, "batchElevation")
        } else {
            override_mode
        }
    }
    async fn command(&self, body: &str, elevation: &str) -> Result<Value> {
        ensure!(
            !self.cancel.is_cancelled(),
            "Cancelled; remote process state may be unknown"
        );
        let mode = self.elevation(elevation);
        let password =
            if mode == "sudo" && text(&self.target.config, "elevationPassword").is_empty() {
                &self.target.config["password"]
            } else {
                &self.target.config["elevationPassword"]
            };
        let options =
            json!({"elevated":mode!="none","elevationMethod":mode,"elevationPassword":password});
        self.session
            .exec_cancellable_with_timeout(
                body,
                step_timeout(self.job.step_timeout),
                &options,
                &self.cancel,
            )
            .await
    }
    async fn checked(&self, body: &str, elevation: &str) -> Result<Value> {
        let v = self.command(body, elevation).await?;
        ensure!(
            v["exitCode"] == 0,
            "Command failed (exit {}): {}",
            v["exitCode"],
            text(&v, "stderr")
        );
        Ok(v)
    }
    async fn script(&self, stage: &str, script: &Script) -> Result<()> {
        if script.body.trim().is_empty() {
            return Ok(());
        }
        self.event(stage, json!({"status":"running"})).await?;
        let command = script_command(
            script,
            &self.job_id,
            text(&self.target.config, "hostname"),
            &self.workdir,
        );
        let result = self.command(&command, &script.elevation).await;
        match result {
            Ok(v) => {
                self.event(stage,json!({"status":if v["exitCode"]==0{"success"}else{"failed"},"stdout":v["stdout"],"stderr":v["stderr"],"exitCode":v["exitCode"]})).await?;
                ensure!(
                    v["exitCode"] == 0,
                    "{stage} script failed (exit {})",
                    v["exitCode"]
                );
                Ok(())
            }
            Err(e) => {
                self.event(stage, json!({"status":"failed","message":e.to_string()}))
                    .await?;
                Err(e)
            }
        }
    }
    async fn cleanup_workspace(&self) -> Result<()> {
        if !self.workspace_cleanup_required {
            return Ok(());
        }
        ensure!(
            is_managed_work_directory(&self.workdir),
            "Invalid temporary directory"
        );
        let _ = self.event("workspace", json!({"status":"running", "cleanupStatus":"running", "remoteWorkDirectory":self.workdir, "sourceTaskId":self.job_id})).await;
        // An independent token lets finalization run after cancellation/timeout.
        // Never follow a substituted symlink, or delete outside this exact path.
        let command = format!(
            "rm -rf -- {p}; test ! -e {p} && test ! -L {p}",
            p = q(&self.workdir)
        );
        let mut modes = vec!["none"];
        for mode in [
            self.elevation(""),
            self.elevation(&self.job.script.elevation),
            self.elevation(&self.job.before.elevation),
            self.elevation(&self.job.after.elevation),
        ] {
            if mode != "none" && !modes.contains(&mode) {
                modes.push(mode);
            }
        }
        let cleanup = async {
            let mut last = String::new();
            for mode in modes {
                let password = if mode == "sudo"
                    && text(&self.target.config, "elevationPassword").is_empty()
                {
                    &self.target.config["password"]
                } else {
                    &self.target.config["elevationPassword"]
                };
                let options = json!({"elevated":mode!="none", "elevationMethod":mode, "elevationPassword":password});
                match self
                    .session
                    .exec_cancellable(
                        &command,
                        Duration::from_secs(10),
                        &options,
                        &CancellationToken::new(),
                    )
                    .await
                {
                    Ok(value) if value["exitCode"] == 0 => return Ok(()),
                    Ok(value) => {
                        last = format!("exit {}: {}", value["exitCode"], text(&value, "stderr"))
                    }
                    Err(error) => last = error.to_string(),
                }
            }
            bail!("{last}")
        };
        let result = tokio::time::timeout(Duration::from_secs(30), cleanup)
            .await
            .context("Temporary directory cleanup timed out")
            .and_then(|result| result);
        let message = result
            .as_ref()
            .err()
            .map(|error| format!("Temporary directory cleanup failed: {error}"));
        let _ = self.event("workspace", json!({"status":if result.is_ok(){"success"}else{"failed"}, "cleanupStatus":if result.is_ok(){"success"}else{"failed"}, "remoteWorkDirectory":self.workdir, "sourceTaskId":self.job_id, "message":message})).await;
        result.map_err(|_| anyhow!("{}", message.unwrap()))
    }
    async fn execute(&mut self) -> Result<()> {
        self.event("authenticate", json!({"status":"success"}))
            .await?;
        self.event("elevation", json!({"status":"running"})).await?;
        if let Err(error) = self.checked("id -u", "").await {
            self.event("elevation", json!({"status":if self.cancel.is_cancelled(){"cancelled"}else{"failed"},"message":error.to_string()})).await?;
            return Err(error.context("Elevation check failed"));
        }
        self.event("elevation", json!({"status":"success"})).await?;
        if self.job.kind == "check" {
            return Ok(());
        }
        if self.job.remote_work_directory.is_empty() {
            // If the transport fails after mkdir was sent, still attempt cleanup.
            // A confirmed mkdir failure (including a collision) owns no directory.
            self.workspace_cleanup_required = true;
            let result = self
                .command(&format!("umask 077; mkdir {}", q(&self.workdir)), "none")
                .await?;
            if result["exitCode"] != 0 {
                self.workspace_cleanup_required = result["exitCode"].as_i64().is_none();
                bail!(
                    "Could not create temporary directory: {}",
                    text(&result, "stderr")
                );
            }
        } else {
            self.checked(
                &format!(
                    "test -d {} && test ! -L {}",
                    q(&self.workdir),
                    q(&self.workdir)
                ),
                "none",
            )
            .await?;
            self.workspace_cleanup_required = true;
        }
        self.event("workspace",json!({"status":"success","cleanupStatus":"pending","remoteWorkDirectory":self.workdir,"sourceTaskId":self.job_id})).await?;
        if self.job.kind == "execute" {
            return self.script("execute", &self.job.script).await;
        }
        let mut config = self.target.config.clone();
        config["usesSudo"] = json!(false);
        config["fileProtocol"] = json!("sftp");
        let files = tokio::select! {_=self.cancel.cancelled()=>bail!("Cancelled"),r=tokio::time::timeout(Duration::from_secs(self.job.connect_timeout),Files::open(self.session.clone(),config))=>r.context("SFTP open timed out")??};
        let result = if self.job.kind == "upload" {
            self.upload(&files).await
        } else {
            self.collect(&files).await
        };
        files.shutdown().await;
        result
    }
    async fn transfer(
        &self,
        files: &Arc<Files>,
        mut request: Value,
        step_id: &str,
    ) -> Result<Value> {
        request["id"] = json!(step_id);
        let operation = files.request(request, self.raw.clone(), "batch".into());
        tokio::pin!(operation);
        tokio::select! {
            r=&mut operation=>r,
            _=self.cancel.cancelled()=>{files.shutdown().await;let _=tokio::time::timeout(Duration::from_secs(3),&mut operation).await; bail!("Transfer cancelled")},
            _=crate::ssh::optional_deadline(step_timeout(self.job.step_timeout))=>{files.shutdown().await;let _=tokio::time::timeout(Duration::from_secs(3),&mut operation).await;bail!("Transfer timed out")}
        }
    }
    async fn upload(&self, files: &Arc<Files>) -> Result<()> {
        let mut errors = vec![];
        let mut names = HashSet::new();
        for path in &self.job.local_paths {
            let name = Path::new(path)
                .file_name()
                .and_then(|s| s.to_str())
                .context("Invalid local filename")?;
            ensure!(
                names.insert(name.to_string()),
                "Selected upload paths have duplicate filenames"
            );
        }
        for (index, path) in self.job.local_paths.iter().enumerate() {
            ensure!(!self.cancel.is_cancelled(), "Cancelled");
            let name = Path::new(path).file_name().unwrap().to_str().unwrap();
            let destination = format!(
                "{}/{}",
                self.job.remote_directory.trim_end_matches('/'),
                name
            );
            let stage = format!("{}/upload-{index}", self.workdir);
            self.event(
                "upload",
                json!({"status":"running","stepId":format!("upload-{index}"),"localPath":path,"remotePath":destination}),
            )
            .await?;
            let operation=async {
                let existence=self.command(&format!("if [ -e {p} ] || [ -L {p} ]; then exit 0; else exit 1; fi",p=q(&destination)),"").await?;
                ensure!(existence["exitCode"]==0 || existence["exitCode"]==1,"Could not inspect upload destination");
                let conflict=existence["exitCode"]==0;
                if conflict {
                    self.event("conflict",json!({"status":"detected","remotePath":destination,"policy":self.job.overwrite})).await?;
                    if self.job.overwrite=="skip" {return Ok::<_,anyhow::Error>(("skipped", false));}
                }
                self.transfer(files,json!({"action":"upload","localPath":path,"remotePath":stage,"overwrite":false}), &format!("upload-{index}")).await?;
                self.verify_upload(files,Path::new(path),&stage).await?;
                let directory=std::fs::symlink_metadata(path)?.is_dir();
                let cmd=upload_install_command(&self.job,&stage,&destination,&self.job_id,directory);
                let result=self.command(&cmd,"").await?;
                if result["exitCode"]==66 {if !conflict {self.event("conflict",json!({"status":"detected","remotePath":destination,"policy":self.job.overwrite})).await?;}return Ok::<_,anyhow::Error>(("skipped", false));}
                let installed_conflict = text(&result,"stdout").contains("__TERMPILOT_CONFLICT__");
                if installed_conflict && !conflict { self.event("conflict",json!({"status":"detected","remotePath":destination,"policy":self.job.overwrite})).await?; }
                ensure!(result["exitCode"]==0,"Install/permissions failed: {}",text(&result,"stderr"));
                Ok(("success", installed_conflict))
            }.await;
            match operation {Ok((status, backed_up))=>self.event("upload",json!({"status":status,"stepId":format!("upload-{index}"),"remotePath":destination,"policy":self.job.overwrite,"backupPath":if self.job.overwrite=="backup" && backed_up {Some(format!("{destination}.termpilot-backup-{}",self.job_id))}else{None}})).await?,Err(e)=>{errors.push(e.to_string()); self.event("upload",json!({"status":"failed","stepId":format!("upload-{index}"),"remotePath":destination,"message":e.to_string()})).await?;}}
        }
        ensure!(
            errors.is_empty(),
            "{} upload(s) failed: {}",
            errors.len(),
            errors.join("; ")
        );
        Ok(())
    }
    async fn verify_upload(&self, files: &Arc<Files>, local: &Path, remote: &str) -> Result<()> {
        let sftp = files.sftp.as_ref().context("SFTP required")?;
        let mut pending = vec![(local.to_owned(), remote.to_string())];
        let mut count = 0;
        while let Some((local, remote)) = pending.pop() {
            ensure!(
                !self.cancel.is_cancelled(),
                "Cancelled during upload verification"
            );
            count += 1;
            ensure!(count <= 100000, "Too many upload entries");
            let meta = std::fs::symlink_metadata(&local)?;
            if meta.is_dir() {
                for e in std::fs::read_dir(&local)? {
                    let e = e?;
                    pending.push((
                        e.path(),
                        format!(
                            "{}/{}",
                            remote,
                            e.file_name().to_str().context("Invalid filename")?
                        ),
                    ));
                }
            } else {
                ensure!(meta.is_file(), "Only regular upload files are supported");
                let p = local.clone();
                let local = tokio::task::spawn_blocking(move || local_hash(&p)).await??;
                let remote = remote_hash(
                    sftp,
                    &remote,
                    &self.cancel,
                    Duration::from_secs(self.job.step_timeout),
                )
                .await?;
                ensure!(
                    local == remote,
                    "Upload checksum mismatch; destination was not replaced"
                );
            }
        }
        Ok(())
    }
    async fn collect(&self, files: &Arc<Files>) -> Result<()> {
        let before = self.script("prepare", &self.job.before).await;
        let mut errors = vec![];
        if let Err(e) = before {
            errors.push(e.to_string());
        } else {
            if let Err(e) = std::fs::create_dir_all(&self.job.local_directory) {
                errors.push(e.to_string());
            }
            for (index, template) in self.job.remote_paths.iter().enumerate() {
                if self.cancel.is_cancelled() {
                    errors.push("Cancelled; remote state may be unknown".into());
                    break;
                }
                let remote = template
                    .replace("${REMOTE_WORK_DIR}", &self.workdir)
                    .replace("${HOST_IP}", text(&self.target.config, "hostname"))
                    .replace("${TASK_ID}", &self.job_id);
                self.event("collect", json!({"status":"running","stepId":format!("collect-{index}"),"remotePath":remote}))
                    .await?;
                let result = self.collect_file(files, &remote, index).await;
                match result {Ok((local,hash))=>self.event("collect",json!({"status":"success","stepId":format!("collect-{index}"),"remotePath":remote,"localPath":local,"sha256":hash})).await?, Err(e)=>{errors.push(e.to_string());self.event("collect",json!({"status":"failed","stepId":format!("collect-{index}"),"remotePath":remote,"message":e.to_string()})).await?;}}
            }
        }
        let collected = errors.is_empty();
        self.event("collection",json!({"status":if collected{"success"}else{"failed"},"remoteWorkDirectory":self.workdir,"sourceTaskId":self.job_id})).await?;
        // Cancellation skips user scripts. The owned workspace is always
        // finalized separately, even when collection or this script fails.
        if !self.cancel.is_cancelled() && self.job.should_cleanup(collected) {
            if let Err(e) = self.script("cleanup", &self.job.after).await {
                errors.push(format!("Cleanup failed: {e}"));
            }
        } else if !self.job.after.body.is_empty() {
            self.event("cleanup", json!({"status":"skipped"})).await?;
        }
        ensure!(errors.is_empty(), "{}", errors.join("; "));
        Ok(())
    }
    async fn collect_file(
        &self,
        files: &Arc<Files>,
        remote: &str,
        index: usize,
    ) -> Result<(PathBuf, String)> {
        // Privileged reads are snapshotted into the login user's private 0700
        // workspace. No dependency on a root SFTP server or su's binary PTY.
        let source = if self.elevation("") != "none" {
            let staged = format!("{}/collect-{index}-{}", self.workdir, uuid::Uuid::new_v4());
            self.checked(
                &format!(
                    "test -f {p} && cp -- {p} {s} && chmod 0644 {s}",
                    p = q(remote),
                    s = q(&staged)
                ),
                "",
            )
            .await?;
            staged
        } else {
            remote.to_string()
        };
        let sftp = files.sftp.as_ref().context("SFTP required")?;
        let attrs = sftp.stat(&source, true).await?;
        ensure!(
            attrs.kind() == "file",
            "Collection requires regular files; archive directories first"
        );
        let expected = remote_hash(
            sftp,
            &source,
            &self.cancel,
            Duration::from_secs(self.job.step_timeout),
        )
        .await?;
        let temporary = Path::new(&self.job.local_directory)
            .join(format!(".termpilot-batch-{}", uuid::Uuid::new_v4()));
        let result=async {
            self.transfer(files,json!({"action":"download","localPath":temporary,"remotePath":source,"overwrite":false}), &format!("collect-{index}")).await?;
            let p=temporary.clone(); let hash=tokio::task::spawn_blocking(move||local_hash(&p)).await??;
            ensure!(hash==expected,"Source changed or checksum mismatch");
            let after=sftp.stat(&source,true).await?;
            ensure!(after.size==attrs.size && after.mtime==attrs.mtime,"Source changed during collection; create a snapshot in preparation");
            let name=component(remote.rsplit('/').next().unwrap_or("file"));
            let stem=format!("{}-{}-{}",component(text(&self.target.config,"hostname")),self.stamp,name);
            let published=publish_unique(&temporary,Path::new(&self.job.local_directory),&stem)?;
            Ok((published,hash))
        }.await;
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        if result.is_ok() && source != remote {
            let _ = self.checked(&format!("rm -f -- {}", q(&source)), "").await;
        }
        result
    }
}
pub fn script_command(script: &Script, id: &str, host: &str, work: &str) -> String {
    let mut prefix = format!(
        "export TASK_ID={} HOST_IP={} REMOTE_WORK_DIR={}; ",
        q(id),
        q(host),
        q(work)
    );
    for (k, v) in &script.environment {
        prefix.push_str(&format!("export {k}={}; ", q(v)));
    }
    if !script.cwd.is_empty() {
        prefix.push_str(&format!(
            "cd {} || exit; ",
            q(&script.cwd.replace("${REMOTE_WORK_DIR}", work))
        ));
    }
    prefix.push_str(&format!(
        "exec {} -c {} termpilot",
        q(if script.shell.is_empty() {
            "/bin/bash"
        } else {
            &script.shell
        }),
        q(&script
            .body
            .trim_start_matches('\u{feff}')
            .replace("\r\n", "\n"))
    ));
    for arg in &script.args {
        prefix.push(' ');
        prefix.push_str(&q(arg));
    }
    prefix
}
fn upload_install_command(job: &Job, stage: &str, dest: &str, id: &str, directory: bool) -> String {
    let d = q(dest);
    let temporary = format!("{dest}.termpilot-{id}.part");
    let tmp = q(&temporary);
    let exists = format!("[ -e {d} ] || [ -L {d} ]");
    let skip = if job.overwrite == "skip" {
        format!("if {exists}; then exit 66; fi; ")
    } else {
        String::new()
    };
    let permissions = if directory && job.recursive_permissions {
        format!(
            "find {tmp} -type d -exec chmod {} {{}} +; find {tmp} -type f -exec chmod {} {{}} +; ",
            job.directory_mode, job.file_mode
        )
    } else {
        format!(
            "chmod {} {tmp}; ",
            if directory {
                &job.directory_mode
            } else {
                &job.file_mode
            }
        )
    };
    let ownership = if !job.owner.is_empty() || !job.group.is_empty() {
        format!(
            "chown {} {} {tmp}; ",
            if directory && job.recursive_permissions {
                "-R"
            } else {
                ""
            },
            q(&format!(
                "{}{}{}",
                job.owner,
                if job.group.is_empty() { "" } else { ":" },
                job.group
            ))
        )
    } else {
        String::new()
    };
    let backup = format!("{dest}.termpilot-backup-{id}");
    // Preserve an existing tree by rename; overwrite removes only that backup
    // after the replacement has been installed successfully.
    format!("set -e; mkdir -p -- {parent}; {skip}test ! -e {tmp}; test ! -L {tmp}; cp -R -- {stage} {tmp}; {permissions}{ownership}{skip}if {exists}; then printf '__TERMPILOT_CONFLICT__\\n'; test ! -e {backup}; test ! -L {backup}; mv -- {d} {backup}; fi; if mv -n -- {tmp} {d}; then if [ -e {tmp} ] || [ -L {tmp} ]; then rm -rf -- {tmp}; exit 66; fi; {remove}true; else if [ -e {backup} ] && [ ! -e {d} ]; then mv -- {backup} {d}; fi; exit 1; fi",parent=q(&job.remote_directory),stage=q(stage),backup=q(&backup),remove=if job.overwrite=="overwrite"{format!("rm -rf -- {}; ",q(&backup))}else{String::new()})
}
async fn remote_hash(
    sftp: &Arc<crate::sftp::Sftp>,
    path: &str,
    cancel: &CancellationToken,
    timeout: Duration,
) -> Result<String> {
    let timeout = if timeout.is_zero() {
        None
    } else {
        Some(timeout)
    };
    let handle = tokio::select! {
        _=cancel.cancelled()=>bail!("Cancelled during checksum"),
        _=crate::ssh::optional_deadline(timeout)=>bail!("Checksum timed out"),
        result=sftp.open(path, 1, Default::default())=>result?,
    };
    let work = async {
        let mut hash = Sha256::new();
        let mut offset = 0;
        loop {
            let b = sftp.read(&handle, offset, 65536).await?;
            if b.is_empty() {
                break;
            }
            offset += b.len() as u64;
            hash.update(&b);
        }
        Ok::<_, anyhow::Error>(hex::encode(hash.finalize()))
    };
    let result = tokio::select! {
        _=cancel.cancelled()=>Err(anyhow!("Cancelled during checksum")),
        _=crate::ssh::optional_deadline(timeout)=>Err(anyhow!("Checksum timed out")),
        result=work=>result,
    };
    let _ = tokio::time::timeout(Duration::from_secs(2), sftp.close(&handle)).await;
    result
}
fn step_timeout(seconds: u64) -> Option<Duration> {
    (seconds != 0).then(|| Duration::from_secs(seconds))
}
fn local_hash(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut h = Sha256::new();
    let mut b = [0u8; 65536];
    loop {
        let n = f.read(&mut b)?;
        if n == 0 {
            break;
        }
        h.update(&b[..n]);
    }
    Ok(hex::encode(h.finalize()))
}
fn publish_unique(temp: &Path, directory: &Path, name: &str) -> Result<PathBuf> {
    for n in 0..10000 {
        let path = directory.join(if n == 0 {
            name.to_string()
        } else {
            let stem = Path::new(name)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(name);
            let ext = Path::new(name).extension().and_then(|s| s.to_str());
            format!(
                "{stem}-{n}{}",
                ext.map(|s| format!(".{s}")).unwrap_or_default()
            )
        });
        match crate::platform::publish_new_file(temp, &path) {
            Ok(()) => return Ok(path),
            Err(_) if std::fs::symlink_metadata(&path).is_ok() => continue,
            Err(e) => return Err(e.into()),
        }
    }
    bail!("Too many filename collisions")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shell_arguments_cannot_escape() {
        let s = Script {
            body: "printf '%s' \"$1\"".into(),
            args: vec!["'; touch /tmp/not-run; '".into()],
            ..Default::default()
        };
        let c = script_command(&s, "id", "127.0.0.1", "/tmp/work");
        assert!(c.contains("'\\''"));
        assert!(c.contains("export TASK_ID='id'"));
    }
    #[test]
    fn collection_never_overwrites() {
        let d = std::env::temp_dir().join(format!("tp-batch-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&d).unwrap();
        std::fs::write(d.join("ip-time-x.log"), "old").unwrap();
        std::fs::write(d.join("temp"), "new").unwrap();
        let p = publish_unique(&d.join("temp"), &d, "ip-time-x.log").unwrap();
        assert_eq!(p.file_name().unwrap(), "ip-time-x-1.log");
        assert_eq!(
            std::fs::read_to_string(d.join("ip-time-x.log")).unwrap(),
            "old"
        );
        std::fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn reports_redact_credentials_recursively() {
        let mut v = json!({"stdout":"secret","items":["prefix secret"]});
        redact(&mut v, &["secret".into()]);
        assert!(!v.to_string().contains("secret"));
    }
}
