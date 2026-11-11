use crate::{
    ipc::{self, number, shell_quote, text, Events},
    transport,
};
use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use russh::{
    client,
    keys::{self, HashAlg, PrivateKeyWithHashAlg},
    Channel, ChannelMsg, Disconnect,
};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::{oneshot, Mutex, RwLock},
};
use tokio_util::sync::CancellationToken;

pub(crate) async fn optional_deadline(timeout: Option<Duration>) {
    match timeout {
        Some(duration) => tokio::time::sleep(duration).await,
        None => std::future::pending::<()>().await,
    }
}

/// A raw russh Channel does not send CLOSE when its future is dropped. Keep
/// cleanup independent of the caller, including aborts of directory probes.
pub(crate) struct SessionChannel(Option<Channel<client::Msg>>);
impl std::ops::Deref for SessionChannel {
    type Target = Channel<client::Msg>;
    fn deref(&self) -> &Self::Target {
        self.0.as_ref().expect("channel already closed")
    }
}
impl std::ops::DerefMut for SessionChannel {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.0.as_mut().expect("channel already closed")
    }
}
impl SessionChannel {
    pub(crate) async fn open(handle: Arc<client::Handle<Handler>>) -> Result<SessionChannel> {
        for attempt in 0..4 {
            let handle = handle.clone();
            // Do not drop russh's pending open on caller cancellation: the
            // server may accept it later. A detached result still owns the
            // guard, so a late confirmation immediately closes its channel.
            let opened = tokio::spawn(async move {
                handle.channel_open_session().await.map(|channel| SessionChannel(Some(channel)))
            }).await.context("SSH channel task failed")?;
            match opened {
                Ok(channel) => return Ok(channel),
                Err(error @ russh::Error::ChannelOpenFailure(
                    russh::ChannelOpenFailure::ConnectFailed | russh::ChannelOpenFailure::ResourceShortage,
                )) => {
                    if attempt == 3 {
                        return Err(anyhow::anyhow!(
                            "SSH server refused an additional session channel: {error}. Close unused terminal/file sessions and reconnect; if this persists, check the server's MaxSessions limit."
                        ));
                    }
                    // Retry only channel allocation, before any command or
                    // input was sent. Never replay a possibly executed command.
                    tokio::time::sleep(Duration::from_millis(100 << attempt)).await;
                }
                Err(error) => return Err(error.into()),
            }
        }
        unreachable!()
    }
    pub(crate) fn into_stream(mut self) -> russh::ChannelStream<client::Msg> {
        // russh's stream owns its own close-on-drop guard after this handoff.
        self.0.take().expect("channel already closed").into_stream()
    }
    pub(crate) async fn close(&mut self) -> Result<(), russh::Error> {
        if let Some(channel) = self.0.as_ref() {
            channel.close().await?;
        }
        self.0.take();
        Ok(())
    }
}
impl Drop for SessionChannel {
    fn drop(&mut self) {
        if let Some(channel) = self.0.take() {
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(2), channel.close()).await;
                });
            }
        }
    }
}

// russh's convenience certificate method does not negotiate the RSA signature
// algorithm. Use its signer interface for both SHA-2 RSA and other key types.
struct CertificateSigner(Arc<keys::PrivateKey>);
impl russh::Signer for CertificateSigner {
    type Error = anyhow::Error;
    async fn auth_sign(
        &mut self,
        _identity: &keys::agent::AgentIdentity,
        hash: Option<HashAlg>,
        mut data: Vec<u8>,
    ) -> Result<Vec<u8>> {
        use signature::Signer;
        let signed = match self.0.key_data() {
            keys::ssh_key::private::KeypairData::Rsa(key) => (key, hash).try_sign(&data)?,
            key => key.try_sign(&data)?,
        };
        let encoded = Vec::<u8>::try_from(signed)?;
        data.extend_from_slice(&(encoded.len() as u32).to_be_bytes());
        data.extend_from_slice(&encoded);
        Ok(data)
    }
}

