#[path = "files_resume.rs"]
mod resume;
use crate::{
    ipc::{self, number, shell_quote, text, Events},
    scp::{self, Scp},
    sftp::{self, Attributes, Sftp},
    ssh::Session,
};
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    future::Future,
    path::Path,
    pin::Pin,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::{Mutex, Notify, Semaphore},
    task::JoinSet,
};
use tokio_util::sync::CancellationToken;

pub struct Transfer {
    cancel: CancellationToken,
    user_cancel: AtomicBool,
    paused: AtomicBool,
    notify: Notify,
    done: AtomicU64,
    total: AtomicU64,
    visited: AtomicU64,
    last: Mutex<Instant>,
}
impl Transfer {
    async fn interruptible<T>(&self, work: impl Future<Output = Result<T>>) -> Result<T> {
        tokio::select! {
            _ = self.cancel.cancelled() => bail!("Transfer cancelled"),
            result = work => result,
        }
    }
    fn new(cancel: CancellationToken) -> Self {
        Self {
            cancel,
            user_cancel: AtomicBool::new(false),
            paused: AtomicBool::new(false),
            notify: Notify::new(),
            done: AtomicU64::new(0),
            total: AtomicU64::new(0),
            visited: AtomicU64::new(0),
            last: Mutex::new(Instant::now() - Duration::from_secs(1)),
        }
    }
    async fn ready(&self) -> Result<()> {
        loop {
            let change = self.notify.notified();
            tokio::pin!(change);
            change.as_mut().enable();
            ensure!(!self.cancel.is_cancelled(), "Transfer cancelled");
            if !self.paused.load(Ordering::Acquire) {
                return Ok(());
            }
            tokio::select! {_=self.cancel.cancelled()=>bail!("Transfer cancelled"),_=change=>{}}
        }
    }
    async fn progress(
        &self,
        id: &Value,
        events: &Events,
        channel: &str,
        bytes: u64,
        force: bool,
    ) -> Result<()> {
        let done = self.done.fetch_add(bytes, Ordering::Relaxed) + bytes;
        let mut last = self.last.lock().await;
        if force || last.elapsed() >= Duration::from_millis(100) {
            *last = Instant::now();
            ipc::event(events,json!({"type":"sftpResponse","channel":channel,"message":{"id":id,"event":"progress","transferred":done,"total":self.total.load(Ordering::Relaxed)}})).await?;
        }
        Ok(())
    }
}
pub struct Files {
    pub session: Arc<Session>,
    pub sftp: Option<Arc<Sftp>>,
    pub scp: Scp,
    pub options: Value,
    transfers: Mutex<HashMap<String, Arc<Transfer>>>,
    closed: CancellationToken,
    limiter: FileLimiter,
    transfer_memory: Arc<Semaphore>,
    root_shell: Mutex<Option<crate::elevation::RootShell>>,
    forwards: Mutex<HashMap<String, Value>>,
}
type BoxWork<'a, T> = Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>;
impl Drop for Files {
    fn drop(&mut self) {
        self.closed.cancel();
    }
}
impl Files {
    pub async fn open(session: Arc<Session>, options: Value) -> Result<Arc<Self>> {
        let protocol = text(&options, "fileProtocol");
        let encoding = text(&options, "filenameEncoding");
        ensure!(
            protocol != "scp" || options["usesSudo"].as_bool() != Some(true),
            "SCP mode cannot be combined with elevated SFTP"
        );
        let sftp = if protocol == "scp" || options["execOnly"].as_bool() == Some(true) {
            None
        } else {
            let open_once = || async {
                let mut channel = session.open_session_channel().await?;
                if options["usesSudo"].as_bool() == Some(true) {
                    let paths=session.exec("for p in /usr/lib/openssh/sftp-server /usr/libexec/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server /usr/lib/sftp-server /usr/local/libexec/sftp-server /usr/local/lib/sftp-server; do if [ -x \"$p\" ]; then printf '%s' \"$p\"; exit 0; fi; done; command -v sftp-server",Duration::from_secs(15),&Value::Null).await?;
                    let server = paths["stdout"]
                        .as_str()
                        .filter(|p| p.starts_with('/') && !p.contains(['\n', '\r']))
                        .context("Remote sftp-server not found")?;
                    let marker = format!("__TERMPILOT_SFTP_{}__", uuid::Uuid::new_v4().simple());
                    let payload = format!(
                        "printf %s {}; exec {} -e",
                        shell_quote(&marker),
                        shell_quote(server)
                    );
                    let command = if text(&options, "elevationMethod") == "su" {
                        format!("su - root -c {}", shell_quote(&payload))
                    } else {
                        format!(
                            "sudo -H -S -p '__TERMPILOT_PASSWORD__' sh -c {}",
                            shell_quote(&payload)
                        )
                    };
                    channel.exec(true, command).await?;
                    let mut output = Vec::new();
                    let mut errors = String::new();
                    let mut sent = false;
                    tokio::time::timeout(Duration::from_secs(25), async {
                        loop {
                            match channel.wait().await.context("Elevated SFTP closed")? {
                                russh::ChannelMsg::Data { data } => {
                                    output.extend(&data);
                                    ensure!(output.len() <= 65536, "Elevated SFTP handshake limit");
                                    if output.ends_with(marker.as_bytes()) {
                                        return Ok::<_, anyhow::Error>(());
                                    }
                                }
                                russh::ChannelMsg::ExtendedData { data, .. } => {
                                    errors.push_str(&String::from_utf8_lossy(&data));
                                    ensure!(errors.len() <= 65536, "Elevation output limit");
                                    if errors.contains("__TERMPILOT_PASSWORD__")
                                        || errors.to_ascii_lowercase().contains("password:")
                                        || errors.contains("密码")
                                    {
                                        ensure!(!sent, "Elevation credentials rejected");
                                        channel
                                            .data(
                                                format!(
                                                    "{}\n",
                                                    text(&options, "elevationPassword")
                                                )
                                                .as_bytes(),
                                            )
                                            .await?;
                                        sent = true;
                                        errors.clear();
                                    }
                                }
                                russh::ChannelMsg::ExitStatus { .. } | russh::ChannelMsg::Close => {
                                    bail!("Elevated SFTP failed")
                                }
                                _ => {}
                            }
                        }
                    })
                    .await
                    .context("Elevated SFTP timed out")??;
                } else {
                    channel.request_subsystem(true, "sftp").await?;
                }
                Sftp::new(Box::new(channel.into_stream()), encoding).await
            };
            let mut open = open_once().await;
            // Some servers intermittently close a newly opened subsystem. A
            // fresh channel is safe to retry before any file operation starts.
            // Never retry authentication or replay a partially written file.
            let transient = open
                .as_ref()
                .err()
                .and_then(|error| error.downcast_ref::<std::io::Error>())
                .is_some_and(|error| {
                    matches!(
                        error.kind(),
                        std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset
                    )
                });
            if transient
                && options["usesSudo"].as_bool() != Some(true)
                && !session.cancel.is_cancelled()
            {
                tokio::time::sleep(Duration::from_millis(100)).await;
                open = open_once().await;
            }
            match open {
                Ok(sftp) => Some(sftp),
                Err(error) if protocol == "sftp" || options["usesSudo"].as_bool() == Some(true) => {
                    return Err(error)
                }
                Err(_) => None,
            }
        };
        let closed = session.cancel.child_token();
        let scp = Scp::new(session.clone(), encoding);
        Ok(Arc::new(Self {
            session,
            sftp,
            scp,
            options,
            transfers: Mutex::new(HashMap::new()),
            closed,
            limiter: FileLimiter::default(),
            transfer_memory: Arc::new(Semaphore::new(16 * 1024)),
            root_shell: Mutex::new(None),
            forwards: Mutex::new(HashMap::new()),
        }))
    }
    pub async fn shutdown(&self) {
        self.closed.cancel();
        self.root_shell.lock().await.take();
        for (_, rule) in self.forwards.lock().await.drain() {
            let _ =
                tokio::time::timeout(Duration::from_secs(2), self.session.forward(&rule, false))
                    .await;
        }
    }
    pub fn cancel(&self) {
        self.closed.cancel();
    }
    pub fn mode(&self) -> &'static str {
        if self.sftp.is_some() {
            "sftp"
        } else {
            "scp"
        }
    }
    async fn stat(&self, path: &str) -> Result<Attributes> {
        if let Some(s) = &self.sftp {
            s.stat(path, false).await
        } else {
            self.scp.stat(path).await
        }
    }
    async fn list(&self, path: &str) -> Result<Vec<(String, Attributes)>> {
        let entries = if let Some(s) = &self.sftp {
            s.list(path).await?
        } else {
            self.scp.list(path).await?
        };
        for (name, _) in &entries {
            scp::validate_name(name)?;
        }
        Ok(entries)
    }
    async fn mkdir(&self, path: &str) -> Result<()> {
        if let Some(s) = &self.sftp {
            s.mkdir(path).await
        } else {
            self.scp.mkdir(path).await
        }
    }
    async fn remove(&self, path: &str, directory: bool) -> Result<()> {
        if let Some(s) = &self.sftp {
            s.remove(path, directory).await
        } else {
            self.scp.remove(path, directory).await
        }
    }
    async fn rename(&self, old: &str, new: &str, replace: bool) -> Result<()> {
        if let Some(s) = &self.sftp {
            s.rename(old, new, replace).await
        } else {
            self.scp.rename(old, new, replace).await
        }
    }
    async fn chmod(&self, path: &str, mode: u32) -> Result<()> {
        ensure!(mode <= 0o7777, "Invalid permissions");
        if let Some(s) = &self.sftp {
            s.setstat(
                path,
                Attributes {
                    permissions: Some(mode),
                    ..Default::default()
                },
            )
            .await
        } else {
            self.scp.chmod(path, mode).await
        }
    }
    fn ensure_directory<'a>(&'a self, path: &'a str, depth: usize) -> BoxWork<'a, ()> {
        Box::pin(async move {
            ensure!(depth <= 128, "Directory depth limit");
            if path.is_empty() || path == "." || path == "/" {
                return Ok(());
            }
            match self.stat(path).await {
                Ok(a) => {
                    ensure!(a.kind() == "directory", "Remote parent is not a directory");
                    return Ok(());
                }
                Err(e) if sftp::missing(&e) => {}
                Err(e) => return Err(e),
            }
            let parent = parent(path);
            self.ensure_directory(&parent, depth + 1).await?;
            self.mkdir(path).await
        })
    }
    fn remove_tree<'a>(
        &'a self,
        path: &'a str,
        state: &'a Transfer,
        depth: usize,
    ) -> BoxWork<'a, ()> {
        Box::pin(async move {
            ensure!(
                depth <= 128 && path != "/" && path != "." && path != "..",
                "Invalid delete target"
            );
            state.ready().await?;
            ensure!(
                state.visited.fetch_add(1, Ordering::Relaxed) < 100_000,
                "Directory entry limit"
            );
            let a = self.stat(path).await?;
            if a.kind() == "directory" {
                for (name, _) in self.list(path).await? {
                    self.remove_tree(&join(path, &name), state, depth + 1)
                        .await?;
                }
            }
            self.remove(path, a.kind() == "directory").await
        })
    }
    fn remote_size<'a>(
        &'a self,
        path: &'a str,
        state: &'a Transfer,
        depth: usize,
    ) -> BoxWork<'a, u64> {
        Box::pin(async move {
            state.ready().await?;
            ensure!(depth <= 128, "Directory depth limit");
            ensure!(
                state.visited.fetch_add(1, Ordering::Relaxed) < 100_000,
                "Directory entry limit"
            );
            let a = self.stat(path).await?;
            if a.kind() == "directory" {
                let mut size = 0u64;
                for (name, _) in self.list(path).await? {
                    size = size
                        .checked_add(
                            self.remote_size(&join(path, &name), state, depth + 1)
                                .await?,
                        )
                        .context("Transfer size overflow")?;
                }
                Ok(size)
            } else {
                ensure!(
                    a.kind() == "file",
                    "Only regular files and directories can be transferred"
                );
                Ok(a.size.unwrap_or(0))
            }
        })
    }
    pub async fn request(
        self: &Arc<Self>,
        request: Value,
        events: Events,
        channel: String,
    ) -> Result<Value> {
        let action = text(&request, "action");
        let id = request["id"].clone();
        let key = id.to_string();
        if matches!(action, "cancel" | "pause" | "resume") {
            if action != "cancel" {
                ensure!(self.sftp.is_some(), "SCP does not support resumable pause");
            }
            if let Some(state) = self
                .transfers
                .lock()
                .await
                .get(&request["targetID"].to_string())
            {
                if action == "cancel" {
                    state.user_cancel.store(true, Ordering::Release);
                    state.cancel.cancel();
                } else {
                    state.paused.store(action == "pause", Ordering::Release);
                }
                state.notify.notify_waiters();
            }
            return Ok(json!({}));
        }
        if action == "close" {
            self.shutdown().await;
            return Ok(json!({}));
        }
        if action == "forwardList" {
            return Ok(
                json!({"rules":self.forwards.lock().await.values().cloned().collect::<Vec<_>>()}),
            );
        }
        if action == "forwardStart" || action == "forwardStop" {
            let rule = &request["rule"];
            let start = action == "forwardStart";
            let mut forwards = self.forwards.lock().await;
            let result = self.session.forward(rule, start).await?;
            if start {
                forwards.insert(text(rule, "id").into(), rule.clone());
            } else {
                forwards.remove(text(rule, "id"));
            }
            return Ok(result);
        }
        if action == "terminalCWD" {
            let target = text(&request, "sourceSessionID");
            let target = if target.is_empty() {
                text(&self.options, "sourceSessionID")
            } else {
                target
            };
            let path = match self.session.terminal_directory(target, &Value::Null).await {
                Ok(path) => path,
                Err(_)
                    if self.options["usesSudo"] == true
                        || self.options["persistentElevation"] == true =>
                {
                    let mut options = self.options.clone();
                    options["elevated"] = json!(true);
                    self.session.terminal_directory(target, &options).await?
                }
                Err(error) => return Err(error),
            };
            return Ok(json!({"path": path}));
        }
        let state = Arc::new(Transfer::new(self.closed.child_token()));
        {
            let mut transfers = self.transfers.lock().await;
            ensure!(!transfers.contains_key(&key), "Duplicate request ID");
            transfers.insert(key.clone(), state.clone());
        }
        let result = self.perform(&request, &state, &events, &channel).await;
        self.transfers.lock().await.remove(&key);
        result
    }
    async fn perform(
        self: &Arc<Self>,
        r: &Value,
        state: &Arc<Transfer>,
        events: &Events,
        channel: &str,
    ) -> Result<Value> {
        state.ready().await?;
        let path = text(r, "path");
        let overwrite = r["overwrite"].as_bool() == Some(true);
        match text(r, "action") {
            "systemInfo" => {
                self.session
                    .monitor
                    .info(&self.session, &state.cancel)
                    .await
            }
            "systemMonitor" => {
                self.session
                    .monitor
                    .request(&self.session, r, &state.cancel)
                    .await
            }
            "exec" => {
                let mut options = self.options.clone();
                options["elevated"] = r["elevated"].clone();
                if options["elevated"] == true
                    && options["persistentElevation"] == true
                    && text(&self.session.config, "username") != "root"
                {
                    let timeout =
                        Duration::from_millis(number(r, "timeoutMS", 15000).clamp(1000, 600000));
                    let receive = {
                        let mut root = self.root_shell.lock().await;
                        let identity = crate::elevation::RootShell::identity(&options);
                        if root.as_ref().is_none_or(|r| r.identity != identity) {
                            *root = Some(crate::elevation::RootShell::new(
                                self.session.handle.clone(),
                                &options,
                                &self.closed,
                            ));
                        }
                        root.as_ref()
                            .unwrap()
                            .submit(text(r, "command"), timeout, &state.cancel)?
                    };
                    return tokio::select! {
                        _=state.cancel.cancelled()=>Err(anyhow::anyhow!("Command cancelled")),
                        result=receive=>result.context("Root command session closed")?,
                    };
                }
                self.session
                    .exec_cancellable(
                        text(r, "command"),
                        Duration::from_millis(number(r, "timeoutMS", 15000).clamp(1000, 600000)),
                        &options,
                        &state.cancel,
                    )
                    .await
            }
            "realpath" => {
                let path = if path.is_empty() { "." } else { path };
                Ok(
                    json!({"path":if let Some(s)=&self.sftp{s.canonicalize(path).await?}else{self.scp.canonicalize(path).await?}}),
                )
            }
            "list" => {
                let mut entries = Vec::new();
                for (name, attrs) in self.list(if path.is_empty() { "." } else { path }).await? {
                    let mut entry = attrs.entry(&name);
                    if attrs.kind() == "symbolicLink" {
                        if let Some(s) = &self.sftp {
                            entry["linkTarget"] = s
                                .read_link(&join(path, &name))
                                .await
                                .ok()
                                .map(Value::String)
                                .unwrap_or(Value::Null);
                        }
                    }
                    entries.push(entry);
                }
                Ok(json!({"entries":entries}))
            }
            "stat" => Ok(
                json!({"entry":self.stat(path).await?.entry(path.rsplit('/').next().unwrap_or(path))}),
            ),
            "mkdir" => {
                self.ensure_directory(path, 0).await?;
                Ok(json!({}))
            }
            "chmod" => {
                self.chmod(path, number(r, "permissions", u64::MAX).try_into()?)
                    .await?;
                Ok(json!({}))
            }
            "rename" => {
                self.rename(text(r, "oldPath"), text(r, "newPath"), false)
                    .await?;
                Ok(json!({}))
            }
            "delete" => {
                self.remove_tree(path, state, 0).await?;
                Ok(json!({}))
            }
            "readText" => {
                let a = self.stat(path).await?;
                ensure!(
                    a.kind() == "file" && a.size.unwrap_or(0) <= 8 * 1024 * 1024,
                    "Text file limit"
                );
                let mut data = Vec::new();
                if let Some(s) = &self.sftp {
                    let handle = s.open(path, 1, Attributes::default()).await?;
                    let result = async {
                        loop {
                            let b = s.read(&handle, data.len() as u64, 65536).await?;
                            if b.is_empty() {
                                break;
                            }
                            data.extend(b);
                            ensure!(data.len() <= 8 * 1024 * 1024, "Text file limit");
                        }
                        Ok::<_, anyhow::Error>(())
                    }
                    .await;
                    let closed = s.close(&handle).await;
                    result?;
                    closed?;
                } else {
                    let (mut stream, size, _) = self.scp.download_stream(path).await?;
                    ensure!(size <= 8 * 1024 * 1024, "Text file limit");
                    data.resize(size as usize, 0);
                    stream.read_exact(&mut data).await?;
                    scp::finish_download(&mut stream).await?;
                }
                let (content, _, _) = encoding_rs::UTF_8.decode(&data);
                Ok(json!({"text":content}))
            }
            "writeText" => {
                let normalized = text(r, "content").replace("\r\n", "\n");
                let content = normalized.as_bytes();
                ensure!(content.len() <= 8 * 1024 * 1024, "Text file limit");
                let permissions = match self.stat(path).await {
                    Ok(a) => a.permissions.unwrap_or(0o600) & 0o7777,
                    Err(e) if sftp::missing(&e) => 0o600,
                    Err(e) => return Err(e),
                };
                let parent = parent(path);
                self.ensure_directory(&parent, 0).await?;
                if !overwrite {
                    ensure!(!self.exists(path).await?, "Remote path already exists");
                }
                let temporary =
                    format!("{}.termpilot-{}.part", path, uuid::Uuid::new_v4().simple());
                let result = async {
                    if let Some(s) = &self.sftp {
                        let handle = s
                            .open(
                                &temporary,
                                2 | 8 | 32,
                                Attributes {
                                    permissions: Some(permissions),
                                    ..Default::default()
                                },
                            )
                            .await?;
                        let writing = async {
                            for (index, chunk) in content.chunks(32768).enumerate() {
                                s.write(&handle, (index * 32768) as u64, chunk).await?;
                            }
                            Ok::<_, anyhow::Error>(())
                        }
                        .await;
                        let closed = s.close(&handle).await;
                        writing?;
                        closed?;
                    } else {
                        let mut stream = self
                            .scp
                            .upload_stream(&temporary, content.len() as u64, permissions)
                            .await?;
                        stream.write_all(content).await?;
                        scp::finish_upload(&mut stream).await?;
                    }
                    self.publish(&temporary, path, overwrite, state).await
                }
                .await;
                if result.is_err() {
                    let _ = tokio::time::timeout(
                        Duration::from_secs(2),
                        self.remove(&temporary, false),
                    )
                    .await;
                }
                result?;
                Ok(json!({}))
            }
            "upload" | "download" => {
                let local_path = normalize_selected_path(Path::new(text(r, "localPath")))?;
                let local = local_path.as_path();
                let remote = text(r, "remotePath");
                ensure!(
                    local.is_absolute() && !remote.is_empty(),
                    "Transfer paths required"
                );
                let upload = text(r, "action") == "upload";
                let total = if upload {
                    {
                        let local = local.to_owned();
                        tokio::task::spawn_blocking(move || local_size(&local, 0)).await??
                    }
                } else {
                    self.remote_size(remote, state, 0).await?
                };
                state.total.store(total, Ordering::Relaxed);
                state.visited.store(0, Ordering::Relaxed);
                self.limiter.limit.store(
                    number(r, "fileConcurrency", 2).clamp(1, 16) as usize,
                    Ordering::Release,
                );
                self.limiter.notify.notify_waiters();
                self.transfer_tree(
                    local, remote, upload, overwrite, r, state, events, channel, 0,
                )
                .await?;
                state.progress(&r["id"], events, channel, 0, true).await?;
                Ok(json!({"bytesTransferred":state.done.load(Ordering::Relaxed)}))
            }
            _ => bail!("Unknown file operation"),
        }
    }
    async fn exists(&self, path: &str) -> Result<bool> {
        match self.stat(path).await {
            Ok(_) => Ok(true),
            Err(e) if sftp::missing(&e) => Ok(false),
            Err(e) => Err(e),
        }
    }
    async fn publish(
        &self,
        temporary: &str,
        path: &str,
        overwrite: bool,
        state: &Transfer,
    ) -> Result<()> {
        state.ready().await?;
        if !overwrite {
            ensure!(
                !self.exists(path).await?,
                "Remote destination already exists"
            );
        }
        // OpenSSH's extension replaces atomically. Legacy servers need the
        // existing remove+rename behavior only after explicit overwrite.
        if overwrite {
            if let Some(s) = &self.sftp {
                if !s.extensions.contains_key("posix-rename@openssh.com")
                    && self.exists(path).await?
                {
                    self.remove_tree(path, state, 0).await?;
                }
            }
        }
        self.rename(temporary, path, overwrite).await
    }
    #[allow(clippy::too_many_arguments)]
    async fn transfer_tree(
        self: &Arc<Self>,
        local: &Path,
        remote: &str,
        upload: bool,
        overwrite: bool,
        r: &Value,
        state: &Arc<Transfer>,
        events: &Events,
        channel: &str,
        _depth: usize,
    ) -> Result<()> {
        let mut pending = vec![(local.to_owned(), remote.to_string(), 0usize)];
        let mut workers = JoinSet::new();
        let concurrency = number(r, "fileConcurrency", 2).clamp(1, 16) as usize;
        let result = async {
            while let Some((local, remote, depth)) = pending.pop() {
                state.ready().await?;
                ensure!(
                    depth <= 128 && state.visited.fetch_add(1, Ordering::Relaxed) < 100_000,
                    "Directory entry limit"
                );
                let directory = if upload {
                    let attrs = std::fs::symlink_metadata(&local)?;
                    ensure!(
                        !crate::platform::is_link(&attrs) && (attrs.is_dir() || attrs.is_file()),
                        "Refusing special source"
                    );
                    attrs.is_dir()
                } else {
                    let attrs = self.stat(&remote).await?;
                    ensure!(
                        matches!(attrs.kind(), "file" | "directory"),
                        "Refusing special remote file"
                    );
                    attrs.kind() == "directory"
                };
                if directory {
                    if upload {
                        self.ensure_directory(&remote, 0).await?;
                        for entry in std::fs::read_dir(&local)? {
                            let entry = entry?;
                            let name = entry
                                .file_name()
                                .into_string()
                                .map_err(|_| anyhow::anyhow!("Local filename is not Unicode"))?;
                            scp::validate_name(&name)?;
                            pending.push((entry.path(), join(&remote, &name), depth + 1));
                        }
                    } else {
                        safe_local_parent(&local)?;
                        if let Ok(attrs) = std::fs::symlink_metadata(&local) {
                            ensure!(
                                overwrite && attrs.is_dir() && !crate::platform::is_link(&attrs),
                                "Local destination already exists"
                            );
                        } else {
                            std::fs::create_dir_all(&local)?;
                        }
                        let entries = self.list(&remote).await?;
                        validate_local_names(entries.iter().map(|(name, _)| name.as_str()))?;
                        for (name, _) in entries {
                            pending.push((local.join(&name), join(&remote, &name), depth + 1));
                        }
                    }
                    ensure!(pending.len() <= 100_000, "Directory entry limit");
                } else {
                    while workers.len() >= concurrency {
                        workers
                            .join_next()
                            .await
                            .context("Transfer worker missing")???;
                    }
                    let (this, r, state, events, channel) = (
                        self.clone(),
                        r.clone(),
                        state.clone(),
                        events.clone(),
                        channel.to_string(),
                    );
                    workers.spawn(async move {
                        let _permit = this.limiter.acquire(&state.cancel).await?;
                        if upload {
                            this.upload_file(
                                &local, &remote, overwrite, &r, &state, &events, &channel,
                            )
                            .await
                        } else {
                            this.download_file(
                                &remote, &local, overwrite, &r, &state, &events, &channel,
                            )
                            .await
                        }
                    });
                }
            }
            while let Some(result) = workers.join_next().await {
                result??;
            }
            Ok::<_, anyhow::Error>(())
        }
        .await;
        if result.is_err() {
            state.cancel.cancel();
        }
        while workers.join_next().await.is_some() {}
        result
    }
    #[allow(clippy::too_many_arguments)]
    async fn upload_file(
        &self,
        local: &Path,
        remote: &str,
        overwrite: bool,
        r: &Value,
        state: &Arc<Transfer>,
        events: &Events,
        channel: &str,
    ) -> Result<()> {
        if !text(r, "resumeDirectory").is_empty() && self.sftp.is_some() {
            return self
                .resume_file(local, remote, true, overwrite, r, state, events, channel)
                .await;
        }
        self.ensure_directory(&parent(remote), 0).await?;
        if !overwrite {
            ensure!(!self.exists(remote).await?, "Remote path already exists");
        }
        let source = Arc::new(open_local_source(local)?);
        let size = source.metadata()?.len();
        let existing = match self.stat(remote).await {
            Ok(a) => Some(a),
            Err(e) if sftp::missing(&e) => None,
            Err(e) => return Err(e),
        };
        let mode = existing
            .as_ref()
            .and_then(|a| a.permissions)
            .unwrap_or(0o644)
            & 0o7777;
        let temporary = format!("{remote}.termpilot-{}.part", uuid::Uuid::new_v4().simple());
        let result=async{
            if let Some(s)=&self.sftp{
                let handle=s.open(&temporary,2|8|32,Attributes{permissions:Some(mode),..Default::default()}).await?;
                let mut workers = JoinSet::new();
                let chunks = number(r, "chunkConcurrency", 8).clamp(1, 32) as usize;
                let logical_length = number(r, "chunkSizeBytes", 65536).clamp(4096, 10 * 1024 * 1024) as usize;
                // A server's advertised maximum is a safety limit, not its
                // optimal write size. Large packets stall small SSH windows
                // (notably Dropbear); 64 KiB writes keep acknowledgements and
                // progress flowing without excessive task/packet overhead.
                let length = logical_length.min(s.max_write.load(Ordering::Relaxed)).min(64 * 1024);
                let parallel = (logical_length * chunks / length).clamp(1, 32);
                let mut offset = 0u64;
                // Schedule wire-sized writes independently, matching downloads.
                // A large UI chunk must not serialize dozens of round trips or
                // hide progress until every sub-packet has been acknowledged.
                let writing = async {
                    while offset < size || !workers.is_empty() {
                        state.ready().await?;
                        while offset < size && workers.len() < parallel {
                            let count = length.min((size - offset) as usize);
                            let position = offset;
                            offset += count as u64;
                            let (s, handle, source, state, memory) = (s.clone(), handle.clone(), source.clone(), state.clone(), self.transfer_memory.clone());
                            workers.spawn(async move {
                                state.ready().await?;
                                let _memory = tokio::select! {
                                    _ = state.cancel.cancelled() => bail!("Transfer cancelled"),
                                    permit = memory.acquire_many_owned(count.div_ceil(4096) as u32) => permit?
                                };
                                let data = tokio::task::spawn_blocking(move || read_at(&source, position, count)).await??;
                                state.ready().await?;
                                state.interruptible(s.write(&handle, position, &data)).await?;
                                Ok::<_, anyhow::Error>(count as u64)
                            });
                        }
                        let bytes = tokio::select! {
                            _ = state.cancel.cancelled() => bail!("Transfer cancelled"),
                            result = workers.join_next() => result.context("Missing transfer worker")???
                        };
                        state.progress(&r["id"], events, channel, bytes, false).await?;
                    }
                    Ok::<_, anyhow::Error>(())
                }.await;
                // Wake paused/waiting siblings on failure before draining them.
                if writing.is_err() { state.cancel.cancel(); }
                while workers.join_next().await.is_some() {}
                let closed = tokio::time::timeout(Duration::from_secs(2), s.close(&handle)).await;
                writing?;
                closed??;
            }else{let mut stream=self.scp.upload_stream(&temporary,size,mode).await?;let mut offset=0;while offset<size{state.ready().await?;let data=read_at(&source,offset,65536.min((size-offset)as usize))?;tokio::time::timeout(Duration::from_secs(30),stream.write_all(&data)).await??;offset+=data.len()as u64;state.progress(&r["id"],events,channel,data.len()as u64,false).await?;}scp::finish_upload(&mut stream).await?;}
            if existing.as_ref().is_some_and(|a|a.kind()=="directory"){ensure!(overwrite,"Remote directory exists");self.remove_tree(remote,state,0).await?;}self.publish(&temporary,remote,overwrite,state).await
        }.await;
        if result.is_err() {
            let _ =
                tokio::time::timeout(Duration::from_secs(2), self.remove(&temporary, false)).await;
        }
        result
    }
    #[allow(clippy::too_many_arguments)]
    async fn download_file(
        &self,
        remote: &str,
        local: &Path,
        overwrite: bool,
        r: &Value,
        state: &Arc<Transfer>,
        events: &Events,
        channel: &str,
    ) -> Result<()> {
        if !text(r, "resumeDirectory").is_empty() && self.sftp.is_some() {
            return self
                .resume_file(local, remote, false, overwrite, r, state, events, channel)
                .await;
        }
        safe_local_parent(local)?;
        if local.exists() || std::fs::symlink_metadata(local).is_ok() {
            ensure!(
                overwrite
                    && std::fs::symlink_metadata(local)?.is_file()
                    && !crate::platform::is_link(&std::fs::symlink_metadata(local)?),
                "Local destination already exists"
            );
        }
        let parent = local.parent().context("Local parent")?;
        std::fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(".termpilot-{}.part", uuid::Uuid::new_v4().simple()));
        let target = Arc::new(
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)?,
        );
        let result=async{
            if let Some(s)=&self.sftp{
                let attrs = s.stat(remote, true).await?;
                ensure!(attrs.kind() == "file", "Not a regular remote file");
                let size = attrs.size.context("Remote size unavailable")?;
                let handle = s.open(remote, 1, Attributes::default()).await?;
                let mut workers = JoinSet::new();
                let chunks = number(r, "chunkConcurrency", 8).clamp(1, 32) as usize;
                let logical_length = number(r, "chunkSizeBytes", 65536).clamp(4096, 10 * 1024 * 1024) as usize;
                // Keep the configured in-flight byte budget, but schedule wire
                // reads independently. Waiting for every sub-read of one large
                // logical chunk leaves the SSH window empty at each boundary.
                let length = logical_length.min(s.max_read.load(Ordering::Relaxed));
                let parallel = (logical_length * chunks / length).clamp(1, 64);
                let mut offset = 0;
                let reading = async {
                    while offset < size || !workers.is_empty() {
                        state.ready().await?;
                        while offset < size && workers.len() < parallel {
                            let count = length.min((size - offset) as usize);
                            let position = offset;
                            offset += count as u64;
                            let (s, handle, target, state, memory) = (s.clone(), handle.clone(), target.clone(), state.clone(), self.transfer_memory.clone());
                            workers.spawn(async move {
                                state.ready().await?;
                                let _memory = tokio::select! {
                                    _ = state.cancel.cancelled() => bail!("Transfer cancelled"),
                                    permit = memory.acquire_many_owned(count.div_ceil(4096) as u32) => permit?
                                };
                                let mut bytes = Vec::with_capacity(count);
                                while bytes.len() < count {
                                    state.ready().await?;
                                    let b = state.interruptible(s.read(&handle, position + bytes.len() as u64, count - bytes.len())).await?;
                                    ensure!(!b.is_empty(), "Remote file shortened during download");
                                    bytes.extend(b);
                                }
                                state.ready().await?;
                                tokio::task::spawn_blocking(move || write_at(&target, position, &bytes)).await??;
                                Ok::<_, anyhow::Error>(count as u64)
                            });
                        }
                        let bytes = tokio::select! {
                            _ = state.cancel.cancelled() => bail!("Transfer cancelled"),
                            r = workers.join_next() => r.context("Missing transfer worker")???
                        };
                        state.progress(&r["id"], events, channel, bytes, false).await?;
                    }
                    Ok::<_, anyhow::Error>(())
                }.await;
                if reading.is_err() { state.cancel.cancel(); }
                while workers.join_next().await.is_some() {}
                let closed = tokio::time::timeout(Duration::from_secs(2), s.close(&handle)).await;
                reading?;
                closed??;
            }else{let(mut stream,size,_)=self.scp.download_stream(remote).await?;let mut offset=0;while offset<size{state.ready().await?;let mut data=vec![0;65536.min((size-offset)as usize)];tokio::time::timeout(Duration::from_secs(30),stream.read_exact(&mut data)).await??;write_at(&target,offset,&data)?;offset+=data.len()as u64;state.progress(&r["id"],events,channel,data.len()as u64,false).await?;}scp::finish_download(&mut stream).await?;}
            state.ready().await?;target.sync_all()?;safe_local_parent(local)?;
            if overwrite{crate::platform::replace_file(&temporary,local)?;}else{crate::platform::publish_new_file(&temporary,local)?;}Ok::<_,anyhow::Error>(())
        }.await;
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result
    }
}
fn parent(path: &str) -> String {
    match path.rsplit_once('/') {
        Some(("", _)) => "/".into(),
        Some((p, _)) => p.into(),
        None => ".".into(),
    }
}
fn join(parent: &str, name: &str) -> String {
    format!("{}/{}", parent.trim_end_matches('/'), name)
}
fn local_size(path: &Path, depth: usize) -> Result<u64> {
    fn walk(path: &Path, depth: usize, visited: &mut usize) -> Result<u64> {
        *visited += 1;
        ensure!(*visited <= 100_000, "Directory entry limit");
        ensure!(depth <= 128, "Directory depth limit");
        let a = std::fs::symlink_metadata(path)?;
        ensure!(
            !crate::platform::is_link(&a),
            "Refusing symbolic link source"
        );
        if a.is_file() {
            return Ok(a.len());
        }
        ensure!(a.is_dir(), "Unsupported local file type");
        let mut size = 0u64;
        for child in std::fs::read_dir(path)? {
            size = size
                .checked_add(walk(&child?.path(), depth + 1, visited)?)
                .context("Transfer size overflow")?;
        }
        Ok(size)
    }
    walk(path, depth, &mut 0)
}
fn safe_local_parent(path: &Path) -> Result<()> {
    ensure!(path.is_absolute(), "Absolute local path required");
    for part in path.components() {
        ensure!(
            !matches!(part, std::path::Component::ParentDir),
            "Parent traversal rejected"
        );
    }
    let mut cursor = path.parent();
    while let Some(p) = cursor {
        if let Ok(a) = std::fs::symlink_metadata(p) {
            ensure!(
                !crate::platform::is_link(&a),
                "Refusing symbolic link destination ancestor"
            );
        }
        cursor = p.parent();
    }
    Ok(())
}
fn open_local_source(path: &Path) -> Result<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = options.open(path)?;
    ensure!(
        !crate::platform::is_link(&file.metadata()?),
        "Refusing link source"
    );
    ensure!(file.metadata()?.is_file(), "Not a regular local file");
    Ok(file)
}
fn read_at(file: &std::fs::File, offset: u64, size: usize) -> Result<Vec<u8>> {
    let mut bytes = vec![0; size];
    let mut read = 0;
    while read < size {
        #[cfg(unix)]
        let n = {
            use std::os::unix::fs::FileExt;
            file.read_at(&mut bytes[read..], offset + read as u64)?
        };
        #[cfg(windows)]
        let n = {
            use std::os::windows::fs::FileExt;
            file.seek_read(&mut bytes[read..], offset + read as u64)?
        };
        ensure!(n > 0, "Local file shortened during upload");
        read += n;
    }
    Ok(bytes)
}
fn write_at(file: &std::fs::File, offset: u64, bytes: &[u8]) -> Result<()> {
    let mut written = 0;
    while written < bytes.len() {
        #[cfg(unix)]
        let n = {
            use std::os::unix::fs::FileExt;
            file.write_at(&bytes[written..], offset + written as u64)?
        };
        #[cfg(windows)]
        let n = {
            use std::os::windows::fs::FileExt;
            file.seek_write(&bytes[written..], offset + written as u64)?
        };
        ensure!(n > 0, "Local file write failed");
        written += n;
    }
    Ok(())
}

