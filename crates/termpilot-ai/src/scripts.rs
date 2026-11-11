//! Shared snippet records and isolated automation jobs.
use crate::{
    model::{text, Conversation},
    read_line, Runtime,
};
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    process::Stdio,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    process::Command,
    sync::{watch, Mutex},
};
use tokio_util::sync::CancellationToken;
pub const NAMES: &[&str] = &[
    "snippets_list",
    "snippets_get",
    "snippets_create",
    "snippets_update",
    "snippets_delete",
    "snippets_run",
    "scripts_list",
    "scripts_get",
    "scripts_create",
    "scripts_update",
    "scripts_delete",
    "scripts_run",
    "scripts_reference",
    "scripts_runs_list",
    "scripts_run_stop",
    "scripts_run_pause",
    "scripts_run_resume",
    "scripts_targets_set",
    "host_connect_scripts_list",
    "host_connect_scripts_set",
];
struct Handle {
    conversation: String,
    cancel: CancellationToken,
    pause: watch::Sender<bool>,
}
struct Lease {
    runtime: Arc<Runtime>,
    id: String,
    run: Option<String>,
}
impl Drop for Lease {
    fn drop(&mut self) {
        let runtime = self.runtime.clone();
        let id = self.id.clone();
        let run = self.run.clone();
        tokio::spawn(async move {
            runtime.terminal.release_script(&id).await;
            if let Some(run_id) = run {
                if runtime.scripts.runs.lock().await.remove(&run_id).is_some() {
                    let store = runtime.store.lock().await;
                    if let Ok(Some(mut record)) = store.get::<Value>("scriptRuns", &run_id) {
                        if ["running", "pauseRequested", "paused", "stopping"]
                            .contains(&text(&record, "status"))
                        {
                            record["status"] = json!("interrupted");
                            record["error"] = json!(
                                "Script controller ended; terminal outcomes require verification"
                            );
                            let _ = store.put("scriptRuns", &run_id, &record);
                        }
                    }
                }
            }
        });
    }
}
#[derive(Default)]
struct Output {
    bytes: VecDeque<u8>,
    position: u64,
    escape: u8,
}
#[derive(Default)]
pub struct Scheduler {
    queues: Mutex<HashMap<String, VecDeque<String>>>,
    output_pending: Mutex<std::collections::HashSet<String>>,
    trigger_times: Mutex<HashMap<String, VecDeque<std::time::Instant>>>,
    draining: Mutex<std::collections::HashSet<String>>,
    trigger_positions: Mutex<HashMap<(String, String), u64>>,
    runs: Mutex<HashMap<String, Handle>>,
    output: Mutex<HashMap<String, Output>>,
}
impl Scheduler {
    pub async fn feed(&self, session: &str, bytes: &[u8]) {
        let mut all = self.output.lock().await;
        if !all.contains_key(session) && all.len() >= 64 {
            return;
        }
        let output = all.entry(session.into()).or_default();
        for &b in bytes {
            match output.escape {
                1 => {
                    output.escape = if b == b'[' {
                        2
                    } else if b == b']' {
                        3
                    } else {
                        0
                    };
                    continue;
                }
                2 => {
                    if (0x40..=0x7e).contains(&b) {
                        output.escape = 0
                    }
                    continue;
                }
                3 => {
                    if b == 7 {
                        output.escape = 0
                    } else if b == 27 {
                        output.escape = 4
                    }
                    continue;
                }
                4 => {
                    output.escape = if b == b'\\' { 0 } else { 3 };
                    continue;
                }
                _ => {}
            }
            if b == 27 {
                output.escape = 1;
                continue;
            }
            if b == 13 {
                continue;
            }
            if b < 32 && b != 10 && b != 9 {
                continue;
            }
            output.bytes.push_back(b);
            output.position += 1;
            if output.bytes.len() > 1024 * 1024 {
                output.bytes.pop_front();
            }
        }
    }
    pub async fn cancel_conversation(&self, id: &str) {
        for run in self
            .runs
            .lock()
            .await
            .values()
            .filter(|r| r.conversation == id)
        {
            run.cancel.cancel();
        }
    }
    pub async fn position(&self, session: &str) -> u64 {
        self.output
            .lock()
            .await
            .get(session)
            .map(|o| o.position)
            .unwrap_or(0)
    }
    async fn output(&self, session: &str, offset: u64) -> Value {
        let all = self.output.lock().await;
        let Some(output) = all.get(session) else {
            return json!({"text":"","position":0});
        };
        let start = output.position.saturating_sub(output.bytes.len() as u64);
        let bytes: Vec<u8> = output
            .bytes
            .iter()
            .skip(offset.saturating_sub(start) as usize)
            .copied()
            .collect();
        json!({"text":String::from_utf8_lossy(&bytes),"position":output.position,"truncated":offset<start})
    }
}
fn boolean(v: &Value, key: &str, default: bool) -> Result<bool> {
    match v.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(Value::Bool(b)) => Ok(*b),
        Some(Value::String(s)) if s == "true" => Ok(true),
        Some(Value::String(s)) if s == "false" => Ok(false),
        _ => bail!("{key} must be true or false"),
    }
}
pub async fn definition(rt: &Runtime, id: &str) -> Result<Value> {
    rt.store
        .lock()
        .await
        .get("automation", id)?
        .context("Snippet or script not found")
}
pub async fn execute(
    rt: &Arc<Runtime>,
    c: &Conversation,
    name: &str,
    args: &Value,
    cancel: &CancellationToken,
    approved_script: Option<&Value>,
) -> Result<Value> {
    let script = name.starts_with("scripts_");
    let id = text(args, if script { "scriptId" } else { "snippetId" });
    match name {
        "scripts_reference" => Ok(
            json!({"language":"JavaScript","runtime":"Isolated QuickJS controlled by Rust","api":include_str!("script_api.md")}),
        ),
        "snippets_list" | "scripts_list" => {
            let records = rt.store.lock().await.list::<Value>("automation")?;
            Ok(json!(records
                .into_iter()
                .filter(|r| !script || r["kind"] == "script")
                .collect::<Vec<_>>()))
        }
        "snippets_get" | "scripts_get" => definition(rt, id).await,
        "snippets_create"
        | "snippets_update"
        | "scripts_create"
        | "scripts_update"
        | "scripts_targets_set" => {
            let mut record = if name.ends_with("create") {
                json!({"id":uuid::Uuid::new_v4().to_string(),"kind":if script{"script"}else{"snippet"},"trigger":"manual"})
            } else {
                definition(rt, id).await?
            };
            for (key, value) in args.as_object().unwrap() {
                match key.as_str() {
                    "scriptId" | "snippetId" => {}
                    "tags" | "targets" | "targetGroups" => {
                        let list: Vec<String> =
                            serde_json::from_str(value.as_str().context("Expected JSON array")?)?;
                        record[key] = json!(list);
                    }
                    "targetsAllHosts" | "noAutoRun" => {
                        record[key] = json!(boolean(args, key, false)?)
                    }
                    _ => record[key] = value.clone(),
                }
            }
            ensure!(
                !text(&record, "label").trim().is_empty(),
                "A script or snippet name is required"
            );
            ensure!(
                text(&record, "content").len() <= 1024 * 1024,
                "Script exceeds 1 MiB"
            );
            ensure!(
                ["script", "snippet"].contains(&text(&record, "kind")),
                "Unknown snippet kind"
            );
            ensure!(
                ["manual", "onConnect", "onOutput"].contains(&text(&record, "trigger")),
                "Unknown script trigger"
            );
            if record["trigger"] == "onOutput" {
                ensure!(
                    !text(&record, "triggerPattern").is_empty(),
                    "Output trigger requires a pattern"
                );
                let pattern = regex::RegexBuilder::new(text(&record, "triggerPattern"))
                    .size_limit(1024 * 1024)
                    .build()
                    .context("Invalid output trigger regex")?;
                ensure!(
                    !pattern.is_match(""),
                    "Output trigger cannot match empty text"
                );
            }
            if let Some(mode) = record["multiLineRunMode"].as_str() {
                ensure!(
                    ["paste", "lineDelay"].contains(&mode),
                    "Unknown multiline mode"
                );
            }
            record["updatedAt"] = json!(crate::model::now());
            let store = rt.store.lock().await;
            let mut changes = vec![("automation", text(&record, "id").to_owned(), record.clone())];
            let previous: Value = store
                .get("automation", text(&record, "id"))?
                .unwrap_or(Value::Null);
            let old = previous["targets"].as_array().cloned().unwrap_or_default();
            let new = record["targets"].as_array().cloned().unwrap_or_default();
            let hosts: std::collections::HashSet<_> = old
                .iter()
                .chain(new.iter())
                .filter_map(Value::as_str)
                .collect();
            for host in hosts {
                target_host(&store.vault()?, host)?;
                let mut queue: Vec<String> = store.get("scriptQueues", host)?.unwrap_or_default();
                queue.retain(|id| id != text(&record, "id"));
                if record["trigger"] == "onConnect" && new.iter().any(|v| v == host) {
                    queue.push(text(&record, "id").into());
                }
                changes.push(("scriptQueues", host.into(), json!(queue)));
            }
            store.put_batch(&changes)?;
            Ok(record)
        }
        "snippets_delete" | "scripts_delete" => {
            definition(rt, id).await?;
            rt.store.lock().await.delete("automation", id)?;
            Ok(json!({"deleted":true}))
        }
        "host_connect_scripts_list" => Ok(json!(resolved_queue(rt, text(args, "hostId")).await?)),
        "host_connect_scripts_set" => {
            let host = text(args, "hostId");
            let ids: Vec<String> = serde_json::from_str(text(args, "scriptIds"))?;
            ensure!(ids.len() <= 128, "Connection script queue limit exceeded");
            let store = rt.store.lock().await;
            target_host(&store.vault()?, host)?;
            let mut unique = std::collections::HashSet::new();
            for id in &ids {
                ensure!(unique.insert(id), "Duplicate script in connection queue");
                let record: Value = store.get("automation", id)?.context("Script not found")?;
                ensure!(
                    record["kind"] == "script" && record["trigger"] == "onConnect",
                    "Only onConnect scripts can be queued"
                );
            }
            let mut changes = vec![("scriptQueues", host.to_owned(), json!(ids))];
            for mut record in store.list::<Value>("automation")? {
                if record["kind"] != "script" || record["trigger"] != "onConnect" {
                    continue;
                }
                let mut targets = record["targets"].as_array().cloned().unwrap_or_default();
                targets.retain(|v| v.as_str().is_none_or(|id| !id.eq_ignore_ascii_case(host)));
                if ids.iter().any(|id| record["id"] == *id) {
                    targets.push(json!(host));
                }
                record["targets"] = json!(targets);
                changes.push(("automation", text(&record, "id").into(), record));
            }
            store.put_batch(&changes)?;
            Ok(json!({"hostId":host,"scriptIds":ids}))
        }
        "scripts_runs_list" => {
            let records = rt.store.lock().await.list::<Value>("scriptRuns")?;
            Ok(json!(records
                .into_iter()
                .filter(|r| r["conversationId"] == c.id
                    && (args["sessionId"].is_null() || r["sessionId"] == args["sessionId"]))
                .collect::<Vec<_>>()))
        }
        "scripts_run_stop" | "scripts_run_pause" | "scripts_run_resume" => {
            let runs = rt.scripts.runs.lock().await;
            let run = runs
                .get(text(args, "runId"))
                .filter(|r| r.conversation == c.id)
                .context("Run is not active in this conversation")?;
            if name == "scripts_run_stop" {
                run.cancel.cancel()
            } else {
                run.pause.send(name == "scripts_run_pause")?;
            }
            let status = if name == "scripts_run_stop" {
                "stopping"
            } else if name == "scripts_run_pause" {
                "pauseRequested"
            } else {
                "running"
            };
            Ok(json!({"runId":args["runId"],"status":status}))
        }
        "scripts_run" | "snippets_run" => {
            let record = match approved_script {
                Some(record) => record.clone(),
                None => definition(rt, id).await?,
            };
            ensure!(
                name != "scripts_run" || record["kind"] == "script",
                "scripts_run requires an automation script"
            );
            let environment = crate::tools::environment(rt, c).await;
            let sessions = environment["sessions"].as_array().unwrap();
            let session = if let Some(id) = args["sessionId"].as_str() {
                sessions
                    .iter()
                    .find(|s| s["sessionId"] == id)
                    .context("Session is outside this scope")?
            } else {
                ensure!(sessions.len() == 1, "Select a target session");
                &sessions[0]
            };
            let session_id = text(session, "sessionId").to_owned();
            if record["kind"] != "script" {
                let mut command = text(&record, "content").to_owned();
                let variables: HashMap<String, String> = if let Some(s) = args["variables"].as_str()
                {
                    serde_json::from_str(s)?
                } else {
                    HashMap::new()
                };
                for (key, value) in variables {
                    let placeholder = format!("{{{{{key}}}}}");
                    let occurrences = command.matches(&placeholder).count();
                    ensure!(
                        command
                            .len()
                            .saturating_add(occurrences.saturating_mul(value.len()))
                            <= 1024 * 1024,
                        "Expanded snippet exceeds 1 MiB"
                    );
                    command = command.replace(&placeholder, &value);
                }
                ensure!(!command.contains("{{"), "Snippet variables are missing");
                if record["noAutoRun"] == true {
                    let _lease = Lease {
                        runtime: rt.clone(),
                        run: None,
                        id: rt.terminal.reserve_script(&c.id, &session_id).await?,
                    };
                    return native(
                        rt,
                        &c.id,
                        "terminal_write",
                        json!({"sessionId":session_id,"text":command}),
                        cancel,
                    )
                    .await;
                }
                if record["multiLineRunMode"] == "lineDelay" {
                    let _lease = Lease {
                        runtime: rt.clone(),
                        run: None,
                        id: rt.terminal.reserve_script(&c.id, &session_id).await?,
                    };
                    for line in command.lines() {
                        native(
                            rt,
                            &c.id,
                            "terminal_write",
                            json!({"sessionId":session_id,"text":format!("{line}\r")}),
                            cancel,
                        )
                        .await?;
                        tokio::select! {_=cancel.cancelled()=>bail!("Cancelled"),_=tokio::time::sleep(Duration::from_millis(100))=>{}}
                    }
                    return Ok(
                        json!({"sent":true,"completion":"Commands were delivered; verify terminal results"}),
                    );
                }
                return rt
                    .terminal
                    .operate(
                        rt,
                        &c.id,
                        if boolean(args, "wait", true)? {
                            "terminal_execute"
                        } else {
                            "terminal_start"
                        },
                        &json!({"sessionId":session_id,"command":command}),
                        cancel,
                    )
                    .await;
            }
            let mut runs = rt.scripts.runs.lock().await;
            ensure!(runs.len() < 4, "At most four scripts may run concurrently");
            let lease = rt.terminal.reserve_script(&c.id, &session_id).await?;
            let run_id = uuid::Uuid::new_v4().to_string();
            let lease_guard = Lease {
                runtime: rt.clone(),
                id: lease.clone(),
                run: Some(run_id.clone()),
            };
            let token = rt.lifetime.child_token();
            let (pause, paused) = watch::channel(false);
            runs.insert(
                run_id.clone(),
                Handle {
                    conversation: c.id.clone(),
                    cancel: token.clone(),
                    pause,
                },
            );
            drop(runs);
            let run = json!({"id":run_id,"scriptId":record["id"],"sessionId":session_id,"conversationId":c.id,"status":"running","startedAt":crate::model::now(),"logs":[]});
            let saved = rt.store.lock().await.put("scriptRuns", &run_id, &run);
            if let Err(error) = saved {
                rt.scripts.runs.lock().await.remove(&run_id);
                rt.terminal.release_script(&lease).await;
                return Err(error);
            }
            let runtime = rt.clone();
            let conversation = c.id.clone();
            let spawned_id = run_id.clone();
            let handle = tokio::spawn(async move {
                let _lease = lease_guard;
                let mut run = run;
                let result = run_worker(
                    &runtime,
                    &conversation,
                    &session_id,
                    &record,
                    &mut run,
                    &token,
                    paused,
                )
                .await;
                runtime.terminal.release_script(&lease).await;
                run["status"] = json!(if token.is_cancelled() {
                    "stopped"
                } else if result.is_ok() {
                    "completed"
                } else {
                    "failed"
                });
                run["error"] = result
                    .as_ref()
                    .err()
                    .map(|e| json!(e.to_string()))
                    .unwrap_or(Value::Null);
                run["endedAt"] = json!(crate::model::now());
                runtime.scripts.runs.lock().await.remove(&spawned_id);
                runtime
                    .store
                    .lock()
                    .await
                    .put("scriptRuns", &spawned_id, &run)?;
                runtime
                    .emit(json!({"type":"scriptRun","run":run}), &conversation)
                    .await?;
                Ok::<_, anyhow::Error>(run)
            });
            if boolean(args, "wait", false)? {
                tokio::select! {_=cancel.cancelled()=>{rt.scripts.cancel_conversation(&c.id).await;bail!("Cancelled")},result=handle=>result?}
            } else {
                Ok(json!({"runId":run_id,"status":"running"}))
            }
        }
        _ => bail!("Unknown script operation"),
    }
}
async fn native(
    rt: &Arc<Runtime>,
    conversation: &str,
    name: &str,
    args: Value,
    cancel: &CancellationToken,
) -> Result<Value> {
    let value = rt
        .ask(
            conversation,
            "toolRequest",
            json!({"name":name,"arguments":args}),
            cancel,
        )
        .await?;
    ensure!(value["ok"] == true, "{}", text(&value, "error"));
    Ok(value["result"].clone())
}
async fn checkpoint(paused: &mut watch::Receiver<bool>, cancel: &CancellationToken) -> Result<()> {
    while *paused.borrow_and_update() {
        tokio::select! {_=cancel.cancelled()=>bail!("Cancelled"),r=paused.changed()=>r?}
    }
    ensure!(!cancel.is_cancelled(), "Cancelled");
    Ok(())
}
async fn run_worker(
    rt: &Arc<Runtime>,
    conversation: &str,
    session: &str,
    record: &Value,
    run: &mut Value,
    cancel: &CancellationToken,
    mut paused: watch::Receiver<bool>,
) -> Result<()> {
    let seed = native(
        rt,
        conversation,
        "terminal_read_context",
        json!({"sessionId":session,"range":"tail","maxLines":300}),
        cancel,
    )
    .await?;
    if rt.scripts.position(session).await == 0 {
        rt.scripts
            .feed(session, text(&seed, "text").as_bytes())
            .await;
    }
    let position = Arc::new(Mutex::new(0u64));
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let mut child = Command::new(std::env::current_exe()?)
        .arg("ai-script")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let (mut input, output) = (child.stdin.take().unwrap(), child.stdout.take().unwrap());
    #[cfg(any(target_os = "ios", target_os = "android"))]
    let (mut input, output, script_cancel, script_task) = {
        let (host, worker) = tokio::io::duplex(256 * 1024);
        let (read, write) = tokio::io::split(worker);
        let script_cancel = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop = script_cancel.clone();
        let task = tokio::task::spawn_blocking(move || {
            let mut reader = std::io::BufReader::new(tokio_util::io::SyncIoBridge::new(read));
            crate::script_worker::serve_io(
                &mut reader,
                tokio_util::io::SyncIoBridge::new(write),
                stop,
            )
        });
        let (read, write) = tokio::io::split(host);
        (write, read, script_cancel, task)
    };
    let c = rt.conversation(conversation).await?;
    let env = crate::tools::environment(rt, &c).await;
    let metadata = env["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == session)
        .context("Terminal disconnected")?;
    input.write_all(format!("{}\n",json!({"source":record["content"],"snapshot":{"screen":seed,"session":{"connected":true,"name":metadata["label"],"hostname":metadata["hostname"],"username":metadata["username"]}}})).as_bytes()).await?;
    let (tx, mut rx) = tokio::sync::mpsc::channel(128);
    let reader = tokio::spawn(async move {
        let mut output = BufReader::new(output);
        loop {
            let value = read_line(&mut output).await;
            let done = !matches!(&value, Ok(Some(_)));
            if tx.send(value).await.is_err() || done {
                break;
            }
        }
    });
    let mut requests = tokio::task::JoinSet::<(Value, Result<Value>)>::new();
    let result:Result<()>=async{loop {
        tokio::select!{
            _=cancel.cancelled()=>bail!("Cancelled"),
            Some(result)=requests.join_next()=>{let (id,result)=result?;let response=match result{Ok(value)=>json!({"id":id,"ok":true,"result":value}),Err(e)=>json!({"id":id,"ok":false,"error":e.to_string()})};input.write_all(format!("{response}\n").as_bytes()).await?;},
            value=rx.recv()=>{
                let value=value.context("Script process closed")??.context("Script exited without a final result")?;
                match text(&value,"type") {
                    "completed"=>return Ok(()),"failed"=>bail!("{}",text(&value,"error")),
                    "notify"=>{let method=text(&value,"method");ensure!(method=="log"||method.starts_with("progress."),"Unknown script notification");let logs=run["logs"].as_array_mut().context("Invalid run log")?;ensure!(logs.len()<512,"Script log limit exceeded");logs.push(json!({"method":method,"arguments":value["args"],"at":crate::model::now()}));rt.emit(json!({"type":"scriptActivity","runId":run["id"],"sessionId":session,"method":method,"arguments":value["args"]}),conversation).await?;},
                    "call"=>{ensure!(requests.len()<128,"Script host request limit exceeded");checkpoint(&mut paused,cancel).await?;let rt=rt.clone();let conversation=conversation.to_owned();let session=session.to_owned();let cancel=cancel.clone();let cursor=position.clone();let id=value["id"].clone();requests.spawn(async move{let result=host(&rt,&conversation,&session,text(&value,"method"),&value["args"],cursor,&cancel).await;(id,result)});},
                    _=>bail!("Invalid script worker event")
                }
            }
        }
        run["updatedAt"]=json!(crate::model::now());
    }}.await;
    requests.abort_all();
    reader.abort();
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        script_cancel.store(true, std::sync::atomic::Ordering::Release);
        drop(input);
        let _ = tokio::time::timeout(Duration::from_secs(6), script_task).await;
    }
    result
}
async fn host(
    rt: &Arc<Runtime>,
    conversation: &str,
    session: &str,
    method: &str,
    args: &Value,
    cursor: Arc<Mutex<u64>>,
    cancel: &CancellationToken,
) -> Result<Value> {
    let c = rt.conversation(conversation).await?;
    let env = crate::tools::environment(rt, &c).await;
    ensure!(
        env["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["sessionId"] == session),
        "Terminal disconnected or outside scope"
    );
    match method {
        "session.sleep" => {
            let ms = args[0].as_u64().unwrap_or(0).min(86400000);
            tokio::select! {_=cancel.cancelled()=>bail!("Cancelled"),_=tokio::time::sleep(Duration::from_millis(ms))=>{}}
            Ok(Value::Null)
        }
        "screen.waitSnapshot" => Ok(rt.scripts.output(session, *cursor.lock().await).await),
        "screen.consume" => {
            *cursor.lock().await = args[0].as_u64().context("Invalid output cursor")?;
            Ok(Value::Null)
        }
        "screen.send" | "screen.sendLine" => {
            *cursor.lock().await = rt.scripts.position(session).await;
            let value = args[0].as_str().unwrap_or("");
            native(
                rt,
                conversation,
                "terminal_write",
                json!({"sessionId":session,"text":value}),
                cancel,
            )
            .await?;
            if method == "screen.sendLine" {
                tokio::select! {_=cancel.cancelled()=>bail!("Cancelled"),_=tokio::time::sleep(Duration::from_millis(30))=>{}}
                native(
                    rt,
                    conversation,
                    "terminal_write",
                    json!({"sessionId":session,"text":"\r"}),
                    cancel,
                )
                .await?;
            }
            Ok(Value::Null)
        }
        "screen.getText" => {
            let value=native(rt,conversation,"terminal_read_context",json!({"sessionId":session,"range":"lines","startLine":args[0].as_u64().unwrap_or(0),"maxLines":args[1].as_u64().unwrap_or(299).saturating_sub(args[0].as_u64().unwrap_or(0)).saturating_add(1).clamp(1,300)}),cancel).await?;
            Ok(value)
        }
        "screen.clear" => {
            native(
                rt,
                conversation,
                "terminal_write",
                json!({"sessionId":session,"text":"\u{1b}[2J\u{1b}[H"}),
                cancel,
            )
            .await
        }
        "session.disconnect" => {
            native(
                rt,
                conversation,
                "session_close",
                json!({"sessionId":session}),
                cancel,
            )
            .await
        }
        "log" | "progress.start" | "progress.step" | "progress.set" | "progress.done" => {
            rt.emit(json!({"type":"scriptActivity","sessionId":session,"method":method,"arguments":args}),conversation).await?;
            Ok(Value::Null)
        }
        name if name.starts_with("dialog.") => {
            crate::forms::request(rt, conversation, name, args, cancel).await
        }
        _ => bail!("Script API {method} is not implemented"),
    }
}
// Resolve targets from current vault data so moving a host between groups takes
// effect without copying inherited group membership into host-specific queues.
fn target_host(vault: &termpilot_core::vault::Vault, id: &str) -> Result<(Value, String)> {
    let host = vault
        .get("hosts", &json!(id))
        .map_err(|e| anyhow::anyhow!(e.message))?
        .context("Host not found")?;
    let groups = vault
        .list("groups")
        .map_err(|e| anyhow::anyhow!(e.message))?;
    let mut parts = vec![];
    let mut parent = host["groupID"].clone();
    let mut seen = std::collections::HashSet::new();
    while let Some(group) = groups
        .iter()
        .find(|g| !parent.is_null() && g["id"] == parent)
    {
        ensure!(
            seen.insert(parent.to_string()),
            "Group hierarchy contains a cycle"
        );
        parts.push(text(group, "name").to_owned());
        parent = group["parentGroupID"].clone();
    }
    parts.reverse();
    Ok((host, parts.join("/")))
}
fn targets(record: &Value, host: &str, group: &str) -> bool {
    record["targetsAllHosts"] == true
        || record["targets"].as_array().is_some_and(|a| {
            a.iter()
                .any(|v| v.as_str().is_some_and(|v| v.eq_ignore_ascii_case(host)))
        })
        || record["targetGroups"].as_array().is_some_and(|a| {
            a.iter().any(|v| {
                v.as_str().is_some_and(|p| {
                    !p.is_empty() && (group == p || group.starts_with(&format!("{p}/")))
                })
            })
        })
}
pub async fn resolved_queue(rt: &Runtime, host: &str) -> Result<Vec<Value>> {
    let store = rt.store.lock().await;
    let (_, group) = target_host(&store.vault()?, host)?;
    let records = store.list::<Value>("automation")?;
    let manual: Vec<String> = store.get("scriptQueues", host)?.unwrap_or_default();
    let valid: Vec<_> = records
        .into_iter()
        .filter(|r| r["kind"] == "script" && r["trigger"] == "onConnect")
        .collect();
    let mut result: Vec<Value> = vec![];
    for all_hosts in [true, false] {
        for record in &valid {
            if (record["targetsAllHosts"] == true) == all_hosts
                && targets(record, host, &group)
                && !result.iter().any(|r| r["id"] == record["id"])
            {
                result.push(record.clone());
            }
        }
    }
    // Explicit host queues always follow global and inherited group scripts.
    result.retain(|r| {
        r["targetsAllHosts"] == true
            || r["targetGroups"].as_array().is_some_and(|a| {
                a.iter().any(|v| {
                    v.as_str()
                        .is_some_and(|p| group == p || group.starts_with(&format!("{p}/")))
                })
            })
    });
    let mut ids = manual;
    for record in &valid {
        if targets(record, host, "")
            && record["targetsAllHosts"] != true
            && !ids.iter().any(|id| record["id"] == *id)
        {
            ids.push(text(record, "id").into());
        }
    }
    for id in ids {
        if let Some(record) = valid.iter().find(|r| r["id"] == id) {
            if !result.iter().any(|r| r["id"] == id) {
                result.push(record.clone());
            }
        }
    }
    Ok(result)
}
impl Scheduler {
    pub async fn schedule_output(rt: &Arc<Runtime>, session: &str) {
        if !rt
            .scripts
            .output_pending
            .lock()
            .await
            .insert(session.into())
        {
            return;
        }
        let runtime = rt.clone();
        let session = session.to_owned();
        tokio::spawn(async move {
            tokio::select! { _=runtime.lifetime.cancelled()=>{},_=tokio::time::sleep(Duration::from_millis(100))=>{
                if let Err(error)=Scheduler::output_triggers(&runtime,&session).await {let _=runtime.emit(json!({"type":"error","message":format!("输出脚本触发器：{error}")}),"").await;}
            }}
            runtime.scripts.output_pending.lock().await.remove(&session);
        });
    }
    pub async fn context_changed(rt: &Arc<Runtime>, previous: &Value, current: &Value) {
        let old = previous["sessions"].as_array().cloned().unwrap_or_default();
        let sessions = current["sessions"].as_array().cloned().unwrap_or_default();
        let ids: std::collections::HashSet<String> = sessions
            .iter()
            .map(|s| text(s, "sessionId").into())
            .collect();
        rt.scripts
            .output
            .lock()
            .await
            .retain(|id, _| ids.contains(id));
        rt.scripts
            .trigger_positions
            .lock()
            .await
            .retain(|(id, _), _| ids.contains(id));
        rt.scripts
            .queues
            .lock()
            .await
            .retain(|id, _| ids.contains(id));
        for session in sessions {
            if old.iter().any(|s| s["sessionId"] == session["sessionId"])
                || text(&session, "hostId").is_empty()
            {
                continue;
            }
            let runtime = rt.clone();
            tokio::spawn(async move {
                match resolved_queue(&runtime, text(&session, "hostId")).await {
                    Ok(records) => {
                        for record in records {
                            Scheduler::enqueue(
                                &runtime,
                                text(&session, "sessionId"),
                                text(&record, "id"),
                            )
                            .await;
                        }
                    }
                    Err(e) => {
                        let _ = runtime
                            .emit(
                                json!({"type":"error","message":format!("连接脚本队列：{e}")}),
                                "",
                            )
                            .await;
                    }
                }
            });
        }
    }
    pub async fn output_triggers(rt: &Arc<Runtime>, session: &str) -> Result<()> {
        let context = rt.context.lock().await.clone();
        let Some(metadata) = context["sessions"]
            .as_array()
            .and_then(|a| a.iter().find(|s| s["sessionId"] == session))
        else {
            return Ok(());
        };
        let host = text(metadata, "hostId");
        if host.is_empty() {
            return Ok(());
        }
        let (records, vault) = {
            let store = rt.store.lock().await;
            (store.list::<Value>("automation")?, store.vault()?)
        };
        let records: Vec<_> = records
            .into_iter()
            .filter(|r| r["kind"] == "script" && r["trigger"] == "onOutput")
            .collect();
        if records.is_empty() {
            return Ok(());
        }
        let (_, group) = target_host(&vault, host)?;
        let end = rt.scripts.position(session).await;
        let snapshot = rt.scripts.output(session, end.saturating_sub(16384)).await;
        let buffer = text(&snapshot, "text");
        let start = end.saturating_sub(buffer.len() as u64);
        for record in records {
            if !targets(&record, host, &group) {
                continue;
            }
            let re = regex::Regex::new(text(&record, "triggerPattern"))?;
            let Some(matched) = re.find_iter(buffer).last() else {
                continue;
            };
            let position = start + matched.end() as u64;
            let key = (session.to_owned(), text(&record, "id").to_owned());
            let mut seen = rt.scripts.trigger_positions.lock().await;
            if position <= *seen.get(&key).unwrap_or(&0) {
                continue;
            }
            seen.insert(key, position);
            drop(seen);
            Scheduler::enqueue(rt, session, text(&record, "id")).await;
        }
        Ok(())
    }
    async fn enqueue(rt: &Arc<Runtime>, session: &str, script: &str) {
        let mut recent = rt.scripts.trigger_times.lock().await;
        let times = recent.entry(session.into()).or_default();
        while times
            .front()
            .is_some_and(|t| t.elapsed() > Duration::from_secs(60))
        {
            times.pop_front();
        }
        if times.len() >= 16 {
            drop(recent);
            let _=rt.emit(json!({"type":"error","message":"自动脚本已达到每个终端每分钟 16 次触发限制，请检查脚本是否重复触发自身。"}),"").await;
            return;
        }
        times.push_back(std::time::Instant::now());
        drop(recent);
        let mut queues = rt.scripts.queues.lock().await;
        let queue = queues.entry(session.into()).or_default();
        if queue.len() >= 32 || queue.iter().any(|id| id == script) {
            return;
        }
        queue.push_back(script.into());
        let mut draining = rt.scripts.draining.lock().await;
        if !draining.insert(session.into()) {
            return;
        }
        drop(draining);
        drop(queues);
        let runtime = rt.clone();
        let session = session.to_owned();
        tokio::spawn(async move {
            loop {
                // Queue and worker ownership change under the same locks as enqueue.
                let mut queues = runtime.scripts.queues.lock().await;
                let next = queues.get_mut(&session).and_then(VecDeque::pop_front);
                let Some(script) = next else {
                    runtime.scripts.draining.lock().await.remove(&session);
                    break;
                };
                drop(queues);
                if runtime.lifetime.is_cancelled() {
                    runtime.scripts.draining.lock().await.remove(&session);
                    break;
                }
                let mut conversation = Conversation::new(session.clone(), "automation".into());
                conversation.title = "自动脚本".into();
                if runtime.save(&mut conversation).await.is_err() {
                    runtime.scripts.draining.lock().await.remove(&session);
                    break;
                }
                let result = crate::tools::call(
                    &runtime,
                    &conversation.id,
                    "scripts_run",
                    json!({"scriptId":script,"sessionId":session,"wait":"true"}),
                    &runtime.lifetime,
                )
                .await;
                if let Err(error) = result {
                    let _ = runtime
                        .emit(
                            json!({"type":"error","message":format!("自动脚本：{error}")}),
                            &conversation.id,
                        )
                        .await;
                }
            }
        });
    }
}
