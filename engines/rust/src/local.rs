//! Native macOS terminal/file clients share one Rust SSH transport through an
//! owner-only Unix socket. Secrets arrive through a private pipe, never argv.
use crate::{
    ipc::{self, text},
    worker::{self, Shared},
};
use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::PathBuf,
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    process::Command,
    task::JoinSet,
};

fn socket_path(config: &Value) -> Result<PathBuf> {
    let id = text(config, "connectionID");
    ensure!(
        !id.is_empty() && id.len() <= 256,
        "SSH connection identity required"
    );
    let directory = PathBuf::from(format!("/tmp/TermPilot-{}", unsafe { libc::geteuid() }));
    match std::fs::create_dir(&directory) {
        Ok(()) => std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    let metadata = std::fs::symlink_metadata(&directory)?;
    ensure!(
        metadata.is_dir()
            && metadata.uid() == unsafe { libc::geteuid() }
            && metadata.mode() & 0o077 == 0,
        "Unsafe SSH broker directory"
    );
    Ok(directory.join(format!("{}.sock", &hex::encode(Sha256::digest(id))[..32])))
}
async fn attach(config: &Value) -> Result<UnixStream> {
    let path = socket_path(config)?;
    if let Ok(socket) = UnixStream::connect(&path).await {
        return Ok(socket);
    }
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("ssh-broker")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    let mut input = child.stdin.take().context("Broker input")?;
    ipc::write_json(&mut input, config).await?;
    input.shutdown().await?;
    drop(input);
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if let Ok(socket) = UnixStream::connect(&path).await {
                return Ok(socket);
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
    })
    .await
    .context("SSH broker did not start")?
}
pub async fn broker() -> Result<()> {
    let config = ipc::read_json(&mut BufReader::new(tokio::io::stdin()))
        .await?
        .context("Broker configuration missing")?;
    let path = socket_path(&config)?;
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path.with_extension("lock"))?;
    if lock.try_lock().is_err() {
        return Ok(());
    }
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    let shared = Shared::new(config);
    let mut clients = JoinSet::new();
    let mut idle = tokio::time::Instant::now();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (socket, _) = accepted?;
                if socket.peer_cred()?.uid() != unsafe { libc::geteuid() } { continue; }
                let shared = shared.clone(); let (read, write) = socket.into_split();
                clients.spawn(async move { let _ = worker::serve(read, write, Some(shared), None).await; });
                idle = tokio::time::Instant::now();
            }
            _ = clients.join_next(), if !clients.is_empty() => { idle = tokio::time::Instant::now(); }
            _ = tokio::time::sleep(Duration::from_secs(1)) => { if clients.is_empty() && idle.elapsed() >= Duration::from_secs(15) { break; } }
        }
    }
    shared.close().await;
    drop(listener);
    let _ = std::fs::remove_file(path);
    Ok(())
}
pub async fn files() -> Result<()> {
    let mut input = ipc::JsonReader::new(BufReader::new(tokio::io::stdin()));
    let mut config = input.read().await?.context("File configuration missing")?;
    if text(&config, "connectionID").is_empty() {
        config["connectionID"] = json!(uuid::Uuid::new_v4().to_string());
    }
    let socket = attach(&config).await?;
    let (read, mut write) = socket.into_split();
    let mut read = ipc::JsonReader::new(BufReader::new(read));
    let exec = config["execOnly"].as_bool() == Some(true);
    let channel = if exec { "exec" } else { "files" };
    ipc::write_json(
        &mut write,
        &json!({"type":if exec {"execOpen"} else {"sftpOpen"},"config":config}),
    )
    .await?;
    let mut output = tokio::io::stdout();
    let work: Result<()> = async {
        loop { tokio::select! {
            command = input.read() => {
                let Some(command) = command? else { break; };
                ipc::write_json(&mut write, &json!({"type":"sftpRequest","channel":channel,"request":command})).await?;
            }
            event = read.read() => {
                let event = event?.context("SSH broker closed")?;
                match text(&event,"type") {
                    "sftpReady"|"execReady" => ipc::write_json(&mut output,&json!({"id":0,"event":"ready","mode":event["mode"]})).await?,
                    "sftpResponse" => ipc::write_json(&mut output,&event["message"]).await?,
                    "error" => bail!("{}",text(&event,"message")),
                    "hostKeyPrompt"|"credentialPrompt" => bail!("Open the SSH terminal to confirm the host key or authentication prompt before using files"),
                    _=>{}
                }
            }
        }} Ok(())
    }.await;
    if let Err(error) = &work {
        let _ = ipc::write_json(
            &mut output,
            &json!({"id":0,"ok":false,"error":error.to_string()}),
        )
        .await;
    }
    work
}
struct RawTerminal(libc::termios);
impl RawTerminal {
    fn enter() -> Result<Option<Self>> {
        if unsafe { libc::isatty(0) } != 1 {
            return Ok(None);
        }
        let mut saved = unsafe { std::mem::zeroed::<libc::termios>() };
        ensure!(
            unsafe { libc::tcgetattr(0, &mut saved) } == 0,
            "Cannot read local terminal mode"
        );
        let mut raw = saved;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        ensure!(
            unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } == 0,
            "Cannot configure local terminal"
        );
        Ok(Some(Self(saved)))
    }
}
impl Drop for RawTerminal {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(0, libc::TCSANOW, &self.0);
        }
    }
}
fn dimensions() -> (u16, u16) {
    let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
    unsafe {
        libc::ioctl(1, libc::TIOCGWINSZ, &mut size);
    }
    (size.ws_col.max(1), size.ws_row.max(1))
}
async fn terminal_log(
    output: &mut tokio::io::Stdout,
    status: &str,
    message: &str,
    detail: Option<&Value>,
) -> Result<()> {
    let clean = message.replace(['\x1e', '\x1f', '\r', '\n'], " ");
    let detail = match detail {
        Some(v) => format!(" {}", serde_json::to_string(v)?),
        None => String::new(),
    };
    output
        .write_all(format!("\x1e[ssh2:{status}] {clean}{detail}\x1f").as_bytes())
        .await?;
    output.flush().await?;
    Ok(())
}
pub async fn terminal(fifo: PathBuf) -> Result<()> {
    // The caller creates a 0600 FIFO in a 0700 directory. It is consumed once;
    // no credentials ever enter the PTY (including its initial echo window).
    let config = tokio::task::spawn_blocking(move || -> Result<Value> {
        use std::{io::Read, os::unix::fs::FileTypeExt};
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&fifo)?;
        let meta = file.metadata()?;
        ensure!(
            meta.file_type().is_fifo()
                && meta.uid() == unsafe { libc::geteuid() }
                && meta.mode() & 0o077 == 0,
            "Unsafe configuration pipe"
        );
        let _ = std::fs::remove_file(&fifo);
        if let Some(p) = fifo.parent() {
            let _ = std::fs::remove_dir(p);
        }
        let mut bytes = Vec::new();
        file.by_ref()
            .take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= 1024 * 1024, "Configuration limit");
        let result = serde_json::from_slice(&bytes);
        use zeroize::Zeroize;
        bytes.zeroize();
        Ok(result?)
    })
    .await??;
    let forwarding = config["forwardRule"].is_object();
    let _raw = if forwarding {
        None
    } else {
        RawTerminal::enter()?
    };
    let mut output = tokio::io::stdout();
    let result:Result<()>=async {
        let socket=attach(&config).await?; let(read,mut write)=socket.into_split(); let mut read=ipc::JsonReader::new(BufReader::new(read));
        let(cols,rows)=dimensions(); ipc::write_json(&mut write,&json!({"type":if forwarding {"forwardOpen"}else{"open"},"cols":cols,"rows":rows,"sessionID":config["sessionID"],"forwardRule":config["forwardRule"]})).await?;
        let mut input=tokio::io::stdin(); let mut buffer=[0u8;16384]; let mut prompt:Option<(String,bool,Vec<u8>)>=None;
        let mut resize=tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())?;
        let mut terminate=tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        loop {tokio::select! {
            _=terminate.recv()=>break,
            _=resize.recv()=>{let(cols,rows)=dimensions();ipc::write_json(&mut write,&json!({"type":"resize","cols":cols,"rows":rows})).await?;}
            n=input.read(&mut buffer), if !forwarding=>{
                let n=n?;if n==0{break;}
                if let Some((id,host_key,answer))=&mut prompt {
                    for byte in &buffer[..n] {
                        if matches!(byte,b'\r'|b'\n') {
                            let value=String::from_utf8_lossy(answer);
                            let event=if *host_key {json!({"type":"hostKeyResponse","promptID":id,"accepted":matches!(value.trim().to_lowercase().as_str(),"yes"|"y"|"accept"|"accepted"|"true"|"1")})}else{json!({"type":"credentialResponse","promptID":id,"value":value})};
                            ipc::write_json(&mut write,&event).await?;prompt=None;break;
                        }else if matches!(byte,8|127){answer.pop();}else{ensure!(answer.len()<4096,"Credential input limit");answer.push(*byte);}
                    }
                }else{ipc::write_json(&mut write,&json!({"type":"data","data":STANDARD.encode(&buffer[..n])})).await?;}
            }
            event=read.read()=>{
                let Some(event)=event?else{break;};match text(&event,"type"){
                    "log"=>terminal_log(&mut output,text(&event,"status"),text(&event,"message"),event.get("detail")).await?,
                    "data"=>{output.write_all(&STANDARD.decode(text(&event,"data"))?).await?;output.flush().await?;},
                    "cwd"=>terminal_log(&mut output,"cwd",text(&event,"directory"),None).await?,
                    "user"=>terminal_log(&mut output,"user",text(&event,"username"),None).await?,
                    "hostKeyPrompt" if forwarding=>{
                        let executable=text(&config,"askPassExecutable");ensure!(!executable.is_empty(),"Confirm the SSH host key in a terminal before starting this forward");
                        let detail=&event["detail"];
                        let question=format!("{} SSH host key {} {}. Continue connecting (yes/no)?",text(detail,"hostPattern"),text(detail,"algorithm"),text(detail,"fingerprint"));
                        let answer=Command::new(executable).arg(question).env("TERMPILOT_ASKPASS_MODE","1").env("SSH_ASKPASS_REQUIRE","force").env("TERMPILOT_ASKPASS_REQUEST_DIR",text(&config,"askPassRequestDirectory")).stdin(Stdio::null()).stderr(Stdio::null()).output().await?;
                        let accepted=answer.status.success() && String::from_utf8_lossy(&answer.stdout).trim()=="yes";
                        ipc::write_json(&mut write,&json!({"type":"hostKeyResponse","promptID":event["promptID"],"accepted":accepted})).await?;
                    },
                    "hostKeyPrompt"=>{prompt=Some((text(&event,"promptID").into(),true,Vec::new()));terminal_log(&mut output,"host-key-prompt","SSH host key confirmation required",event.get("detail")).await?;},
                    "credentialPrompt" if forwarding=>{
                        let executable=text(&config,"askPassExecutable");ensure!(!executable.is_empty(),"Authentication prompt helper unavailable");
                        let answer=Command::new(executable).arg(text(&event,"message")).env("TERMPILOT_ASKPASS_MODE","1").env("SSH_ASKPASS_REQUIRE","force").env("TERMPILOT_ASKPASS_REQUEST_DIR",text(&config,"askPassRequestDirectory")).stdin(Stdio::null()).stderr(Stdio::null()).output().await?;
                        let value=if answer.status.success(){Value::String(String::from_utf8(answer.stdout)?.trim_end_matches(['\r','\n']).to_string())}else{Value::Null};
                        ipc::write_json(&mut write,&json!({"type":"credentialResponse","promptID":event["promptID"],"value":value})).await?;
                    },
                    "credentialPrompt"=>{prompt=Some((text(&event,"promptID").into(),false,Vec::new()));output.write_all(format!("\r\n{}: ",text(&event,"message")).as_bytes()).await?;output.flush().await?;},
                    "error"=>bail!("{}",text(&event,"message")),"exit"=>break,_=>{}
                }
            }
        }}
        let _=ipc::write_json(&mut write,&json!({"type":"close"})).await;Ok(())
    }.await;
    if let Err(error) = &result {
        let _ = terminal_log(&mut output, "error", &error.to_string(), None).await;
    }
    result
}
