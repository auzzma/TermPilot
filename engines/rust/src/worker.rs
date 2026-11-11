use crate::{
    files::Files,
    ipc::{self, number, text, Events},
    ssh::{decode_data, Prompts, Session},
};
use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncWrite, BufReader},
    sync::{mpsc, Mutex},
    task::JoinSet,
};
use tokio_util::sync::CancellationToken;

pub struct Shared {
    pub config: Value,
    session: Mutex<Option<Arc<Session>>>,
    pub prompts: Prompts,
}
impl Shared {
    pub fn new(mut config: Value) -> Arc<Self> {
        if text(&config, "sessionID").is_empty() {
            config["sessionID"] = json!(uuid::Uuid::new_v4().to_string());
        }
        Arc::new(Self {
            config,
            session: Mutex::new(None),
            prompts: Prompts::default(),
        })
    }
    pub async fn close(&self) {
        if let Some(s) = self.session.lock().await.take() {
            s.close().await;
        }
    }
    async fn connect(&self, events: Events) -> Result<Arc<Session>> {
        // A native reconnect keeps its connection ID. Serialize new handshakes
        // while allowing a dead transport to be replaced immediately, without
        // waiting for the broker's idle timeout or disrupting live siblings.
        let mut current = self.session.lock().await;
        if let Some(session) = current.as_ref() {
            if !session.cancel.is_cancelled() && !session.handle.is_closed() {
                return Ok(session.clone());
            }
        }
        *current = None;
        let session = Session::connect(self.config.clone(), events, self.prompts.clone()).await?;
        *current = Some(session.clone());
        Ok(session)
    }
}
pub async fn serve<R, W>(
    read: R,
    write: W,
    shared: Option<Arc<Shared>>,
    first: Option<Value>,
) -> Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (events, mut outbound) = mpsc::channel::<Value>(64);
    let (tx, mut inbound) = mpsc::channel::<Value>(32);
    let cancel = CancellationToken::new();
    let output_cancel = cancel.clone();
    let output = tokio::spawn(async move {
        let mut write = write;
        while let Some(value) = outbound.recv().await {
            if ipc::write_json(&mut write, &value).await.is_err() {
                break;
            }
        }
        output_cancel.cancel();
    });
    let input_cancel = cancel.clone();
    let input = tokio::spawn(async move {
        let mut read = BufReader::new(read);
        while let Ok(Some(value)) = ipc::read_json(&mut read).await {
            if tx.send(value).await.is_err() {
                break;
            }
        }
        input_cancel.cancel();
    });
    let mut tasks = JoinSet::new();
    let mut active_session: Option<Arc<Session>> = None;
    let owned = shared.is_none();
    let mut file_channels: HashMap<String, Arc<Files>> = HashMap::new();
    let mut owned_forwards = Vec::new();
    let work=async{
        let first=match first{Some(value)=>value,None=>inbound.recv().await.context("Missing connection command")?};
        let shared=shared.unwrap_or_else(||Shared::new(first["config"].clone()));
        let connect=shared.connect(events.clone());
        tokio::pin!(connect);let mut pending=Vec::new();
        let session=loop{tokio::select!{
            _=cancel.cancelled()=>bail!("Client disconnected"),
            session=&mut connect=>break session?,
            command=inbound.recv()=>{let command=command.context("Client disconnected")?;if matches!(text(&command,"type"),"hostKeyResponse"|"credentialResponse"){shared.prompts.answer(&command).await;}else{ensure!(pending.len()<32,"Too many commands while connecting");pending.push(command);}}
        }};
        active_session=Some(session.clone());
        let mut terminal=None;
        let mut queued=std::collections::VecDeque::new();queued.push_back(if text(&first,"type")=="connect"{json!({"type":"open","cols":number(&first,"cols",80),"rows":number(&first,"rows",24),"sessionID":text(&shared.config,"sessionID")})}else{first});queued.extend(pending);
        loop{
            let command=if let Some(command)=queued.pop_front(){command}else{tokio::select!{_=cancel.cancelled()=>break,_=session.cancel.cancelled()=>break,command=inbound.recv()=>match command{Some(c)=>c,None=>break}}};
            let kind=text(&command,"type");match kind{
                "hostKeyResponse"|"credentialResponse"=>shared.prompts.answer(&command).await,
                "forwardOpen"=>{
                    let rule=command["forwardRule"].clone();
                    session.forward(&rule,true).await?;owned_forwards.push(rule);
                    ipc::event(&events,json!({"type":"log","status":"connected","message":"Port forwarding active"})).await?;
                },
                "open"=>{
                    ensure!(terminal.is_none(),"Terminal already opened");let(tx,rx)=mpsc::channel(32);terminal=Some(tx);let(s,e,stop)=(session.clone(),events.clone(),cancel.child_token());
                    tasks.spawn(async move{if let Err(error)=terminal_loop(s,command,rx,e.clone(),stop).await{let _=ipc::event(&e,json!({"type":"error","channel":"terminal","message":error.to_string()})).await;}});
                },
                "data"|"resize"=>{terminal.as_ref().context("Terminal is not open")?.send(command).await?;},
                "sftpOpen"|"execOpen"=>{
                    let channel=if kind=="sftpOpen"{"files"}else{"exec"};let mut options=command["config"].clone();if !options.is_object(){options=json!({});}
if kind=="execOpen"{options["execOnly"]=json!(true);}
                    match Files::open(session.clone(),options).await{
                        Ok(files)=>{let mode=if kind=="execOpen"{"exec"}else{files.mode()};ipc::event(&events,json!({"type":if kind=="execOpen"{"execReady"}else{"sftpReady"},"channel":channel,"mode":mode})).await?;if let Some(old)=file_channels.insert(channel.into(),files){old.shutdown().await;}},
                        Err(error)=>ipc::event(&events,json!({"type":"error","channel":channel,"message":error.to_string()})).await?,
                    }
                },
                "sftpRequest"=>{
                    let channel=if text(&command,"channel").is_empty(){if file_channels.contains_key("files"){"files"}else{"exec"}}else{text(&command,"channel")};
                    let request=command["request"].clone();let events=events.clone();let channel=channel.to_string();
                    if tasks.len()>=256 && !matches!(text(&request,"action"),"cancel"|"pause"|"resume") {ipc::response(&events,&channel,request["id"].clone(),Err(anyhow::anyhow!("Connection task queue is full"))).await?;continue;}
                    if let Some(files)=file_channels.get(&channel).cloned(){tasks.spawn(async move{let id=request["id"].clone();let result=files.request(request,events.clone(),channel.clone()).await;let _=ipc::response(&events,&channel,id,result).await;});}
                    else{ipc::response(&events,&channel,request["id"].clone(),Err(anyhow::anyhow!("File channel is not open"))).await?;}
                },
                "close"=>{let channel=text(&command,"channel");if channel.is_empty()||channel=="terminal"{break;}
if let Some(files) = file_channels.remove(channel) { files.shutdown().await; }},
                _=>ipc::event(&events,json!({"type":"error","message":"Unknown connection command"})).await?,
            }
            while tasks.try_join_next().is_some(){}
        }
        drop(terminal);Ok::<_,anyhow::Error>(())
    }.await;
    if let Err(error) = &work {
        let _ = ipc::event(&events, json!({"type":"error","message":error.to_string()})).await;
    }
    cancel.cancel();
    for files in file_channels.values() {
        files.shutdown().await;
    }
    if let Some(session) = active_session {
        for rule in owned_forwards {
            let _ =
                tokio::time::timeout(Duration::from_secs(2), session.forward(&rule, false)).await;
        }
        if owned {
            session.close().await;
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(35), async {
        while tasks.join_next().await.is_some() {}
    })
    .await;
    input.abort();
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    drop(events);
    let _ = tokio::time::timeout(Duration::from_secs(2), output).await;
    work
}
async fn terminal_loop(
    session: Arc<Session>,
    open: Value,
    mut commands: mpsc::Receiver<Value>,
    events: Events,
    cancel: CancellationToken,
) -> Result<()> {
    let id = if text(&open, "sessionID").is_empty() {
        uuid::Uuid::new_v4().to_string()
    } else {
        text(&open, "sessionID").into()
    };
    let registration = session.terminal_registration.lock().await;
    let mut channel = tokio::select! {
        _ = cancel.cancelled() => bail!("Terminal cancelled"),
        _ = session.cancel.cancelled() => bail!("Connection closed"),
        result = session.open_session_channel() => result?,
    };
    channel
        .request_pty(
            true,
            "xterm-256color",
            number(&open, "cols", 80).clamp(1, 1000) as u32,
            number(&open, "rows", 24).clamp(1, 1000) as u32,
            0,
            0,
            &[],
        )
        .await?;
    channel.set_env(false, "TERM_PROGRAM", "TermPilot").await?;
    channel.set_env(false, "COLORTERM", "truecolor").await?;
    channel.request_shell(true).await?;
    for attempt in 0..4 {
        if session.register_terminal(&id).await.is_ok() {
            break;
        }
        if attempt < 3 {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
    drop(registration);
    ipc::event(&events,json!({"type":"log","channel":"terminal","status":"connected","message":"Interactive shell connected"})).await?;
    ipc::event(
        &events,
        json!({"type":"user","username":text(&session.config,"username")}),
    )
    .await?;
    let probe_cancel = cancel.child_token();
    let _probe_guard = CancelOnDrop(probe_cancel.clone());
    let (probe_session, probe_events) = (session.clone(), events.clone());
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(5));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {_=probe_cancel.cancelled()=>break,_=probe_session.cancel.cancelled()=>break,_=interval.tick()=>{}}
            let started = std::time::Instant::now();
            // Measure this SSH transport, including its proxy, without starting
            // a shell process or depending on the remote OS / exec permissions.
            let result = tokio::select! {
                _ = probe_cancel.cancelled() => break,
                _ = probe_session.cancel.cancelled() => break,
                result = tokio::time::timeout(Duration::from_secs(3), probe_session.handle.send_ping()) => result,
            };
            if probe_cancel.is_cancelled() || probe_session.cancel.is_cancelled() {
                break;
            }
            let (status, message) =
                if matches!(result, Ok(Ok(()))) && !probe_session.handle.is_closed() {
                    ("latency", started.elapsed().as_millis().to_string())
                } else {
                    ("latency-unavailable", String::new())
                };
            if ipc::event(
                &probe_events,
                json!({"type":"log","channel":"terminal","status":status,"message":message}),
            )
            .await
            .is_err()
            {
                break;
            }
        }
    });
    let mut observed = Vec::new();
    let mut directory_updates = JoinSet::new();
    let mut context_interval = tokio::time::interval(Duration::from_secs(2));
    context_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut last_context = crate::terminal_directory::TerminalContext::default();
    let mut code = 0;
    loop {
        tokio::select! {
            result=directory_updates.join_next(), if !directory_updates.is_empty()=>{
                if let Some(Ok(Ok(context))) = result {
                    let context: crate::terminal_directory::TerminalContext = context;
                    if context.username.is_some() && context.username != last_context.username {
                        ipc::event(&events,json!({"type":"user","username":context.username})).await?;
                        last_context.username = context.username;
                    }
                    if context.directory.is_some() && context.directory != last_context.directory {
                        ipc::event(&events,json!({"type":"cwd","directory":context.directory})).await?;
                        last_context.directory = context.directory;
                    }
                }
            },
            _=context_interval.tick()=>{
                if directory_updates.is_empty() {
                    let (s,terminal_id)=(session.clone(),id.clone());
                    directory_updates.spawn(async move { s.terminal_context(&terminal_id,&Value::Null).await });
                }
            },
            _=cancel.cancelled()=>break,_=session.cancel.cancelled()=>break,
            command=commands.recv()=>{
                let Some(command)=command else{break;};match text(&command,"type"){
                    "data"=>{
                        let data=decode_data(&command)?;
                        channel.data(&data[..]).await?;
                        if data.iter().any(|b| matches!(b,b'\r'|b'\n')) && directory_updates.is_empty() {
                            let (s,terminal_id)=(session.clone(),id.clone());
                            directory_updates.spawn(async move {
                                tokio::time::sleep(Duration::from_millis(150)).await;
                                s.terminal_context(&terminal_id,&Value::Null).await
                            });
                        }
                    },
                    "resize"=>channel.window_change(number(&command,"cols",80).clamp(1,1000)as u32,number(&command,"rows",24).clamp(1,1000)as u32,0,0).await?,
                    _=>{}
                }
            },
            message=channel.wait()=>{
                let Some(message)=message else{break;};match message{
                    russh::ChannelMsg::Data{data}|russh::ChannelMsg::ExtendedData{data,..}=>{
                        observed.extend(&data);if observed.len()>65536{observed.drain(..observed.len()-65536);}
                        if let Some(path)=osc_directory(&observed){session.cwd.write().await.insert(id.clone(),path.clone());ipc::event(&events,json!({"type":"cwd","directory":path})).await?;observed.clear();}
                        ipc::event(&events,json!({"type":"data","channel":"terminal","data":STANDARD.encode(&data)})).await?;
                    },
                    russh::ChannelMsg::ExitStatus{exit_status}=>code=exit_status,
                    russh::ChannelMsg::Close=>break,_=>{}
                }
            }
        }
    }
    directory_updates.abort_all();
    while directory_updates.join_next().await.is_some() {}
    let _ = channel.close().await;
    session.terminal_roots.write().await.remove(&id);
    session.cwd.write().await.remove(&id);
    ipc::event(
        &events,
        json!({"type":"exit","channel":"terminal","code":code}),
    )
    .await?;
    Ok(())
}
fn osc_directory(bytes: &[u8]) -> Option<String> {
    let marker = b"\x1b]7;";
    let start = bytes.windows(marker.len()).rposition(|w| w == marker)? + marker.len();
    let rest = &bytes[start..];
    let end = rest
        .iter()
        .position(|b| *b == 7)
        .or_else(|| rest.windows(2).position(|w| w == b"\x1b\\"))?;
    let url = url::Url::parse(std::str::from_utf8(&rest[..end]).ok()?).ok()?;
    if url.scheme() != "file" {
        return None;
    }
    let mut path = Vec::new();
    let mut input = url.path().bytes();
    while let Some(byte) = input.next() {
        if byte == b'%' {
            let a = (input.next()? as char).to_digit(16)?;
            let b = (input.next()? as char).to_digit(16)?;
            path.push((a * 16 + b) as u8);
        } else {
            path.push(byte);
        }
    }
    let path = String::from_utf8(path).ok()?;
    if path.contains(['\0', '\n', '\r']) {
        None
    } else {
        Some(path)
    }
}

struct CancelOnDrop(CancellationToken);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn directory_tracking_does_not_execute_shell_expressions() {
        assert_eq!(
            osc_directory(b"prompt\x1b]7;file://remote/tmp/%E4%B8%AD\x07"),
            Some("/tmp/中".into())
        );
    }
}
