//! Native Apple drag/file-copy protocol. Never uses SSH or a remote shell.
use super::{
    connection::Writer,
    control::{deflate, inflate, put_bytes, read_bytes, word},
    file_fs as fs,
};
use crate::{ipc::text, screen::Output};
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    io::{BufWriter, Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, watch, Mutex};
use tokio_util::sync::CancellationToken;
fn remote_absolute(path: &str) -> Result<()> {
    ensure!(
        path.starts_with('/')
            && path.len() <= 4095
            && !path.contains('\0')
            && !path.split('/').any(|p| p == ".."),
        "invalidPath"
    );
    Ok(())
}
const MAX_FRAME: usize = 4 * 1024 * 1024;
#[cfg(all(test, target_os = "macos"))]
#[path = "file_live.rs"]
mod live;
type SharedWriter = Arc<Mutex<Writer>>;
type Record = (u16, Vec<u8>);
pub fn frame(command: u16, sid: u32, payload: &[u8]) -> Result<Vec<u8>> {
    ensure!(sid != 0 && payload.len() + 14 <= MAX_FRAME, "invalidFrame");
    let mut out = vec![0x22, 0];
    out.extend((payload.len() as u32 + 8).to_be_bytes());
    out.extend(1u16.to_be_bytes());
    out.extend(command.to_be_bytes());
    out.extend(sid.to_be_bytes());
    out.extend(payload);
    Ok(out)
}
fn request(command: u16, sid: u32, path: &str) -> Result<Vec<u8>> {
    remote_absolute(path)?;
    let mut body = (u32::from(command == 1)).to_be_bytes().to_vec();
    body.extend([0; 4]);
    body.extend((path.len() as u16).to_be_bytes());
    body.extend(path.as_bytes());
    body.push(0);
    frame(command, sid, &body)
}
#[derive(Default)]
pub struct Wire {
    buffer: Vec<u8>,
}
impl Wire {
    pub fn feed(&mut self, data: &[u8]) -> Result<Vec<Vec<u8>>> {
        ensure!(
            self.buffer.len() + data.len() <= MAX_FRAME + 65536,
            "invalidFrame"
        );
        self.buffer.extend(data);
        let mut out = Vec::new();
        while let Some(&kind) = self.buffer.first() {
            let (minimum, offset, limit) = match kind {
                0x22 => (6, 2, MAX_FRAME),
                0x20 => (16, 12, MAX_FRAME),
                0x1e => (12, 8, 4096),
                _ => {
                    out.push(std::mem::take(&mut self.buffer));
                    break;
                }
            };
            if self.buffer.len() < minimum {
                break;
            }
            let size = u32::from_be_bytes(self.buffer[offset..offset + 4].try_into()?) as usize;
            let total = minimum + size;
            ensure!(
                total <= limit && (kind != 0x22 || total >= 14),
                "invalidFrame"
            );
            if self.buffer.len() < total {
                break;
            }
            out.push(self.buffer.drain(..total).collect());
        }
        Ok(out)
    }
}
pub fn drag_archive(paths: &[String], sid: u32) -> Result<Vec<u8>> {
    ensure!((1..=256).contains(&paths.len()), "tooManyFiles");
    let mut archive = Vec::new();
    for path in paths {
        remote_absolute(path)?;
        // URL setters preserve existing %xx sequences; encode each filename
        // component so a literal percent sign survives the round trip.
        let encoded = path
            .split('/')
            .map(|part| {
                percent_encoding::utf8_percent_encode(part, percent_encoding::NON_ALPHANUMERIC)
                    .to_string()
            })
            .collect::<Vec<_>>()
            .join("/");
        let url = url::Url::parse(&format!("file://{encoded}"))?;
        archive.extend(1u32.to_be_bytes());
        put_bytes(&mut archive, b"public.file-url");
        archive.extend([0; 4]);
        archive.extend(1u32.to_be_bytes());
        put_bytes(&mut archive, b"com.apple.ostype");
        put_bytes(&mut archive, b"furl");
        put_bytes(&mut archive, url.as_str().as_bytes());
    }
    let packed = deflate(&archive)?;
    ensure!(packed.len() <= 60000, "tooManyFiles");
    let mut out = vec![0x20, 0, 0, 0];
    out.extend(sid.to_be_bytes());
    out.extend((archive.len() as u32).to_be_bytes());
    put_bytes(&mut out, &packed);
    Ok(out)
}
pub fn remote_paths(packet: &[u8]) -> Result<(u32, Vec<String>)> {
    ensure!(packet.len() >= 16 && packet[0] == 0x20, "invalidDrag");
    let sid = u32::from_be_bytes(packet[4..8].try_into()?);
    ensure!(sid != 0, "invalidDrag");
    let mut fields = &packet[8..];
    let size = word(&mut fields)?;
    let packed = word(&mut fields)?;
    ensure!(fields.len() == packed, "invalidDrag");
    let raw = inflate(fields, size, 8 * 1024 * 1024)?;
    let mut data = raw.as_slice();
    let mut paths = Vec::new();
    let mut items = 0;
    while !data.is_empty() {
        items += 1;
        let count = word(&mut data)?;
        ensure!(items <= 256 && count <= 256, "invalidDrag");
        for _ in 0..count {
            let uti = read_bytes(&mut data)?;
            word(&mut data)?;
            let aliases = word(&mut data)?;
            ensure!(aliases <= 64, "invalidDrag");
            let mut file = uti == b"public.file-url";
            for _ in 0..aliases {
                read_bytes(&mut data)?;
                file |= read_bytes(&mut data)? == b"furl";
            }
            let value = read_bytes(&mut data)?;
            if file {
                let mut url = url::Url::parse(std::str::from_utf8(value)?)?;
                ensure!(
                    url.scheme() == "file" && url.query().is_none() && url.fragment().is_none(),
                    "invalidPath"
                );
                url.set_host(None)
                    .map_err(|_| anyhow::anyhow!("invalidPath"))?;
                let path = percent_encoding::percent_decode_str(url.path().trim_end_matches('/'))
                    .decode_utf8()?
                    .into_owned();
                remote_absolute(&path)?;
                // These are remote POSIX names, even when the client is Windows.
                // Apply Windows destination restrictions only when receiving files.
                let name = path.rsplit('/').next().context("invalidName")?;
                ensure!(
                    !name.is_empty()
                        && name != "."
                        && name != ".."
                        && name.len() <= 255
                        && !name.contains(['\\', '\0']),
                    "invalidName"
                );
                if !paths.contains(&path) {
                    paths.push(path);
                }
            }
        }
    }
    ensure!(paths.len() <= 256, "invalidDrag");
    Ok((sid, paths))
}
struct Pending {
    sid: u32,
    paths: Vec<String>,
    ids: Vec<Option<String>>,
    deadline: Instant,
    dropped: bool,
}
struct Job {
    request: String,
    source: String,
    destination: String,
    direction: &'static str,
    cancel: CancellationToken,
    completed: AtomicU64,
    total: AtomicU64,
    paused: watch::Sender<bool>,
}
struct Shared {
    closed: CancellationToken,
    queued: StdMutex<HashMap<String, Arc<Job>>>,
    active: StdMutex<HashMap<u32, (mpsc::Sender<Record>, CancellationToken)>>,
    writer: SharedWriter,
    output: Output,
}
pub struct Files {
    wire: Wire,
    pending_records: VecDeque<(mpsc::Sender<Record>, CancellationToken, Record)>,
    pending: Option<Pending>,
    remote: HashMap<String, Instant>,
    jobs: mpsc::Sender<Arc<Job>>,
    shared: Arc<Shared>,
    worker: Option<tokio::task::JoinHandle<()>>,
}
impl Files {
    pub fn new(writer: SharedWriter, output: Output) -> Self {
        let (jobs, mut receiver) = mpsc::channel::<Arc<Job>>(256);
        let shared = Arc::new(Shared {
            closed: CancellationToken::new(),
            queued: StdMutex::new(HashMap::new()),
            active: StdMutex::new(HashMap::new()),
            writer,
            output,
        });
        let state = shared.clone();
        let worker = tokio::spawn(async move {
            loop {
                let job = tokio::select! {_=state.closed.cancelled()=>break,job=receiver.recv()=>match job{Some(job)=>job,None=>break}};
                let shared = state.clone();
                let job2 = job.clone();
                let result = tokio::task::spawn_blocking(move || transfer(job2, shared)).await;
                if result.is_err() {
                    let _=state.output.emit(json!({"kind":"fileTransfer","requestID":job.request,"stage":"failed","code":"ioError"}),Vec::new()).await;
                }
                state.queued.lock().unwrap().remove(&job.request);
            }
            let abandoned = state
                .queued
                .lock()
                .unwrap()
                .drain()
                .map(|(_, j)| j)
                .collect::<Vec<_>>();
            for job in abandoned {
                job.cancel.cancel();
                let _=state.output.emit(json!({"kind":"fileTransfer","requestID":job.request,"direction":job.direction,"stage":"cancelled","code":"disconnected"}),Vec::new()).await;
            }
        });
        Self {
            wire: Wire::default(),
            pending_records: VecDeque::new(),
            pending: None,
            remote: HashMap::new(),
            jobs,
            shared,
            worker: Some(worker),
        }
    }
    async fn send(&self, bytes: &[u8]) -> Result<()> {
        self.shared.writer.lock().await.send(bytes).await
    }
    async fn pending_progress(
        &self,
        pending: &Pending,
        stage: &str,
        code: Option<&str>,
    ) -> Result<()> {
        for (path, id) in pending.paths.iter().zip(&pending.ids) {
            if let Some(id) = id {
                self.shared.output.emit(json!({"kind":"fileTransfer","requestID":id,"name":Path::new(path).file_name().and_then(|s|s.to_str()),"direction":"upload","stage":stage,"code":code}),Vec::new()).await?;
            }
        }
        Ok(())
    }
    async fn enqueue(
        &self,
        request: String,
        source: String,
        destination: String,
        direction: &'static str,
    ) -> Result<()> {
        ensure!((1..=80).contains(&request.len()), "invalidRequest");
        if direction == "upload" {
            fs::absolute(&source)?;
            remote_absolute(&destination)?;
        } else {
            remote_absolute(&source)?;
            fs::absolute(&destination)?;
        }
        let job = Arc::new(Job {
            request: request.clone(),
            source,
            destination,
            direction,
            cancel: CancellationToken::new(),
            completed: AtomicU64::new(0),
            total: AtomicU64::new(0),
            paused: watch::channel(false).0,
        });
        {
            let mut queued = self.shared.queued.lock().unwrap();
            ensure!(!queued.contains_key(&request), "invalidRequest");
            ensure!(queued.len() < 256, "tooManyFiles");
            queued.insert(request.clone(), job.clone());
        }
        self.shared.output.emit(json!({"kind":"fileTransfer","requestID":request,"name":Path::new(&job.source).file_name().and_then(|s|s.to_str()),"direction":direction,"stage":"queued","completedBytes":0,"totalBytes":0}),Vec::new()).await?;
        if self.jobs.try_send(job).is_err() {
            self.shared.queued.lock().unwrap().remove(&request);
            anyhow::bail!("tooManyFiles");
        }
        Ok(())
    }
    pub fn is_backpressured(&self) -> bool {
        !self.pending_records.is_empty()
    }
    // Keep the TCP backlog bounded without blocking UDP media or input/control
    // handling while a download is paused. Reserve is cancellation-safe.
    pub async fn flush_pending(&mut self) {
        if let Some((inbox, cancel, _)) = self.pending_records.front() {
            let permit = tokio::select! {
                _ = cancel.cancelled() => None,
                _ = self.shared.closed.cancelled() => None,
                result = inbox.clone().reserve_owned() => result.ok(),
            };
            let (_, _, record) = self.pending_records.pop_front().unwrap();
            if let Some(permit) = permit {
                permit.send(record);
            }
        } else {
            std::future::pending::<()>().await;
        }
    }
    pub async fn command(&mut self, command: &Value) -> Result<bool> {
        match text(command, "kind") {
            "dragEnter" => {
                let values = command["paths"].as_array().context("invalidPath")?;
                ensure!((1..=256).contains(&values.len()), "tooManyFiles");
                let mut paths = Vec::new();
                let mut advertised = Vec::new();
                for value in values {
                    let path = fs::absolute(value.as_str().context("invalidPath")?)?;
                    let info = std::fs::symlink_metadata(&path)?;
                    ensure!(info.is_dir() || info.is_file(), "unsupportedFileType");
                    let path = path.canonicalize()?;
                    let name = path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .context("invalidName")?;
                    fs::basename(name)?;
                    let name = name.to_string();
                    let path = path.to_str().context("invalidPath")?.to_string();
                    let advertised_path = if cfg!(windows) {
                        format!("/TermPilot/{}/{}", uuid::Uuid::new_v4(), name)
                    } else {
                        path.clone()
                    };
                    advertised.push(if info.is_dir() {
                        format!("{}/", advertised_path.trim_end_matches('/'))
                    } else {
                        advertised_path
                    });
                    paths.push(path);
                }
                let sid = rand::random::<u32>().max(1);
                let ids = paths
                    .iter()
                    .map(|_| Some(uuid::Uuid::new_v4().to_string()))
                    .collect();
                self.send(&drag_archive(&advertised, sid)?).await?;
                self.pending = Some(Pending {
                    sid,
                    paths,
                    ids,
                    deadline: Instant::now() + Duration::from_secs(120),
                    dropped: false,
                });
            }
            "dragDrop" => {
                if let Some(mut pending) = self.pending.take() {
                    pending.dropped = true;
                    pending.deadline = Instant::now() + Duration::from_secs(30);
                    self.pending_progress(&pending, "waitingDestination", None)
                        .await?;
                    self.pending = Some(pending);
                }
            }
            "dragCancel" => {
                if let Some(pending) = self.pending.take() {
                    let mut out = vec![0x20, 0, 0, 0];
                    out.extend(pending.sid.to_be_bytes());
                    out.extend([0; 8]);
                    self.send(&out).await?;
                    if pending.dropped {
                        self.pending_progress(&pending, "cancelled", Some("cancelled"))
                            .await?;
                    }
                }
            }
            "dragRequest" => {
                let mut out = vec![0x0e, 0, 0, 0];
                out.extend(rand::random::<u32>().max(1).to_be_bytes());
                self.send(&out).await?;
            }
            "fileDownload" => {
                let source = text(command, "source");
                ensure!(
                    self.remote
                        .get(source)
                        .is_some_and(|expiry| *expiry > Instant::now()),
                    "expiredDrag"
                );
                self.enqueue(
                    text(command, "requestID").into(),
                    source.into(),
                    text(command, "destination").into(),
                    "download",
                )
                .await?;
            }
            "filePause" | "fileResume" => {
                let id = text(command, "requestID");
                let job = self.shared.queued.lock().unwrap().get(id).cloned();
                if let Some(job) = job {
                    let paused = text(command, "kind") == "filePause";
                    job.paused.send_replace(paused);
                    self.shared.output.emit(json!({"kind":"fileTransfer","requestID":id,
                        "name":Path::new(&job.source).file_name().and_then(|s|s.to_str()),
                        "direction":job.direction,"stage":if paused {"paused"} else {"transferring"},
                        "completedBytes":job.completed.load(Ordering::Relaxed),
                        "totalBytes":job.total.load(Ordering::Relaxed)}),Vec::new()).await?;
                }
            }
            "fileCancel" => {
                let request = command["requestID"].as_str();
                let jobs = self
                    .shared
                    .queued
                    .lock()
                    .unwrap()
                    .values()
                    .filter(|job| request.is_none_or(|r| r == job.request))
                    .cloned()
                    .collect::<Vec<_>>();
                for job in jobs {
                    job.cancel.cancel();
                    self.shared
                        .output
                        .emit(
                            json!({"kind":"fileTransfer","requestID":job.request,
                        "name":Path::new(&job.source).file_name().and_then(|s|s.to_str()),
                        "direction":job.direction,"stage":"cancelled",
                        "completedBytes":job.completed.load(Ordering::Relaxed),
                        "totalBytes":job.total.load(Ordering::Relaxed)}),
                            Vec::new(),
                        )
                        .await?;
                }
                if let Some(pending) = &mut self.pending {
                    for (path, id) in pending.paths.iter().zip(&mut pending.ids) {
                        if id
                            .as_ref()
                            .is_some_and(|id| request.is_none_or(|r| r == id))
                        {
                            let id = id.take().unwrap();
                            self.shared.output.emit(json!({"kind":"fileTransfer","requestID":id,"name":Path::new(path).file_name().and_then(|s|s.to_str()),"direction":"upload","stage":"cancelled","code":"cancelled"}),Vec::new()).await?;
                        }
                    }
                }
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
    pub async fn message(&mut self, message: &[u8]) -> Result<Option<Vec<Vec<u8>>>> {
        if self.wire.buffer.is_empty()
            && !message
                .first()
                .is_some_and(|kind| [0x20, 0x1e, 0x22].contains(kind))
        {
            return Ok(None);
        }
        let packets = self.wire.feed(message)?;
        let mut unrelated = Vec::new();
        for packet in packets {
            match packet[0] {
                0x20 => {
                    if packet[4..8] == [0; 4] || packet[8..16] == [0; 8] {
                        self.shared
                            .output
                            .emit(json!({"kind":"remoteDrag","paths":[]}), Vec::new())
                            .await?;
                    } else {
                        let (sid, paths) = remote_paths(&packet)?;
                        self.remote.retain(|_, expiry| *expiry > Instant::now());
                        ensure!(self.remote.len() + paths.len() <= 4096, "tooManyFiles");
                        for path in &paths {
                            self.remote
                                .insert(path.clone(), Instant::now() + Duration::from_secs(120));
                        }
                        self.shared
                            .output
                            .emit(
                                json!({"kind":"remoteDrag","paths":paths,"dragID":sid}),
                                Vec::new(),
                            )
                            .await?;
                    }
                }
                0x1e => {
                    let sid = u32::from_be_bytes(packet[4..8].try_into()?);
                    let destination = std::str::from_utf8(&packet[12..])?.trim_end_matches('\0');
                    remote_absolute(destination)?;
                    if self
                        .pending
                        .as_ref()
                        .is_some_and(|p| p.sid == sid && p.dropped && p.deadline >= Instant::now())
                    {
                        let pending = self.pending.take().unwrap();
                        for (path, id) in pending.paths.into_iter().zip(pending.ids) {
                            if let Some(id) = id {
                                self.enqueue(id, path, destination.into(), "upload").await?;
                            }
                        }
                    }
                }
                0x22 => {
                    ensure!(packet[1] == 0 && packet[6..8] == [0, 1], "invalidFrame");
                    let command = u16::from_be_bytes(packet[8..10].try_into()?);
                    let sid = u32::from_be_bytes(packet[10..14].try_into()?);
                    ensure!(sid != 0, "invalidFrame");
                    let active = self.shared.active.lock().unwrap().get(&sid).cloned();
                    if let Some((inbox, cancel)) = active {
                        let record = (command, packet[14..].to_vec());
                        if self.pending_records.is_empty() {
                            if let Err(mpsc::error::TrySendError::Full(record)) =
                                inbox.try_send(record)
                            {
                                self.pending_records.push_back((inbox, cancel, record));
                            }
                        } else {
                            self.pending_records.push_back((inbox, cancel, record));
                        }
                    }
                }
                _ => unrelated.push(packet),
            }
        }
        Ok(Some(unrelated))
    }
    pub async fn tick(&mut self) -> Result<()> {
        if self
            .pending
            .as_ref()
            .is_some_and(|p| p.deadline < Instant::now())
        {
            let pending = self.pending.take().unwrap();
            if pending.dropped {
                self.pending_progress(&pending, "failed", Some("timeout"))
                    .await?;
            }
        }
        self.remote.retain(|_, expiry| *expiry > Instant::now());
        Ok(())
    }
    pub async fn close(&mut self) {
        self.shared.closed.cancel();
        let jobs = self
            .shared
            .queued
            .lock()
            .unwrap()
            .values()
            .cloned()
            .collect::<Vec<_>>();
        for job in jobs {
            job.cancel.cancel();
        }
        if let Some(pending) = self.pending.take() {
            if pending.dropped {
                let _ = self
                    .pending_progress(&pending, "failed", Some("disconnected"))
                    .await;
            }
        }
        if let Some(worker) = self.worker.take() {
            let _ = tokio::time::timeout(Duration::from_secs(5), worker).await;
        }
    }
}
impl Drop for Files {
    fn drop(&mut self) {
        self.shared.closed.cancel();
    }
}

struct Transfer {
    job: Arc<Job>,
    shared: Arc<Shared>,
    sid: u32,
    inbox: mpsc::Receiver<Record>,
    runtime: tokio::runtime::Handle,
    total: u64,
    completed: u64,
    last_progress: Instant,
    name: String,
}
impl Transfer {
    fn check(&self) -> Result<()> {
        ensure!(!self.shared.closed.is_cancelled(), "disconnected");
        ensure!(!self.job.cancel.is_cancelled(), "cancelled");
        let mut paused = self.job.paused.subscribe();
        self.runtime.block_on(async {
            while *paused.borrow_and_update() {
                tokio::select! {
                    _ = self.shared.closed.cancelled() => anyhow::bail!("disconnected"),
                    _ = self.job.cancel.cancelled() => anyhow::bail!("cancelled"),
                    _ = paused.changed() => {},
                }
            }
            Ok(())
        })
    }
    fn send(&self, bytes: &[u8]) -> Result<()> {
        self.check()?;
        self.runtime
            .block_on(self.shared.writer.lock())
            .send_blocking(&self.runtime, bytes)
    }
    fn send_frame(&self, command: u16, payload: &[u8]) -> Result<()> {
        self.send(&frame(command, self.sid, payload)?)
    }
    fn receive(&mut self) -> Result<Record> {
        let mut paused = self.job.paused.subscribe();
        loop {
            self.check()?;
            paused.borrow_and_update();
            let record = self.runtime.block_on(async {
                tokio::select! {
                    _ = self.shared.closed.cancelled() => anyhow::bail!("disconnected"),
                    _ = self.job.cancel.cancelled() => anyhow::bail!("cancelled"),
                    _ = paused.changed() => Ok(None),
                    result = tokio::time::timeout(Duration::from_secs(30), self.inbox.recv()) =>
                        Ok(Some(result.context("timeout")?.context("disconnected")?)),
                }
            })?;
            if let Some(record) = record {
                self.check()?;
                return Ok(record);
            }
        }
    }
    fn check_sender(&mut self) -> Result<()> {
        self.check()?;
        while let Ok((command, _)) = self.inbox.try_recv() {
            ensure!(command == 300, "remoteRejected");
        }
        Ok(())
    }
    fn progress(&mut self, stage: &str, force: bool, code: Option<&str>) -> Result<()> {
        self.job.completed.store(self.completed, Ordering::Relaxed);
        self.job.total.store(self.total, Ordering::Relaxed);
        let stage = if *self.job.paused.borrow()
            && !["completed", "failed", "cancelled"].contains(&stage)
        {
            "paused"
        } else {
            stage
        };
        if !force && self.last_progress.elapsed() < Duration::from_millis(100) {
            return Ok(());
        }
        self.last_progress = Instant::now();
        self.runtime.block_on(self.shared.output.emit(json!({"kind":"fileTransfer","requestID":self.job.request,"name":self.name,"stage":stage,"direction":self.job.direction,"completedBytes":self.completed,"totalBytes":self.total,"code":code}),Vec::new()))
    }
    fn upload(&mut self) -> Result<()> {
        let source = fs::absolute(&self.job.source)?;
        ensure!(
            !std::fs::symlink_metadata(&source)?.file_type().is_symlink(),
            "unsupportedFileType"
        );
        let source = source.canonicalize()?;
        self.progress("preparing", true, None)?;
        let items = fs::scan(&source, &|| self.check())?;
        let files = items.iter().filter(|i| i.info.is_file()).count() as u64;
        let folders = items.len() as u64 - files;
        self.total = items
            .iter()
            .filter(|i| i.info.is_file())
            .try_fold(0u64, |sum, i| {
                sum.checked_add(i.info.len())
                    .and_then(|n| n.checked_add(i.resource))
            })
            .context("tooManyFiles")?;
        ensure!(self.total <= i64::MAX as u64, "tooManyFiles");
        let allocated = items
            .iter()
            .filter(|i| i.info.is_file())
            .map(|i| fs::allocated(&i.info))
            .sum::<u64>();
        self.send(&request(2, self.sid, &self.job.destination)?)?;
        let mut summary = (u32::from(folders == 0)).to_be_bytes().to_vec();
        summary.extend([0; 4]);
        for n in [self.total, allocated, files, 0, folders] {
            summary.extend(n.to_be_bytes());
        }
        summary.extend([0; 4]);
        self.send_frame(100, &summary)?;
        for item in items {
            self.check_sender()?;
            let mut file = fs::open_source(&item.path)?;
            ensure!(
                fs::unchanged(&item.info, &file.metadata()?),
                "sourceChanged"
            );
            let mut metadata = fs::metadata(&item)?;
            let finder = fs::attribute(&file, fs::FINDER, 32, 0)?;
            if !finder.is_empty() {
                ensure!(finder.len() == 32, "invalidMetadata");
                metadata[2..34].copy_from_slice(&finder);
            }
            self.send_frame(101, &metadata)?;
            if item.info.is_file() {
                for (size, resource) in [(item.info.len(), false), (item.resource, true)] {
                    let mut position = 0;
                    let mut data = vec![0; 16384];
                    let mut payload = Vec::with_capacity(16388);
                    let mut batch = Vec::with_capacity(128 * 1024 + 16402);
                    let mut batch_bytes = 0;
                    while position < size {
                        self.check_sender()?;
                        let length = (size - position).min(16384) as usize;
                        data.resize(length, 0);
                        if resource {
                            data = fs::attribute(&file, fs::RESOURCE, length, position as u32)?;
                        } else {
                            file.read_exact(&mut data).context("sourceChanged")?;
                        }
                        ensure!(!data.is_empty() && data.len() <= length, "sourceChanged");
                        payload.clear();
                        payload.extend((data.len() as u32).to_be_bytes());
                        payload.extend(&data);
                        batch.extend(frame(102, self.sid, &payload)?);
                        position += data.len() as u64;
                        batch_bytes += data.len() as u64;
                        if batch.len() >= 128 * 1024 || position == size {
                            // The socket supplies backpressure. Release the writer
                            // between batches so keyboard and control can proceed.
                            self.send(&batch)?;
                            self.completed += batch_bytes;
                            batch.clear();
                            batch_bytes = 0;
                            self.progress("transferring", false, None)?;
                        }
                    }
                }
                ensure!(
                    fs::unchanged(&item.info, &file.metadata()?),
                    "sourceChanged"
                );
            }
        }
        self.send_frame(104, &[0; 4])?;
        self.progress("confirming", true, None)?;
        loop {
            let (command, payload) = self.receive()?;
            if command == 300 {
                continue;
            }
            ensure!(command == 200 && payload.len() >= 5, "invalidResult");
            let result = i16::from_be_bytes(payload[..2].try_into()?);
            let n = u16::from_be_bytes(payload[2..4].try_into()?) as usize;
            ensure!(result == 0, "remoteRejected");
            ensure!(
                n + 5 == payload.len() && payload.last() == Some(&0),
                "invalidResult"
            );
            self.name = fs::basename(std::str::from_utf8(&payload[4..4 + n])?)?.to_string();
            return Ok(());
        }
    }
    fn download(&mut self) -> Result<()> {
        let destination = fs::absolute(&self.job.destination)?;
        let mut stage = fs::Stage::new(&destination)?;
        let source_name = Path::new(&self.job.source)
            .file_name()
            .and_then(|n| n.to_str())
            .context("invalidName")?
            .to_string();
        let mut summary = false;
        let (mut expected_files, mut expected_folders, mut files, mut folders, mut items) =
            (0u64, 0u64, 0u64, 0u64, 0u64);
        let mut parents = BTreeMap::<u16, PathBuf>::new();
        let mut current = None::<Receiving>;
        let mut metadata = Vec::new();
        let mut inflater = flate2::Decompress::new(true);
        self.send(&request(1, self.sid, &self.job.source)?)?;
        loop {
            let (mut command, mut payload) = self.receive()?;
            if command == 103 {
                let receiving = current.as_ref().context("invalidData")?;
                ensure!(payload.len() >= 10, "invalidData");
                let method = u16::from_be_bytes(payload[..2].try_into()?);
                let size = u32::from_be_bytes(payload[2..6].try_into()?) as usize;
                let packed = u32::from_be_bytes(payload[6..10].try_into()?) as usize;
                ensure!(
                    method == 1
                        && packed == payload.len() - 10
                        && size > 0
                        && size <= MAX_FRAME
                        && size as u64 <= receiving.data + receiving.resource,
                    "invalidData"
                );
                let before = (inflater.total_in(), inflater.total_out());
                let mut decoded = vec![0; size + 1];
                let status = inflater.decompress(
                    &payload[10..],
                    &mut decoded,
                    flate2::FlushDecompress::Sync,
                )?;
                ensure!(
                    status != flate2::Status::StreamEnd
                        && inflater.total_in() - before.0 == packed as u64
                        && inflater.total_out() - before.1 == size as u64,
                    "invalidData"
                );
                decoded.truncate(size);
                payload = (size as u32).to_be_bytes().to_vec();
                payload.extend(decoded);
                command = 102;
            }
            match command {
                100 => {
                    ensure!(!summary && payload.len() == 52, "invalidMetadata");
                    self.total = u64::from_be_bytes(payload[8..16].try_into()?);
                    expected_files = u64::from_be_bytes(payload[24..32].try_into()?);
                    expected_folders = u64::from_be_bytes(payload[40..48].try_into()?);
                    ensure!(
                        self.total <= i64::MAX as u64
                            && expected_files <= 100_000
                            && expected_folders <= 100_000
                            && (1..=100_000).contains(&(expected_files + expected_folders)),
                        "tooManyFiles"
                    );
                    summary = true;
                }
                101 => {
                    finish(&mut current)?;
                    ensure!(summary && payload.len() >= 105, "invalidMetadata");
                    let n = u16::from_be_bytes(payload[100..102].try_into()?) as usize;
                    ensure!(
                        payload.len() == 105 + n && payload.last() == Some(&0),
                        "invalidMetadata"
                    );
                    let name = fs::basename(std::str::from_utf8(&payload[104..104 + n])?)?;
                    let kind = payload[0];
                    let resource = u64::from_be_bytes(payload[34..42].try_into()?);
                    let size = u64::from_be_bytes(payload[42..50].try_into()?);
                    let depth = u16::from_be_bytes(payload[92..94].try_into()?);
                    let mode = u16::from_be_bytes(payload[94..96].try_into()?) as u32 & 0o777;
                    ensure!(
                        depth <= 128 && resource <= u32::MAX as u64 && size <= self.total,
                        "invalidMetadata"
                    );
                    ensure!(kind == 1 || kind == 2, "unsupportedFileType");
                    ensure!(kind != 2 || (size == 0 && resource == 0), "invalidMetadata");
                    let target = if items == 0 {
                        ensure!(depth == 0 && name == source_name, "invalidName");
                        PathBuf::from("item")
                    } else {
                        ensure!(depth > 0, "invalidMetadata");
                        parents
                            .get(&(depth - 1))
                            .context("invalidMetadata")?
                            .join(name)
                    };
                    parents.retain(|level, _| *level < depth);
                    items += 1;
                    ensure!(
                        items <= expected_files + expected_folders,
                        "invalidMetadata"
                    );
                    let file = stage.file(&target, kind == 2)?;
                    if payload[2..34].iter().any(|b| *b != 0) {
                        fs::set_attribute(&file, fs::FINDER, &payload[2..34], 0)?;
                    }
                    if kind == 2 {
                        parents.insert(depth, target.clone());
                        folders += 1;
                    } else {
                        files += 1;
                        current = Some(Receiving {
                            file: BufWriter::with_capacity(256 * 1024, file),
                            data: size,
                            resource,
                            position: 0,
                        });
                    }
                    let modified =
                        (u64::from_be_bytes(payload[58..66].try_into()?) >> 16) as i64 - 2082844800;
                    metadata.push((target, mode, modified));
                }
                102 => {
                    let receiving = current.as_mut().context("invalidData")?;
                    ensure!(payload.len() >= 4, "invalidData");
                    let n = u32::from_be_bytes(payload[..4].try_into()?) as usize;
                    ensure!(
                        n > 0
                            && n == payload.len() - 4
                            && n as u64 <= receiving.data + receiving.resource
                            && self.completed + n as u64 <= self.total,
                        "invalidData"
                    );
                    let data = &payload[4..];
                    let write = receiving.data.min(n as u64) as usize;
                    receiving.file.write_all(&data[..write])?;
                    receiving.data -= write as u64;
                    if write < n {
                        fs::set_attribute(
                            receiving.file.get_ref(),
                            fs::RESOURCE,
                            &data[write..],
                            receiving.position,
                        )?;
                        receiving.resource -= (n - write) as u64;
                        receiving.position = receiving
                            .position
                            .checked_add((n - write) as u32)
                            .context("invalidData")?;
                    }
                    self.completed += n as u64;
                    self.progress("transferring", false, None)?;
                }
                104 => {
                    finish(&mut current)?;
                    if !(payload == [0; 4]
                        && items > 0
                        && self.completed == self.total
                        && files == expected_files
                        && folders == expected_folders)
                    {
                        return Err(anyhow::anyhow!(
                            "receivedBytes={} expectedBytes={} files={}/{} folders={}/{} validEnd={}",
                            self.completed, self.total, files, expected_files,
                            folders, expected_folders, payload == [0; 4]
                        ).context("incompleteFile"));
                    }
                    break;
                }
                200 => anyhow::bail!("remoteRejected"),
                _ => anyhow::bail!("unsupportedFileType"),
            }
        }
        self.check()?;
        for (path, mode, modified) in metadata.iter().rev() {
            stage.apply(path, *mode, *modified)?;
        }
        stage.publish()?;
        let name = destination
            .file_name()
            .and_then(|n| n.to_str())
            .context("invalidName")?;
        let mut response = vec![0, 0];
        response.extend((name.len() as u16).to_be_bytes());
        response.extend(name.as_bytes());
        response.push(0);
        self.send_frame(200, &response)?;
        Ok(())
    }
}
struct Receiving {
    file: BufWriter<std::fs::File>,
    data: u64,
    resource: u64,
    position: u32,
}
fn finish(current: &mut Option<Receiving>) -> Result<()> {
    if let Some(mut file) = current.take() {
        if file.data != 0 || file.resource != 0 {
            return Err(anyhow::anyhow!(
                "remainingDataBytes={} remainingResourceBytes={}",
                file.data,
                file.resource
            )
            .context("incompleteFile"));
        }
        file.file.flush()?;
        file.file.get_ref().sync_all()?;
    }
    Ok(())
}
impl Writer {
    fn send_blocking(&mut self, runtime: &tokio::runtime::Handle, bytes: &[u8]) -> Result<()> {
        runtime.block_on(self.send(bytes))
    }
}
fn transfer(job: Arc<Job>, shared: Arc<Shared>) {
    let sid = rand::random::<u32>().max(1);
    let (tx, rx) = mpsc::channel(16);
    shared
        .active
        .lock()
        .unwrap()
        .insert(sid, (tx, job.cancel.clone()));
    let mut transfer = Transfer {
        job: job.clone(),
        shared: shared.clone(),
        sid,
        inbox: rx,
        runtime: tokio::runtime::Handle::current(),
        total: 0,
        completed: 0,
        last_progress: Instant::now(),
        name: Path::new(&job.source)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string(),
    };
    let result = transfer.check().and_then(|_| {
        if job.direction == "upload" {
            transfer.upload()
        } else {
            transfer.download()
        }
    });
    match result {
        Ok(()) => {
            let _ = transfer.progress("completed", true, None);
        }
        Err(error) => {
            // Only this internally constructed numerical detail is public.
            // Do not log paths, file contents, credentials, or arbitrary errors.
            if error.to_string() == "incompleteFile" {
                if let Some(detail) = error.chain().nth(1) {
                    let _ = transfer.runtime.block_on(shared.output.emit(
                        json!({"kind":"fileTransferDiagnostic","message":detail.to_string()}),
                        Vec::new(),
                    ));
                }
            }
            if let Ok(bytes) = frame(5, sid, &[]) {
                let _ = transfer
                    .runtime
                    .block_on(async { shared.writer.lock().await.send(&bytes).await });
            }
            let text = error.to_string();
            let code = match text.as_str() {
                "cancelled"
                | "disconnected"
                | "alreadyExists"
                | "invalidName"
                | "invalidPath"
                | "expiredDrag"
                | "invalidMetadata"
                | "invalidData"
                | "invalidResult"
                | "incompleteFile"
                | "remoteRejected"
                | "tooManyFiles"
                | "unsupportedFileType"
                | "sourceChanged"
                | "timeout" => text.as_str(),
                _ => "ioError",
            };
            let _ = transfer.progress(
                if code == "cancelled" {
                    "cancelled"
                } else {
                    "failed"
                },
                true,
                Some(code),
            );
        }
    }
    job.cancel.cancel();
    shared.active.lock().unwrap().remove(&sid);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test(flavor = "multi_thread")]
    async fn paused_download_keeps_bounded_backlog_resumes_exact_bytes_and_cancels_cleanly(
    ) -> Result<()> {
        let root =
            std::env::temp_dir().join(format!("TermPilot-pause-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root)?;
        let root = root.canonicalize()?;
        let source = root.join("source-中文.bin");
        let contents = (0..1024 * 1024)
            .map(|i| (i % 251) as u8)
            .collect::<Vec<_>>();
        std::fs::write(&source, &contents)?;
        let item = fs::scan(&source, &|| Ok(()))?.remove(0);
        let metadata = fs::metadata(&item)?;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let stream = tokio::net::TcpStream::connect(listener.local_addr()?).await?;
        let (mut peer, _) = listener.accept().await?;
        let drain =
            tokio::spawn(async move { tokio::io::copy(&mut peer, &mut tokio::io::sink()).await });
        let writer = Arc::new(Mutex::new(Writer::test_writer(stream)));
        let (events, mut event_rx) = mpsc::channel(256);
        let (audio, _) = mpsc::channel(1);
        let output = Output {
            events,
            audio,
            video: Arc::default(),
        };
        let mut files = Files::new(writer, output);
        for cancel in [false, true] {
            let id = uuid::Uuid::new_v4().to_string();
            let destination = root.join(if cancel {
                "cancelled.bin"
            } else {
                "complete.bin"
            });
            files
                .enqueue(
                    id.clone(),
                    format!("/fixture/{}", source.file_name().unwrap().to_str().unwrap()),
                    destination.to_str().unwrap().into(),
                    "download",
                )
                .await?;
            let sid = tokio::time::timeout(Duration::from_secs(3), async {
                loop {
                    if let Some(sid) = files.shared.active.lock().unwrap().keys().next().copied() {
                        break sid;
                    }
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await?;
            let mut summary = vec![0; 52];
            summary[8..16].copy_from_slice(&(contents.len() as u64).to_be_bytes());
            summary[24..32].copy_from_slice(&1u64.to_be_bytes());
            files.message(&frame(100, sid, &summary)?).await?;
            files.message(&frame(101, sid, &metadata)?).await?;
            let chunk = |data: &[u8]| {
                let mut p = (data.len() as u32).to_be_bytes().to_vec();
                p.extend(data);
                frame(102, sid, &p).unwrap()
            };
            files.message(&chunk(&contents[..16384])).await?;
            let job = files
                .shared
                .queued
                .lock()
                .unwrap()
                .get(&id)
                .unwrap()
                .clone();
            tokio::time::timeout(Duration::from_secs(3), async {
                while job.completed.load(Ordering::Relaxed) == 0 {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await?;
            files
                .command(&json!({"kind":"filePause","requestID":id}))
                .await?;
            // One inbound TCP record can fill the bounded transfer inbox. It
            // must return to the main loop so commands and media keep running.
            let burst = contents[16384..]
                .chunks(16384)
                .flat_map(chunk)
                .collect::<Vec<_>>();
            tokio::time::timeout(Duration::from_secs(1), files.message(&burst)).await??;
            assert!(files.is_backpressured());
            let paused_at = job.completed.load(Ordering::Relaxed);
            tokio::time::sleep(Duration::from_millis(100)).await;
            assert_eq!(job.completed.load(Ordering::Relaxed), paused_at);
            assert!(!destination.exists());
            files
                .command(
                    &json!({"kind":if cancel {"fileCancel"} else {"fileResume"},"requestID":id}),
                )
                .await?;
            tokio::time::timeout(Duration::from_secs(3), async {
                while files.is_backpressured() {
                    files.flush_pending().await;
                }
            })
            .await?;
            if !cancel {
                files.message(&frame(104, sid, &[0; 4])?).await?;
            }
            tokio::time::timeout(Duration::from_secs(3), async {
                while files.is_backpressured() {
                    files.flush_pending().await;
                }
            })
            .await
            .context("End-record backlog")?;
            let expected = if cancel { "cancelled" } else { "completed" };
            tokio::time::timeout(Duration::from_secs(3), async {
                loop {
                    let packet = event_rx.recv().await.unwrap();
                    if packet.header["requestID"] == id && packet.header["stage"] == expected {
                        break;
                    }
                    assert_ne!(packet.header["stage"], "failed", "{:?}", packet.header);
                }
            })
            .await?;
            if cancel {
                assert!(!destination.exists());
            } else {
                assert_eq!(std::fs::read(&destination)?, contents);
            }
            tokio::time::timeout(Duration::from_secs(3), async {
                while !files.shared.active.lock().unwrap().is_empty() {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await?;
        }
        files.close().await;
        drop(files);
        drain.abort();
        std::fs::remove_dir_all(root)?;
        Ok(())
    }
    #[test]
    fn split_file_records() {
        let packets = [
            frame(100, 1, &[0; 52]).unwrap(),
            frame(102, 1, &[0, 0, 0, 2, 1, 2]).unwrap(),
        ];
        let wire = packets.concat();
        for split in 0..=wire.len() {
            let mut buffer = Wire::default();
            let mut found = buffer.feed(&wire[..split]).unwrap();
            found.extend(buffer.feed(&wire[split..]).unwrap());
            assert_eq!(found, packets);
        }
    }
    #[test]
    fn escaped_filenames_keep_literal_percent_and_fragment_characters() {
        let paths = vec!["/tmp/中文 %20 #?.txt".to_string(), "/tmp/a%2Fb".to_string()];
        let (_, decoded) = remote_paths(&drag_archive(&paths, 7).unwrap()).unwrap();
        assert_eq!(decoded, paths);
    }
    #[test]
    fn unicode_drag_archive() {
        let paths = vec!["/tmp/中文.txt".to_string(), "/tmp/folder/".to_string()];
        let (sid, decoded) = remote_paths(&drag_archive(&paths, 5).unwrap()).unwrap();
        assert_eq!(sid, 5);
        assert_eq!(decoded, vec!["/tmp/中文.txt", "/tmp/folder"]);
    }
}