#[derive(Default, Clone)]
pub struct Prompts(Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>);
impl Prompts {
    pub async fn answer(&self, value: &Value) {
        if let Some(reply) = self.0.lock().await.remove(text(value, "promptID")) {
            let _ = reply.send(value.clone());
        }
    }
    pub async fn ask(&self, events: &Events, mut value: Value) -> Result<Value> {
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.0.lock().await.insert(id.clone(), tx);
        value["promptID"] = json!(id);
        let result = async {
            ipc::event(events, value).await?;
            Ok(tokio::time::timeout(Duration::from_secs(120), rx)
                .await
                .context("Credential prompt timed out")??)
        }
        .await;
        self.0.lock().await.remove(&id);
        result
    }
    pub async fn credential(&self, events: &Events, message: &str) -> Result<String> {
        let value = self
            .ask(events, json!({"type":"credentialPrompt","message":message}))
            .await?;
        Ok(value["value"]
            .as_str()
            .filter(|s| s.len() <= 4096)
            .context("Credential prompt cancelled")?
            .into())
    }
}
struct RemoteRule {
    host: String,
    port: u16,
    cancel: CancellationToken,
}
type RemoteRules = Arc<RwLock<HashMap<(String, u32), RemoteRule>>>;
pub struct Handler {
    config: Value,
    events: Events,
    prompts: Prompts,
    remote: RemoteRules,
    cancel: CancellationToken,
}
impl client::Handler for Handler {
    type Error = anyhow::Error;
    async fn disconnected(&mut self, reason: client::DisconnectReason<Self::Error>) -> Result<()> {
        self.cancel.cancel();
        match reason {
            client::DisconnectReason::Error(error) => Err(error),
            _ => Ok(()),
        }
    }
    async fn check_server_key(
        &mut self,
        key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool> {
        let key = key.public_key();
        let host = text(&self.config, "hostname");
        let port = number(&self.config, "port", 22) as u16;
        let known = text(&self.config, "knownHostsFile");
        ensure!(!known.is_empty(), "known_hosts path is required");
        let pattern = if port == 22 {
            host.to_string()
        } else {
            format!("[{host}]:{port}")
        };
        let records = crate::known_hosts::records(std::path::Path::new(known), &pattern)?;
        if records.iter().any(|k| k == &key) {
            return Ok(true);
        }
        let detail = json!({"hostPattern":if port==22{host.into()}else{format!("[{host}]:{port}")},"algorithm":key.algorithm().to_string(),"fingerprint":key.fingerprint(HashAlg::Sha256).to_string(),"hasHostPattern":!records.is_empty()});
        let auto = self.config["autoAcceptHostKeys"].as_bool() == Some(true) && records.is_empty();
        let accepted = if auto {
            true
        } else {
            self.prompts
                .ask(
                    &self.events,
                    json!({"type":"hostKeyPrompt","detail":detail}),
                )
                .await?["accepted"]
                .as_bool()
                == Some(true)
        };
        if !accepted {
            return Ok(false);
        }
        crate::known_hosts::save(std::path::Path::new(known), &pattern, &key, &records)?;
        Ok(true)
    }
    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: Channel<client::Msg>,
        address: &str,
        port: u32,
        _origin: &str,
        _origin_port: u32,
        reply: client::ChannelOpenHandle,
        _session: &mut client::Session,
    ) -> Result<()> {
        let rules = self.remote.read().await;
        let rule = rules.iter().find(|((bind, p), _)| {
            *p == port && (bind == address || bind == "0.0.0.0" || bind == "::")
        });
        if let Some((_, r)) = rule {
            let (host, port, cancel) = (r.host.clone(), r.port, r.cancel.clone());
            reply.accept().await;
            tokio::spawn(async move {
                let work = async {
                    let mut target = TcpStream::connect((host.as_str(), port)).await?;
                    let mut channel = channel.into_stream();
                    tokio::io::copy_bidirectional(&mut channel, &mut target).await?;
                    Ok::<_, anyhow::Error>(())
                };
                tokio::select! {_=cancel.cancelled()=>{},_=work=>{}}
            });
        } else {
            reply
                .reject(russh::ChannelOpenFailure::AdministrativelyProhibited)
                .await;
        }
        Ok(())
    }
}
pub struct Session {
    pub monitor: crate::monitor::Monitor,
    pub handle: Arc<client::Handle<Handler>>,
    pub config: Value,
    pub cancel: CancellationToken,
    remote: RemoteRules,
    forwards: Mutex<HashMap<String, (Value, CancellationToken)>>,
    pub cwd: RwLock<HashMap<String, String>>,
    pub(crate) terminal_roots: RwLock<HashMap<String, crate::terminal_directory::TerminalProcess>>,
    pub(crate) terminal_registration: Mutex<()>,
}
impl Drop for Session {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
impl Session {
    pub async fn connect(mut config: Value, events: Events, prompts: Prompts) -> Result<Arc<Self>> {
        let host = text(&config, "hostname").to_string();
        let port = number(&config, "port", 22);
        ensure!((1..=65535).contains(&port), "Invalid SSH port");
        ipc::event(
            &events,
            json!({"type":"log","status":"connecting","message":"Connecting SSH"}),
        )
        .await?;
        let stream = transport::connect(&host, port as u16, &config["proxy"]).await?;
        let remote = RemoteRules::default();
        let cancel = CancellationToken::new();
        let handler = Handler {
            config: json!({"hostname":host,"port":port,"knownHostsFile":config["knownHostsFile"],"autoAcceptHostKeys":config["autoAcceptHostKeys"]}),
            events: events.clone(),
            prompts: prompts.clone(),
            remote: remote.clone(),
            cancel: cancel.clone(),
        };
        // Preserve modern algorithms enabled by the previous ssh2 client. russh's
        // defaults omit NIST ECDH and AES-128-GCM compatibility.
        // Keep Rust MAC defaults: HMAC-SHA1/ETM stay disabled by user choice.
        // Do not enable other legacy algorithms (group1, CBC, DSA, etc.).
        let mut preferred = russh::Preferred::default();
        preferred.kex.to_mut().extend([
            russh::kex::ECDH_SHA2_NISTP256,
            russh::kex::ECDH_SHA2_NISTP384,
            russh::kex::ECDH_SHA2_NISTP521,
        ]);
        preferred.cipher.to_mut().push(russh::cipher::AES_128_GCM);
        let options = Arc::new(client::Config {
            preferred,
            window_size: 8 * 1024 * 1024,
            keepalive_interval: Some(Duration::from_secs(30)),
            keepalive_max: 3,
            ..Default::default()
        });
        let mut handle = tokio::time::timeout(
            Duration::from_secs(150),
            client::connect_stream(options, stream, handler),
        )
        .await
        .context("SSH handshake timed out")??;
        let user = text(&config, "username").to_string();
        ensure!(!user.is_empty(), "SSH username required");
        let auth = match text(&config, "authentication") {
            "identityFile" => {
                let source = if !text(&config, "privateKey").is_empty() {
                    text(&config, "privateKey").to_string()
                } else {
                    tokio::fs::read_to_string(text(&config, "identityFile")).await?
                };
                let mut passphrase = text(&config, "passphrase").to_string();
                let mut key = keys::decode_secret_key(
                    &source,
                    if passphrase.is_empty() {
                        None
                    } else {
                        Some(&passphrase)
                    },
                );
                for _ in 0..3 {
                    if key.is_ok() {
                        break;
                    }
                    passphrase = prompts
                        .credential(&events, "Private key passphrase")
                        .await?;
                    key = keys::decode_secret_key(&source, Some(&passphrase));
                }
                let key = Arc::new(key.context("Private key could not be decrypted")?);
                let certificate = text(&config, "certificate");
                if !certificate.is_empty() {
                    let certificate = if certificate.contains("-cert-v01@openssh.com") {
                        keys::ssh_key::Certificate::from_openssh(certificate)?
                    } else {
                        keys::load_openssh_certificate(certificate)?
                    };
                    ensure!(
                        certificate.public_key() == key.public_key().key_data(),
                        "Certificate does not match the private key"
                    );
                    let hash = handle.best_supported_rsa_hash().await?.flatten();
                    handle
                        .authenticate_certificate_with(
                            &user,
                            certificate,
                            hash,
                            &mut CertificateSigner(key),
                        )
                        .await?
                        .success()
                } else {
                    let hash = handle.best_supported_rsa_hash().await?.flatten();
                    handle
                        .authenticate_publickey(&user, PrivateKeyWithHashAlg::new(key, hash))
                        .await?
                        .success()
                }
            }
            "agent" => {
                #[cfg(unix)]
                let mut agent = keys::agent::client::AgentClient::connect_env().await?;
                #[cfg(windows)]
                let mut agent = keys::agent::client::AgentClient::connect_named_pipe(
                    r"\\.\pipe\openssh-ssh-agent",
                )
                .await?;
                let mut success = false;
                // Agent RSA signatures must negotiate SHA-2 just like private
                // keys; None unconditionally requests legacy ssh-rsa signing.
                let hash = handle.best_supported_rsa_hash().await?.flatten();
                for identity in agent.request_identities().await? {
                    let accepted = match identity {
                        keys::agent::AgentIdentity::PublicKey { key, .. } => handle
                            .authenticate_publickey_with(&user, key, hash, &mut agent)
                            .await?
                            .success(),
                        keys::agent::AgentIdentity::Certificate { certificate, .. } => handle
                            .authenticate_certificate_with(&user, certificate, hash, &mut agent)
                            .await?
                            .success(),
                    };
                    if accepted {
                        success = true;
                        break;
                    }
                }
                success
            }
            "password" | "" => {
                let password = if text(&config, "password").is_empty() {
                    prompts.credential(&events, "SSH password").await?
                } else {
                    text(&config, "password").to_string()
                };
                if handle
                    .authenticate_password(&user, &password)
                    .await?
                    .success()
                {
                    true
                } else {
                    let mut result = handle
                        .authenticate_keyboard_interactive_start(&user, None)
                        .await?;
                    for _ in 0..8 {
                        match result {
                            client::KeyboardInteractiveAuthResponse::Success => break,
                            client::KeyboardInteractiveAuthResponse::Failure { .. } => break,
                            client::KeyboardInteractiveAuthResponse::InfoRequest {
                                prompts: ref challenge_prompts,
                                ..
                            } => {
                                let mut responses = Vec::new();
                                for prompt in challenge_prompts {
                                    responses.push(
                                        if prompt.prompt.to_ascii_lowercase().contains("password") {
                                            password.clone()
                                        } else {
                                            prompts.credential(&events, &prompt.prompt).await?
                                        },
                                    );
                                }
                                result = handle
                                    .authenticate_keyboard_interactive_respond(responses)
                                    .await?;
                            }
                        }
                    }
                    matches!(result, client::KeyboardInteractiveAuthResponse::Success)
                }
            }
            _ => bail!("Unsupported SSH authentication"),
        };
        ensure!(auth, "SSH authentication rejected");
        if let Some(object) = config.as_object_mut() {
            for field in ["password", "privateKey", "passphrase", "certificate"] {
                object.remove(field);
            }
        }
        ipc::event(
            &events,
            json!({"type":"log","status":"authenticated","message":"SSH authenticated"}),
        )
        .await?;
        Ok(Arc::new(Self {
            monitor: crate::monitor::Monitor::default(),
            handle: Arc::new(handle),
            config,
            cancel,
            remote,
            forwards: Mutex::new(HashMap::new()),
            cwd: RwLock::new(HashMap::new()),
            terminal_roots: RwLock::new(HashMap::new()),
            terminal_registration: Mutex::new(()),
        }))
    }
    pub(crate) async fn open_session_channel(&self) -> Result<SessionChannel> {
        SessionChannel::open(self.handle.clone()).await
    }
    pub async fn exec(&self, command: &str, timeout: Duration, options: &Value) -> Result<Value> {
        self.exec_cancellable(command, timeout, options, &self.cancel)
            .await
    }
    pub async fn exec_cancellable(
        &self,
        command: &str,
        timeout: Duration,
        options: &Value,
        cancel: &CancellationToken,
    ) -> Result<Value> {
        self.exec_cancellable_with_timeout(command, Some(timeout), options, cancel)
            .await
    }
    pub async fn exec_cancellable_with_timeout(
        &self,
        command: &str,
        timeout: Option<Duration>,
        options: &Value,
        cancel: &CancellationToken,
    ) -> Result<Value> {
        self.exec_with_input(command, timeout, options, cancel, None)
            .await
    }
    /// Send private command input only after the remote program signals readiness,
    /// so sudo/su password readers cannot consume it as an authentication response.
    pub async fn exec_cancellable_with_input(
        &self,
        command: &str,
        timeout: Duration,
        options: &Value,
        cancel: &CancellationToken,
        marker: &str,
        input: &[u8],
    ) -> Result<Value> {
        ensure!(
            !marker.is_empty() && input.len() <= 2 * 1024 * 1024,
            "Invalid command input"
        );
        self.exec_with_input(
            command,
            Some(timeout),
            options,
            cancel,
            Some((marker, input)),
        )
        .await
    }
    async fn exec_with_input(
        &self,
        command: &str,
        timeout: Option<Duration>,
        options: &Value,
        cancel: &CancellationToken,
        input: Option<(&str, &[u8])>,
    ) -> Result<Value> {
        ensure!(
            !command.contains('\0') && command.len() <= 256 * 1024,
            "Invalid remote command"
        );
        let elevated =
            options["elevated"].as_bool() == Some(true) && text(&self.config, "username") != "root";
        let mut channel = tokio::select! {
            _=self.cancel.cancelled()=>bail!("Connection closed"),
            _=cancel.cancelled()=>bail!("Command cancelled"),
            _=optional_deadline(timeout)=>bail!("Command channel timed out"),
            result=self.open_session_channel()=>result?,
        };
        let mut password = zeroize::Zeroizing::new(text(options, "elevationPassword").to_string());
        let work = async {
            let su = elevated && text(options, "elevationMethod") == "su";
            let command = if elevated {
                if su {
                    channel
                        .request_pty(
                            true,
                            "dumb",
                            80,
                            24,
                            0,
                            0,
                            &[
                                (russh::Pty::ECHO, 0),
                                (russh::Pty::ECHONL, 0),
                                (russh::Pty::OPOST, 0),
                            ],
                        )
                        .await?;
                    format!("su - root -c {}", shell_quote(command))
                } else {
                    format!(
                        "sudo -H -S -p '__TERMPILOT_PASSWORD__' sh -c {}",
                        shell_quote(command)
                    )
                }
            } else {
                command.to_string()
            };
            channel.exec(true, command).await?;
            let mut output = Vec::new();
            let mut errors = Vec::new();
            let mut code = None;
            let mut signal = None;
            let mut sent = false;
            let mut input_sent = false;
            while let Some(message) = channel.wait().await {
                match message {
                    ChannelMsg::Data { data } => output.extend(&data),
                    ChannelMsg::ExtendedData { data, .. } => errors.extend(&data),
                    ChannelMsg::ExitStatus { exit_status } => code = Some(exit_status),
                    ChannelMsg::ExitSignal { signal_name, .. } => {
                        signal = Some(format!("{signal_name:?}"))
                    }
                    ChannelMsg::Close => break,
                    _ => {}
                }
                ensure!(
                    output.len() + errors.len() <= 16 * 1024 * 1024,
                    "Command output exceeds limit"
                );
                if elevated
                    && !sent
                    && !input_sent
                    && (crate::elevation::password_prompt(&errors)
                        || (su && crate::elevation::password_prompt(&output)))
                {
                    let input = zeroize::Zeroizing::new(format!("{}\n", password.as_str()));
                    channel.data(input.as_bytes()).await?;
                    use zeroize::Zeroize;
                    password.zeroize();
                    sent = true;
                    if su {
                        output.clear();
                    }
                    errors.clear();
                }
                if let Some((marker, data)) = input.filter(|_| !input_sent) {
                    if let Some(position) = output
                        .windows(marker.len())
                        .position(|part| part == marker.as_bytes())
                    {
                        output.drain(..position + marker.len());
                        channel.data(data).await?;
                        input_sent = true;
                    }
                }
            }
            ensure!(
                code.is_some() || signal.is_some(),
                "Connection closed without command status"
            );
            Ok::<_, anyhow::Error>(
                json!({"stdout":String::from_utf8_lossy(&output),"stderr":String::from_utf8_lossy(&errors),"exitCode":code,"code":code,"signal":signal}),
            )
        };
        let result = tokio::select! {
            _=self.cancel.cancelled()=>Err(anyhow::anyhow!("Connection closed")),
            _=cancel.cancelled()=>Err(anyhow::anyhow!("Command cancelled")),
            _=optional_deadline(timeout)=>Err(anyhow::anyhow!("Remote command timed out")),
            result=work=>result,
        };
        let _ = tokio::time::timeout(Duration::from_secs(2), channel.close()).await;
        result
    }
    pub async fn close(&self) {
        self.cancel.cancel();
        let _ = self
            .handle
            .disconnect(Disconnect::ByApplication, "TermPilot disconnected", "en")
            .await;
    }
    pub async fn forward(self: &Arc<Self>, rule: &Value, start: bool) -> Result<Value> {
        let id = text(rule, "id");
        ensure!(!id.is_empty(), "Forward ID required");
        let mut forwards = self.forwards.lock().await;
        if !start {
            if let Some((rule, cancel)) = forwards.remove(id) {
                cancel.cancel();
                if text(&rule, "kind") == "remote" {
                    let bind = text(&rule, "bindAddress");
                    let port = number(&rule, "localPort", 0) as u32;
                    self.remote.write().await.remove(&(bind.into(), port));
                    self.handle.cancel_tcpip_forward(bind, port).await?;
                }
            }
            return Ok(json!({"active":false}));
        }
        ensure!(!forwards.contains_key(id), "Forward already active");
        let bind = text(rule, "bindAddress");
        let port = number(rule, "localPort", 0);
        ensure!((1..=65535).contains(&port), "Invalid forwarding port");
        transport::validate_target(bind, port as u16)?;
        let target = text(rule, "remoteHost").to_string();
        let target_port = number(rule, "remotePort", 0);
        let kind = text(rule, "kind");
        if kind != "dynamic" {
            ensure!(
                (1..=65535).contains(&target_port),
                "Invalid forwarding target"
            );
            transport::validate_target(&target, target_port as u16)?;
        }
        let cancel = self.cancel.child_token();
        if kind == "remote" {
            self.remote.write().await.insert(
                (bind.into(), port as u32),
                RemoteRule {
                    host: target,
                    port: target_port as u16,
                    cancel: cancel.clone(),
                },
            );
            if let Err(error) = self.handle.tcpip_forward(bind, port as u32).await {
                self.remote
                    .write()
                    .await
                    .remove(&(bind.into(), port as u32));
                return Err(error.into());
            }
        } else {
            ensure!(
                kind == "local" || kind == "dynamic",
                "Invalid forwarding kind"
            );
            let dynamic = kind == "dynamic";
            let listener = TcpListener::bind((bind, port as u16)).await?;
            let session = self.clone();
            let stop = cancel.clone();
            tokio::spawn(async move {
                loop {
                    let accepted =
                        tokio::select! {_=stop.cancelled()=>break,r=listener.accept()=>r};
                    let Ok((mut socket, _)) = accepted else {
                        break;
                    };
                    let (session, cancel, target) = (session.clone(), stop.clone(), target.clone());
                    tokio::spawn(async move {
                        let work = async {
                            let (host, port) = if dynamic {
                                tokio::time::timeout(
                                    Duration::from_secs(15),
                                    socks_target(&mut socket),
                                )
                                .await??
                            } else {
                                (target, target_port as u16)
                            };
                            let channel = session
                                .handle
                                .channel_open_direct_tcpip(&host, port as u32, "127.0.0.1", 0)
                                .await?;
                            if dynamic {
                                socket.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
                            }
                            let mut stream = channel.into_stream();
                            tokio::io::copy_bidirectional(&mut stream, &mut socket).await?;
                            Ok::<_, anyhow::Error>(())
                        };
                        tokio::select! {_=cancel.cancelled()=>{},_=work=>{}}
                    });
                }
            });
        }
        forwards.insert(id.into(), (rule.clone(), cancel));
        Ok(json!({"active":true}))
    }
}
async fn socks_target(socket: &mut TcpStream) -> Result<(String, u16)> {
    ensure!(socket.read_u8().await? == 5, "SOCKS version");
    let n = socket.read_u8().await?;
    let mut methods = vec![0; n as usize];
    socket.read_exact(&mut methods).await?;
    ensure!(methods.contains(&0), "SOCKS authentication");
    socket.write_all(&[5, 0]).await?;
    let mut head = [0; 4];
    socket.read_exact(&mut head).await?;
    ensure!(head[..3] == [5, 1, 0], "SOCKS CONNECT required");
    let host = match head[3] {
        1 => {
            let mut a = [0; 4];
            socket.read_exact(&mut a).await?;
            std::net::Ipv4Addr::from(a).to_string()
        }
        4 => {
            let mut a = [0; 16];
            socket.read_exact(&mut a).await?;
            std::net::Ipv6Addr::from(a).to_string()
        }
        3 => {
            let n = socket.read_u8().await?;
            let mut a = vec![0; n as usize];
            socket.read_exact(&mut a).await?;
            String::from_utf8(a)?
        }
        _ => bail!("SOCKS address"),
    };
    let port = socket.read_u16().await?;
    transport::validate_target(&host, port)?;
    Ok((host, port))
}
pub fn decode_data(value: &Value) -> Result<Vec<u8>> {
    let data = STANDARD.decode(text(value, "data"))?;
    ensure!(data.len() <= 256 * 1024, "Terminal input limit");
    Ok(data)
}