// Resolve aliases chosen by the user once (macOS /tmp and /var are symlinks).
// Descendants supplied by the remote peer still pass no-symlink checks.
fn normalize_selected_path(path: &Path) -> Result<std::path::PathBuf> {
    ensure!(
        path.is_absolute()
            && !path
                .components()
                .any(|p| matches!(p, std::path::Component::ParentDir)),
        "Invalid local path"
    );
    let mut parent = path.parent().context("Local parent required")?;
    let mut suffix = vec![path
        .file_name()
        .context("Local filename required")?
        .to_os_string()];
    while !parent.exists() {
        suffix.push(
            parent
                .file_name()
                .context("Existing local ancestor required")?
                .to_os_string(),
        );
        parent = parent
            .parent()
            .context("Existing local ancestor required")?;
    }
    let mut result = std::fs::canonicalize(parent)?;
    for name in suffix.into_iter().rev() {
        result.push(name);
    }
    Ok(result)
}

struct FileLimiter {
    active: AtomicUsize,
    limit: AtomicUsize,
    notify: Notify,
}
impl Default for FileLimiter {
    fn default() -> Self {
        Self {
            active: AtomicUsize::new(0),
            limit: AtomicUsize::new(2),
            notify: Notify::new(),
        }
    }
}
struct FilePermit<'a>(&'a FileLimiter);
impl Drop for FilePermit<'_> {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::AcqRel);
        self.0.notify.notify_waiters();
    }
}
impl FileLimiter {
    async fn acquire(&self, cancel: &CancellationToken) -> Result<FilePermit<'_>> {
        loop {
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            ensure!(!cancel.is_cancelled(), "Transfer cancelled");
            if self
                .active
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                    (n < self.limit.load(Ordering::Acquire)).then_some(n + 1)
                })
                .is_ok()
            {
                return Ok(FilePermit(self));
            }
            tokio::select! {_=cancel.cancelled()=>bail!("Transfer cancelled"),_=notified=>{}}
        }
    }
}
fn validate_local_names<'a>(names: impl Iterator<Item = &'a str>) -> Result<()> {
    let mut seen = std::collections::HashSet::new();
    for name in names {
        scp::validate_name(name)?;
        #[cfg(windows)]
        {
            ensure!(
                !name.ends_with(['.', ' '])
                    && !name.contains([':', '<', '>', '"', '|', '?', '*'])
                    && !name.chars().any(|c| c.is_control()),
                "Invalid Windows filename"
            );
            let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
            ensure!(
                !matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
                    && !(stem.len() == 4
                        && (stem.starts_with("COM") || stem.starts_with("LPT"))
                        && matches!(stem.as_bytes()[3], b'1'..=b'9')),
                "Reserved Windows filename"
            );
        }
        // Default macOS and Windows volumes are case-insensitive. Reject aliases
        // before downloading either name, rather than silently overwriting one.
        #[cfg(any(windows, target_os = "macos"))]
        let key = name.to_lowercase();
        #[cfg(not(any(windows, target_os = "macos")))]
        let key = name.to_string();
        ensure!(seen.insert(key), "Colliding destination names");
    }
    Ok(())
}
