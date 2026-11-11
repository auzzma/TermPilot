//! Authenticated loopback MCP transport plus native stdio/CLI entry points.
use crate::{
    model::{text, Conversation},
    read_line, tools, Runtime,
};
use anyhow::{bail, ensure, Context, Result};
use axum::{
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
    Json, Router,
};
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    convert::Infallible,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    sync::{broadcast, Mutex, Semaphore},
};
use tokio_util::sync::CancellationToken;

pub struct Endpoint {
    pub url: String,
    pub token: String,
    pub cancel: CancellationToken,
    pub expires: u64,
    pub discovery: PathBuf,
}
impl Endpoint {
    pub fn public(&self) -> Value {
        json!({"enabled":!self.cancel.is_cancelled(),"url":self.url,"expires":self.expires,"discovery":self.discovery})
    }
}
impl Drop for Endpoint {
    fn drop(&mut self) {
        self.cancel.cancel();
        // Another app window may have published a newer endpoint at the shared
        // discovery path. Never remove that window's token on our shutdown.
        if std::fs::read(&self.discovery)
            .ok()
            .and_then(|v| serde_json::from_slice::<Value>(&v).ok())
            .is_some_and(|v| v["token"] == self.token)
        {
            let _ = std::fs::remove_file(&self.discovery);
        }
    }
}
#[derive(Clone)]
struct Server {
    runtime: Arc<Runtime>,
    token: String,
    scope: String,
    cancel: CancellationToken,
    expires: u64,
    sessions: Arc<Mutex<HashMap<String, Arc<ClientSession>>>>,
    conversation: Option<String>,
    activity: Arc<AtomicU64>,
    idle_seconds: u64,
}
struct ClientSession {
    conversation: String,
    cancel: CancellationToken,
    loaded: Mutex<HashSet<String>>,
    changes: broadcast::Sender<Value>,
    requests: Mutex<HashMap<String, CancellationToken>>,
    limit: Semaphore,
}
fn toolsets() -> HashMap<String, Vec<String>> {
    serde_json::from_str(include_str!("mcp_toolsets.json")).expect("bundled MCP toolsets")
}
fn loader() -> Value {
    json!({"name":"load_termpilot_tools","description":"Load TermPilot tools by category, then refresh tools/list. Categories: attachments, sftp_advanced, vault_hosts, vault_notes, snippets, scripts, portforward, all.","inputSchema":{"type":"object","properties":{"toolset":{"type":"string","enum":["attachments","sftp_advanced","vault_hosts","vault_notes","snippets","scripts","portforward","all"]}},"required":["toolset"],"additionalProperties":false}})
}
pub async fn enable(runtime: Arc<Runtime>, params: &Value) -> Result<Value> {
    disable(&runtime).await;
    let endpoint = start(runtime.clone(), params, false).await?;
    let info = endpoint.public();
    *runtime.mcp.lock().await = Some(endpoint);
    Ok(info)
}
pub async fn start(runtime: Arc<Runtime>, params: &Value, internal: bool) -> Result<Endpoint> {
    let c = if !internal && text(params, "conversationId").is_empty() {
        Conversation::new("workspace".into(), "external".into())
    } else {
        runtime.conversation(text(params, "conversationId")).await?
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}/mcp", listener.local_addr()?);
    let token = format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    );
    let cancel = runtime.lifetime.child_token();
    let access = runtime.settings.lock().await.tool_access.clone();
    let configured = !internal && params["configured"] == true;
    let idle_seconds = if configured && access.availability == "temporary" {
        access.idle_minutes * 60
    } else {
        0
    };
    let seconds = if configured {
        10 * 365 * 86400
    } else {
        params["durationSeconds"]
            .as_u64()
            .unwrap_or(3600)
            .clamp(60, 86400)
    };
    let expires = crate::model::now() + seconds;
    let discovery = runtime.store.lock().await.directory.join(if internal {
        format!("ai-mcp-{}.json", uuid::Uuid::new_v4())
    } else {
        "ai-mcp.json".into()
    });
    let value = json!({"url":url,"token":token,"expires":expires,"instance":uuid::Uuid::new_v4().to_string()});
    {
        use std::io::Write;
        let temp = discovery.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        let mut options = std::fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp)?;
        file.write_all(serde_json::to_string(&value)?.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(temp, &discovery)?;
    }
    let activity = Arc::new(AtomicU64::new(crate::model::now()));
    let state = Server {
        runtime: runtime.clone(),
        token: token.clone(),
        scope: c.scope,
        cancel: cancel.clone(),
        expires,
        sessions: Arc::new(Mutex::new(HashMap::new())),
        conversation: internal.then_some(c.id),
        activity: activity.clone(),
        idle_seconds,
    };
    let app = Router::new()
        .route("/mcp", post(handle).delete(close).get(events))
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
        .with_state(state);
    let shutdown = cancel.clone();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(shutdown.cancelled_owned())
            .await;
    });
    let expiry = cancel.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {_=expiry.cancelled()=>break,_=tokio::time::sleep(Duration::from_secs(1))=>{
                let now = crate::model::now();
                if now >= expires || (idle_seconds > 0 && now.saturating_sub(activity.load(Ordering::Relaxed)) >= idle_seconds) { expiry.cancel(); break; }
            }}
        }
    });
    let endpoint = Endpoint {
        url,
        token,
        cancel,
        expires,
        discovery,
    };
    Ok(endpoint)
}
pub async fn disable(runtime: &Runtime) {
    if let Some(endpoint) = runtime.mcp.lock().await.take() {
        endpoint.cancel.cancel();
    }
}
fn authenticated(s: &Server, h: &HeaderMap) -> bool {
    if s.cancel.is_cancelled() || crate::model::now() >= s.expires || h.contains_key("origin") {
        return false;
    }
    let expected = format!("Bearer {}", s.token);
    let given = h
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if expected.len() != given.len() {
        return false;
    }
    let valid = expected
        .bytes()
        .zip(given.bytes())
        .fold(0u8, |a, (x, y)| a | (x ^ y))
        == 0;
    let now = crate::model::now();
    if s.idle_seconds > 0
        && now.saturating_sub(s.activity.load(Ordering::Relaxed)) >= s.idle_seconds
    {
        s.cancel.cancel();
        return false;
    }
    if valid {
        s.activity.store(now, Ordering::Relaxed);
    }
    valid
}

pub async fn integration_info(runtime: &Runtime) -> Result<Value> {
    let directory = runtime.store.lock().await.directory.clone();
    let launcher = std::env::current_exe()?;
    let discovery = directory.join("ai-mcp.json");
    let config = json!({"mcpServers":{"TermPilot":{"command":launcher,"args":["ai-mcp"],"env":{"TERMPILOT_MCP_DISCOVERY":discovery}}}});
    // JSON-quoted strings are valid TOML basic strings as well. This is display
    // text, never shell-executed by TermPilot.
    let toml = format!("[mcp_servers.TermPilot]\ncommand = {}\nargs = [\"ai-mcp\"]\nenv = {{ TERMPILOT_MCP_DISCOVERY = {} }}\n", serde_json::to_string(&launcher)?, serde_json::to_string(&discovery)?);
    let skills = directory.join("Skills");
    std::fs::create_dir_all(&skills)?;
    let status = runtime
        .mcp
        .lock()
        .await
        .as_ref()
        .map(Endpoint::public)
        .unwrap_or(json!({"enabled":false}));
    Ok(
        json!({"launcher":launcher,"discovery":discovery,"skillsDirectory":skills,"status":status,"clients":{"codex":toml,"claude":serde_json::to_string_pretty(&config)?,"cursor":serde_json::to_string_pretty(&config)?,"grok":serde_json::to_string_pretty(&config)?}}),
    )
}
async fn close(State(s): State<Server>, headers: HeaderMap) -> Response {
    if !authenticated(&s, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let id = headers
        .get("mcp-session-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if let Some(session) = s.sessions.lock().await.remove(id) {
        session.cancel.cancel();
    }
    StatusCode::NO_CONTENT.into_response()
}
async fn events(State(s): State<Server>, headers: HeaderMap) -> Response {
    use axum::response::sse::{Event, KeepAlive, Sse};
    if !authenticated(&s, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let id = headers
        .get("mcp-session-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let Some(session) = s.sessions.lock().await.get(id).cloned() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let stream = futures_util::stream::unfold(
        (session.changes.subscribe(), session.cancel.clone()),
        |(mut rx, cancel)| async move {
            loop {
                tokio::select! {_=cancel.cancelled()=>return None,v=rx.recv()=>match v{Ok(v)=>return Some((Ok::<_,Infallible>(Event::default().event("message").data(v.to_string())),(rx,cancel))),Err(broadcast::error::RecvError::Lagged(_))=>continue,Err(_)=>return None}}
            }
        },
    );
    Sse::new(stream)
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
        .into_response()
}
async fn handle(
    State(s): State<Server>,
    headers: HeaderMap,
    Json(request): Json<Value>,
) -> Response {
    if !authenticated(&s, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let id = request["id"].clone();
    let method = text(&request, "method");
    if method == "initialize" {
        let session = uuid::Uuid::new_v4().to_string();
        let c = if let Some(id) = &s.conversation {
            match s.runtime.conversation(id).await {
                Ok(c) => c,
                Err(_) => return StatusCode::NOT_FOUND.into_response(),
            }
        } else {
            Conversation::new(s.scope.clone(), "external".into())
        };
        let mut sessions = s.sessions.lock().await;
        if sessions.len() >= 16 {
            return StatusCode::TOO_MANY_REQUESTS.into_response();
        }
        if s.runtime
            .store
            .lock()
            .await
            .put("conversations", &c.id, &c)
            .is_err()
        {
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
        let client = Arc::new(ClientSession {
            conversation: c.id.clone(),
            cancel: s.cancel.child_token(),
            loaded: Mutex::new(toolsets().remove("core").unwrap().into_iter().collect()),
            changes: broadcast::channel(32).0,
            requests: Mutex::new(HashMap::new()),
            limit: Semaphore::new(4),
        });
        // A standalone client owns its jobs. Revoking that client also cancels
        // work already returned by terminal_start/scripts_run. Internal clients
        // share the panel turn's lifetime and must not cancel each other.
        if s.conversation.is_none() {
            let runtime = s.runtime.clone();
            let stopped = client.cancel.clone();
            let conversation = c.id.clone();
            tokio::spawn(async move {
                stopped.cancelled().await;
                runtime.scripts.cancel_conversation(&conversation).await;
                runtime
                    .terminal
                    .cancel_conversation(&runtime, &conversation)
                    .await;
            });
        }
        sessions.insert(session.clone(), client);
        return ([("mcp-session-id",session)],Json(json!({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"TermPilot","version":env!("CARGO_PKG_VERSION")},"capabilities":{"tools":{"listChanged":true}},"instructions":tools::SYSTEM}}))).into_response();
    }
    let session = headers
        .get("mcp-session-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let session = s.sessions.lock().await.get(session).cloned();
    let Some(session) = session else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if id.is_null() {
        if method == "notifications/cancelled" {
            if let Some(cancel) = session
                .requests
                .lock()
                .await
                .get(&request["params"]["requestId"].to_string())
            {
                cancel.cancel();
            }
        }
        return StatusCode::ACCEPTED.into_response();
    }
    let Ok(_permit) = session.limit.try_acquire() else {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    };
    let result = match method {
        "ping" => Ok(json!({})),
        "tools/list" => {
            let loaded = session.loaded.lock().await;
            let mut available: Vec<_> = tools::available(&s.runtime)
                .await
                .into_iter()
                .filter(|t| loaded.contains(text(t, "name")))
                .collect();
            available.push(loader());
            Ok(json!({"tools":available}))
        }
        "tools/call" => {
            let params = &request["params"];
            let name = text(params, "name");
            if name == "load_termpilot_tools" {
                let category = text(&params["arguments"], "toolset");
                let mut sets = toolsets();
                sets.remove("core");
                let requested = if category == "all" {
                    Some(sets.into_values().flatten().collect::<Vec<_>>())
                } else {
                    sets.remove(category)
                };
                if let Some(requested) = requested {
                    let available = tools::available(&s.runtime).await;
                    let mut loaded = session.loaded.lock().await;
                    let mut new = vec![];
                    let mut unavailable = vec![];
                    for name in requested {
                        if available.iter().any(|v| v["name"] == name) {
                            if loaded.insert(name.clone()) {
                                new.push(name);
                            }
                        } else {
                            unavailable.push(name);
                        }
                    }
                    if !new.is_empty() {
                        let _ = session.changes.send(
                            json!({"jsonrpc":"2.0","method":"notifications/tools/list_changed"}),
                        );
                    }
                    Ok(
                        json!({"content":[{"type":"text","text":json!({"newlyLoaded":new,"unavailable":unavailable,"loadedCatalogToolCount":loaded.len()}).to_string()}],"isError":false}),
                    )
                } else {
                    Err(anyhow::anyhow!("Unknown tool category"))
                }
            } else if !session.loaded.lock().await.contains(name) {
                Ok(
                    json!({"content":[{"type":"text","text":"Tool not loaded. Call load_termpilot_tools first."}],"isError":true}),
                )
            } else {
                let cancel = session.cancel.child_token();
                {
                    let mut pending = session.requests.lock().await;
                    if pending.contains_key(&id.to_string()) {
                        return Json(json!({"jsonrpc":"2.0","id":id,"error":{"code":-32600,"message":"Duplicate active request id"}})).into_response();
                    }
                    pending.insert(id.to_string(), cancel.clone());
                }
                let result = match tools::call(
                    &s.runtime,
                    &session.conversation,
                    text(params, "name"),
                    params["arguments"]
                        .as_object()
                        .map(|v| json!(v))
                        .unwrap_or(json!({})),
                    &cancel,
                )
                .await
                {
                    Ok(v) => Ok(
                        json!({"content":[{"type":"text","text":v.to_string()}],"isError":false}),
                    ),
                    Err(e) => {
                        Ok(json!({"content":[{"type":"text","text":e.to_string()}],"isError":true}))
                    }
                };
                session.requests.lock().await.remove(&id.to_string());
                result
            }
        }
        _ => Err(anyhow::anyhow!("Unknown MCP method")),
    };
    Json(match result {
        Ok(v) => json!({"jsonrpc":"2.0","id":id,"result":v}),
        Err(e) => json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":e.to_string()}}),
    })
    .into_response()
}
async fn discovery() -> Result<Value> {
    let path = std::env::var("TERMPILOT_MCP_DISCOVERY")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_directory().join("ai-mcp.json"));
    let v: Value = serde_json::from_slice(
        &tokio::fs::read(path)
            .await
            .context("Enable external AI access in TermPilot first")?,
    )?;
    ensure!(
        v["expires"].as_u64().unwrap_or(0) > crate::model::now(),
        "TermPilot external access expired"
    );
    let url = reqwest::Url::parse(text(&v, "url"))?;
    ensure!(
        url.host_str() == Some("127.0.0.1") && url.scheme() == "http",
        "MCP discovery must point to this computer"
    );
    Ok(v)
}
pub fn default_directory() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
            .join("Library/Application Support/TermPilot")
    }
    #[cfg(target_os = "windows")]
    {
        let executable = std::env::current_exe().expect("Locate the TermPilot engine");
        let directory = executable.parent().expect("TermPilot engine directory");
        // Published engine: <product>/app/engine/termpilot-engine.exe.
        let payload = if directory
            .file_name()
            .is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case("engine"))
        {
            directory.parent().unwrap_or(directory)
        } else {
            directory
        };
        let root = if payload
            .file_name()
            .is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case("app"))
            && payload
                .parent()
                .is_some_and(|parent| parent.join("TermPilot.exe").is_file())
        {
            payload.parent().unwrap()
        } else {
            payload
        };
        root.join("AppData")
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share/TermPilot")
    }
}
async fn exchange(
    c: &reqwest::Client,
    d: &Value,
    session: &mut String,
    r: &Value,
) -> Result<Option<Value>> {
    let mut request = c
        .post(text(d, "url"))
        .bearer_auth(text(d, "token"))
        .header("accept", "application/json, text/event-stream")
        .header("MCP-Protocol-Version", "2025-03-26")
        .json(r);
    if !session.is_empty() {
        request = request.header("Mcp-Session-Id", session.as_str());
    }
    let response = request
        .send()
        .await
        .context("TermPilot MCP connection failed")?;
    ensure!(
        response.status().is_success(),
        "TermPilot MCP HTTP {}",
        response.status().as_u16()
    );
    if let Some(s) = response.headers().get("mcp-session-id") {
        *session = s.to_str()?.into();
    }
    if response.status() == StatusCode::ACCEPTED {
        return Ok(None);
    }
    Ok(Some(response.json().await?))
}
pub async fn stdio_proxy() -> Result<()> {
    let d = discovery().await?;
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(310))
        .build()?;
    let mut session = String::new();
    let mut input = BufReader::new(tokio::io::stdin());
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Value>(128);
    let writer = tokio::spawn(async move {
        let mut output = tokio::io::stdout();
        while let Some(reply) = rx.recv().await {
            let mut bytes = serde_json::to_vec(&reply)?;
            bytes.push(10);
            output.write_all(&bytes).await?;
            output.flush().await?;
        }
        Ok::<_, anyhow::Error>(())
    });
    let first = read_line(&mut input)
        .await?
        .context("MCP initialization required")?;
    ensure!(
        first["method"] == "initialize",
        "MCP initialization required"
    );
    if let Some(reply) = exchange(&client, &d, &mut session, &first).await? {
        tx.send(reply).await?;
    }
    let notifications = {
        let d = d.clone();
        let session = session.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            let client = reqwest::Client::builder().no_proxy().build()?;
            let response = client
                .get(text(&d, "url"))
                .bearer_auth(text(&d, "token"))
                .header("mcp-session-id", session)
                .header("accept", "text/event-stream")
                .send()
                .await?
                .error_for_status()?;
            let mut stream = response.bytes_stream();
            let mut parser = crate::provider::Sse::default();
            while let Some(bytes) = stream.next().await {
                for data in parser.push(&bytes?)? {
                    if let Ok(v) = serde_json::from_str(&data) {
                        tx.send(v).await?;
                    }
                }
            }
            Ok::<_, anyhow::Error>(())
        })
    };
    let mut requests = tokio::task::JoinSet::new();
    let read_result:Result<()>=async {while let Some(request)=read_line(&mut input).await? {
        while requests.try_join_next().is_some(){}
        if requests.len()>=32 {tx.send(json!({"jsonrpc":"2.0","id":request["id"],"error":{"code":-32000,"message":"Too many MCP requests"}})).await?;continue;}
        let client=client.clone();let d=d.clone();let mut session=session.clone();let tx=tx.clone();
        requests.spawn(async move{let result=exchange(&client,&d,&mut session,&request).await;match result{Ok(Some(v))=>{let _=tx.send(v).await;},Err(e)=>{let _=tx.send(json!({"jsonrpc":"2.0","id":request["id"],"error":{"code":-32000,"message":e.to_string()}})).await;},_=>{}}});
    }Ok(())}.await;
    if !session.is_empty() {
        let _ = client
            .delete(text(&d, "url"))
            .bearer_auth(text(&d, "token"))
            .header("mcp-session-id", session)
            .send()
            .await;
    }
    requests.abort_all();
    notifications.abort();
    drop(tx);
    let _ = tokio::time::timeout(Duration::from_secs(2), writer).await;
    read_result
}
pub async fn tool_cli() -> Result<()> {
    let name = std::env::args()
        .nth(2)
        .context("Usage: termpilot-engine ai-tool TOOL; JSON arguments are read from stdin")?;
    let args = if let Some(raw) = std::env::args().nth(3) {
        ensure!(raw.len() <= 2 * 1024 * 1024, "CLI arguments too large");
        serde_json::from_str(&raw)?
    } else {
        read_line(&mut BufReader::new(tokio::io::stdin()))
            .await?
            .unwrap_or(json!({}))
    };
    if name == "tools_list" {
        println!("{}", json!(crate::tools::catalog()));
        return Ok(());
    }
    let d = discovery().await?;
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(310))
        .build()?;
    let mut session = String::new();
    exchange(&client,&d,&mut session,&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"TermPilot CLI","version":"1"}}})).await?;
    exchange(&client,&d,&mut session,&json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"load_termpilot_tools","arguments":{"toolset":"all"}}})).await?;
    let result=exchange(&client,&d,&mut session,&json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":name,"arguments":args}})).await?.context("No tool response")?;
    let _ = client
        .delete(text(&d, "url"))
        .bearer_auth(text(&d, "token"))
        .header("mcp-session-id", session)
        .send()
        .await;
    println!("{result}");
    if result["result"]["isError"] == true || result.get("error").is_some() {
        bail!("Tool failed")
    };
    Ok(())
}
