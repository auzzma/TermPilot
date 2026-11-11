use crate::wire::Output;
use anyhow::{Context, Result, ensure};
use ironrdp_client::rdp::RdpInputSender;
use ironrdp_cliprdr::{
    backend::{ClipboardMessage as Message, CliprdrBackend, CliprdrBackendFactory},
    pdu::*,
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeSet, HashMap, VecDeque},
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering},
    },
    time::{Duration, SystemTime},
};
use tokio::sync::{Semaphore, oneshot, watch};
#[path = "clipboard_pipeline.rs"]
mod pipeline;

#[derive(Debug)]
struct RemoteReadRejected;
impl std::fmt::Display for RemoteReadRejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Remote file read failed")
    }
}
impl std::error::Error for RemoteReadRejected {}

const CHUNK: u32 = 256 * 1024;
#[derive(Debug)]
struct TransferControl {
    state: watch::Sender<u8>, // running, paused, cancelled, finished
    done: AtomicU64,
    total: AtomicU64,
    requests: AtomicUsize,
}
impl Default for TransferControl {
    fn default() -> Self {
        Self {
            state: watch::channel(0).0,
            done: AtomicU64::new(0),
            total: AtomicU64::new(0),
            requests: AtomicUsize::new(0),
        }
    }
}
impl TransferControl {
    fn set(&self, state: u8) -> bool {
        self.state.send_if_modified(|old| {
            if *old >= 2 || *old == state {
                false
            } else {
                *old = state;
                true
            }
        })
    }
    async fn ready(&self) -> Result<()> {
        let mut state = self.state.subscribe();
        loop {
            let current = *state.borrow_and_update();
            if current == 2 {
                anyhow::bail!("File transfer cancelled");
            }
            if current != 1 {
                return Ok(());
            }
            state.changed().await.context("File transfer closed")?;
        }
    }
    async fn cancelled(&self) {
        let mut state = self.state.subscribe();
        loop {
            if *state.borrow_and_update() == 2 {
                return;
            }
            if state.changed().await.is_err() {
                return;
            }
        }
    }
    fn event(&self, output: &Output, id: &str, direction: &str, stage: &str) {
        output.event(json!({"kind":"fileTransfer","id":id,"direction":direction,"stage":stage,
            "completedBytes":self.done.load(Ordering::Relaxed),"totalBytes":self.total.load(Ordering::Relaxed)}));
    }
}

#[derive(Debug, Clone)]
struct LocalFile {
    path: PathBuf,
    descriptor: FileDescriptor,
    modified: Option<SystemTime>,
}
#[derive(Debug, Default)]
struct Snapshot {
    text: String,
    files: Vec<LocalFile>,
    id: String,
    progress: Mutex<UploadProgress>,
    cancelled: AtomicBool,
    control: TransferControl,
    handles: Mutex<HashMap<usize, Arc<Mutex<File>>>>,
}
impl Snapshot {
    fn new_transfer(&self) -> Arc<Self> {
        let snapshot = Arc::new(Self {
            text: self.text.clone(),
            files: self.files.clone(),
            id: uuid::Uuid::new_v4().to_string(),
            ..Self::default()
        });
        snapshot.control.total.store(
            self.control.total.load(Ordering::Relaxed),
            Ordering::Relaxed,
        );
        if self.cancelled.load(Ordering::Acquire) {
            snapshot.cancelled.store(true, Ordering::Release);
            snapshot.control.set(2);
        }
        snapshot
    }
}
#[derive(Debug, Default)]
struct UploadProgress {
    ranges: HashMap<usize, Vec<(u64, u64)>>,
    last: Option<std::time::Instant>,
    finished: bool,
}
impl UploadProgress {
    fn record(&mut self, index: usize, start: u64, end: u64) -> u64 {
        let ranges = self.ranges.entry(index).or_default();
        ranges.push((start, end));
        ranges.sort_unstable();
        let mut merged: Vec<(u64, u64)> = Vec::new();
        for &(a, b) in ranges.iter() {
            if let Some(last) = merged.last_mut().filter(|r| a <= r.1) {
                last.1 = last.1.max(b);
            } else {
                merged.push((a, b));
            }
        }
        *ranges = merged;
        self.ranges.values().flatten().map(|(a, b)| b - a).sum()
    }
}
#[derive(Debug)]
pub struct Shared {
    sender: Mutex<Option<RdpInputSender>>,
    output: Output,
    offers: Mutex<VecDeque<Option<String>>>,
    formats: Mutex<VecDeque<(u64, ClipboardFormatId, u8)>>,
    current: Mutex<Arc<Snapshot>>,
    locks: Mutex<HashMap<u32, Arc<Snapshot>>>,
    pending: Mutex<HashMap<u32, oneshot::Sender<Result<Vec<u8>>>>>,
    downloads: Mutex<HashMap<String, Arc<TransferControl>>>,
    enabled: AtomicBool,
    active: AtomicBool,
    revision: AtomicU64,
    sequence: AtomicU32,
    root: PathBuf,
    capabilities: Mutex<ClipboardGeneralCapabilityFlags>,
    file_workers: Arc<Semaphore>,
    file_bytes: Arc<Semaphore>,
}
impl Shared {
    pub fn new(output: Output, root: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            sender: Mutex::new(None),
            output,
            offers: Mutex::default(),
            formats: Mutex::default(),
            current: Mutex::new(Arc::default()),
            locks: Mutex::default(),
            pending: Mutex::default(),
            downloads: Mutex::default(),
            enabled: AtomicBool::new(true),
            active: AtomicBool::new(true),
            revision: AtomicU64::new(0),
            sequence: AtomicU32::new(1),
            root,
            capabilities: Mutex::new(ClipboardGeneralCapabilityFlags::empty()),
            file_workers: Arc::new(Semaphore::new(4)),
            file_bytes: Arc::new(Semaphore::new(128)), // 8 MiB, held until transport drains
        })
    }
    pub fn set_sender(&self, sender: RdpInputSender) {
        *self.sender.lock().unwrap() = Some(sender);
    }
    fn allowed(&self) -> bool {
        self.enabled.load(Ordering::Acquire) && self.active.load(Ordering::Acquire)
    }
    fn send_raw(&self, message: Message) {
        if let Some(s) = self.sender.lock().unwrap().as_ref() {
            let _ = s.send_clipboard(message);
        }
    }
    fn send(&self, message: Message) {
        if matches!(
            &message,
            Message::SendInitiateCopy(_) | Message::SendInitiateFileCopy(_)
        ) {
            self.offers.lock().unwrap().push_back(None);
        }
        self.send_raw(message);
    }
    fn offer_message(&self, message: Message, id: String) {
        self.offers.lock().unwrap().push_back(Some(id));
        self.send_raw(message);
    }
    fn request_format(&self, revision: u64, format: ClipboardFormatId, attempt: u8) {
        if !self.allowed() || self.revision.load(Ordering::Acquire) != revision {
            return;
        }
        self.formats
            .lock()
            .unwrap()
            .push_back((revision, format, attempt));
        self.send(Message::SendInitiatePaste(format));
    }
    pub fn scope(&self, enabled: Option<bool>, active: Option<bool>) {
        if let Some(v) = enabled {
            self.enabled.store(v, Ordering::Release);
        }
        if let Some(v) = active {
            self.active.store(v, Ordering::Release);
        }
        if !self.allowed() {
            self.abort();
        }
    }
    pub fn abort(&self) {
        self.cancel();
        self.current
            .lock()
            .unwrap()
            .cancelled
            .store(true, Ordering::Release);
        self.current.lock().unwrap().control.set(2);
        for snapshot in self.locks.lock().unwrap().values() {
            snapshot.cancelled.store(true, Ordering::Release);
            snapshot.control.set(2);
        }
        self.send(Message::SendInitiateCopy(vec![]));
    }
    pub fn cancel(&self) {
        self.revision.fetch_add(1, Ordering::AcqRel);
        self.pending.lock().unwrap().clear();
        for control in self.downloads.lock().unwrap().values() {
            control.set(2);
        }
    }
    pub fn control_transfer(&self, id: &str, action: &str) {
        let state = match action {
            "pauseTransfer" => 1,
            "resumeTransfer" => 0,
            _ => 2,
        };
        let stage = match state {
            1 => "paused",
            0 => "transferring",
            _ => "cancelled",
        };
        if let Some(control) = self.downloads.lock().unwrap().get(id) {
            if control.set(state) {
                control.event(&self.output, id, "download", stage);
            }
        }
        let mut snapshots = vec![self.current.lock().unwrap().clone()];
        snapshots.extend(self.locks.lock().unwrap().values().cloned());
        for snapshot in snapshots {
            if snapshot.id == id && snapshot.control.set(state) {
                if state == 2 {
                    snapshot.cancelled.store(true, Ordering::Release);
                }
                snapshot.control.event(&self.output, id, "upload", stage);
            }
        }
    }
    pub async fn offer(self: &Arc<Self>, value: &Value) -> Result<()> {
        if !self.allowed() {
            return Ok(());
        }
        self.cancel();
        let revision = self.revision.load(Ordering::Acquire);
        let offer_id = value["offerId"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let paths = value["paths"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(PathBuf::from)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let text = value["text"].as_str().unwrap_or("").to_owned();
        ensure!(
            text.len() <= 8 * 1024 * 1024,
            "Clipboard text exceeds 8 MiB"
        );
        let snapshot = tokio::task::spawn_blocking(move || -> Result<_> {
            let mut files = Vec::new();
            let mut roots = BTreeSet::new();
            for path in paths {
                ensure!(path.is_absolute(), "Clipboard file path must be absolute");
                let name = path
                    .file_name()
                    .and_then(|s| s.to_str())
                    .context("Invalid clipboard filename")?;
                ensure!(
                    roots.insert(name.to_lowercase()),
                    "Two copied items have the same name"
                );
                enumerate(&path, Path::new(name), &mut files)?;
            }
            Ok(Arc::new(Snapshot {
                text,
                files,
                id: uuid::Uuid::new_v4().to_string(),
                ..Snapshot::default()
            }))
        })
        .await??;
        if !self.allowed() || revision != self.revision.load(Ordering::Acquire) {
            return Ok(());
        }
        if snapshot
            .files
            .iter()
            .any(|file| file.descriptor.file_size.unwrap_or(0) > u32::MAX as u64)
        {
            ensure!(
                self.capabilities
                    .lock()
                    .unwrap()
                    .contains(ClipboardGeneralCapabilityFlags::HUGE_FILE_SUPPORT_ENABLED),
                "Server did not negotiate large-file clipboard support"
            );
        }
        snapshot.control.total.store(
            snapshot
                .files
                .iter()
                .map(|f| f.descriptor.file_size.unwrap_or(0))
                .sum(),
            Ordering::Relaxed,
        );
        *self.current.lock().unwrap() = snapshot.clone();
        if snapshot.files.is_empty() {
            self.offer_message(
                Message::SendInitiateCopy(vec![ClipboardFormat::new(
                    ClipboardFormatId::CF_UNICODETEXT,
                )]),
                offer_id,
            );
        } else {
            ensure!(
                self.capabilities
                    .lock()
                    .unwrap()
                    .contains(ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED),
                "Server does not support file clipboard redirection"
            );
            self.offer_message(
                Message::SendInitiateFileCopy(
                    snapshot
                        .files
                        .iter()
                        .map(|f| f.descriptor.clone())
                        .collect(),
                ),
                offer_id,
            );
        }
        Ok(())
    }
    fn read_upload(
        &self,
        snapshot: Option<Arc<Snapshot>>,
        r: FileContentsRequest,
    ) -> Result<FileContentsResponse<'static>> {
        ensure!(self.allowed(), "Clipboard sync inactive");
        let snapshot = snapshot.context("Expired clipboard snapshot")?;
        ensure!(
            !snapshot.cancelled.load(Ordering::Acquire),
            "File transfer cancelled"
        );
        let index = usize::try_from(r.index)?;
        let item = snapshot.files.get(index).context("Invalid file index")?;
        let source = {
            let mut handles = snapshot.handles.lock().unwrap();
            if let Some(file) = handles.get(&index) {
                file.clone()
            } else {
                let file = Arc::new(Mutex::new(File::open(&item.path)?));
                if handles.len() >= 32 {
                    if let Some(old) = handles.keys().next().copied() {
                        handles.remove(&old);
                    }
                }
                handles.insert(index, file.clone());
                file
            }
        };
        let mut source = source.lock().unwrap();
        let metadata = source.metadata()?;
        ensure!(
            metadata.len() == item.descriptor.file_size.unwrap_or(0)
                && metadata.modified().ok() == item.modified,
            "Source file changed during transfer"
        );
        if r.flags == FileContentsFlags::SIZE {
            return Ok(FileContentsResponse::new_size_response(
                r.stream_id,
                metadata.len(),
            ));
        }
        ensure!(
            r.flags == FileContentsFlags::RANGE && r.requested_size <= 8 * 1024 * 1024,
            "Invalid file contents request"
        );
        ensure!(r.position <= metadata.len(), "Invalid file offset");
        let mut data = vec![0; (metadata.len() - r.position).min(r.requested_size as u64) as usize];
        // Serialize each handle's cursor on both operating systems. Other files
        // and the network run concurrently, without repeated opens.
        source.seek(SeekFrom::Start(r.position))?;
        source.read_exact(&mut data)?;
        drop(source);
        ensure!(
            !snapshot.cancelled.load(Ordering::Acquire),
            "File transfer cancelled"
        );
        let mut progress = snapshot.progress.lock().unwrap();
        let done = progress.record(index, r.position, r.position + data.len() as u64);
        snapshot.control.done.store(done, Ordering::Relaxed);
        let total = snapshot.control.total.load(Ordering::Relaxed);
        if !progress.finished
            && (done == total
                || progress
                    .last
                    .is_none_or(|t| t.elapsed() >= Duration::from_millis(200)))
        {
            progress.last = Some(std::time::Instant::now());
            progress.finished = done == total;
            if progress.finished {
                snapshot.control.set(3);
            }
            ensure!(
                !snapshot.cancelled.load(Ordering::Acquire),
                "File transfer cancelled"
            );
            self.output.event(json!({"kind":"fileTransfer","id":snapshot.id,"name":"Clipboard files","direction":"upload","stage":if done==total {"completed"} else if *snapshot.control.state.borrow()==1 {"paused"} else {"transferring"},"completedBytes":done,"totalBytes":total}));
        }
        Ok(FileContentsResponse::new_data_response(r.stream_id, data))
    }
    async fn request(
        &self,
        index: usize,
        position: u64,
        length: u32,
        lock: Option<u32>,
    ) -> Result<Vec<u8>> {
        let id = self.sequence.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        struct PendingGuard<'a>(
            &'a Mutex<HashMap<u32, oneshot::Sender<Result<Vec<u8>>>>>,
            u32,
        );
        impl Drop for PendingGuard<'_> {
            fn drop(&mut self) {
                self.0.lock().unwrap().remove(&self.1);
            }
        }
        let _guard = PendingGuard(&self.pending, id);
        self.pending.lock().unwrap().insert(id, tx);
        self.send(Message::SendFileContentsRequest(FileContentsRequest {
            stream_id: id,
            index: index as i32,
            flags: FileContentsFlags::RANGE,
            position,
            requested_size: length,
            data_id: lock,
        }));
        let result = tokio::time::timeout(Duration::from_secs(45), rx).await;
        self.pending.lock().unwrap().remove(&id);
        result
            .context("File clipboard request timed out")?
            .context("File transfer cancelled")?
    }
    async fn download(
        self: Arc<Self>,
        files: Vec<FileDescriptor>,
        lock: Option<u32>,
        revision: u64,
    ) {
        let id = uuid::Uuid::new_v4().to_string();
        let directory = self.root.join(&id);
        let control = Arc::new(TransferControl::default());
        self.downloads
            .lock()
            .unwrap()
            .insert(id.clone(), control.clone());
        self.output.event(json!({"kind":"fileTransfer","id":id,"direction":"download","stage":"queued","name":"Clipboard files","completedBytes":0}));
        let result:Result<Vec<PathBuf>>=async {
            ensure!(files.len()<=10000,"Too many clipboard files");
            tokio::fs::create_dir_all(&directory).await?;
            let mut top=BTreeSet::new();let mut seen=BTreeSet::new();let mut done=0u64;
            let total=files.iter().try_fold(0u64,|n,f|n.checked_add(f.file_size.unwrap_or(0))).context("File size overflow")?;
            control.total.store(total, Ordering::Relaxed);
            let mut last=std::time::Instant::now()-Duration::from_secs(1);
            for (index,descriptor) in files.iter().enumerate(){
                control.ready().await?;
                ensure!(self.allowed()&&self.revision.load(Ordering::Acquire)==revision,"File transfer cancelled or clipboard changed");
                let relative=relative_path(descriptor)?;
                ensure!(seen.insert(relative.to_string_lossy().to_lowercase()),"Duplicate clipboard filename");
                top.insert(relative.components().next().unwrap().as_os_str().to_os_string());
                let path=directory.join(&relative);
                if descriptor.attributes.unwrap_or_else(ClipboardFileAttributes::empty).contains(ClipboardFileAttributes::DIRECTORY){tokio::fs::create_dir_all(&path).await?;continue;}
                if let Some(parent)=path.parent(){tokio::fs::create_dir_all(parent).await?;}
                let size=descriptor.file_size.context("Remote file has no declared size")?;
                if size>u32::MAX as u64 {ensure!(self.capabilities.lock().unwrap().contains(ClipboardGeneralCapabilityFlags::HUGE_FILE_SUPPORT_ENABLED),"Server did not negotiate large-file clipboard support");}
                let mut target=tokio::fs::OpenOptions::new().write(true).create_new(true).open(&path).await?;
                let shared = self.clone();
                let base = done;
                pipeline::copy_ranges(&mut target, size, control.clone(), move |offset, length| {
                    let shared = shared.clone();
                    async move {
                        ensure!(shared.allowed() && shared.revision.load(Ordering::Acquire)==revision, "File transfer cancelled or clipboard changed");
                        shared.request(index, offset, length, lock).await
                    }
                }, |position| {
                    done = base + position;
                    control.done.store(done, Ordering::Relaxed);
                    if last.elapsed()>=Duration::from_millis(200) {
                        self.output.event(json!({"kind":"fileTransfer","id":id,"name":descriptor.name,"direction":"download","stage":if *control.state.borrow()==1 {"paused"}else{"transferring"},"completedBytes":done,"totalBytes":total}));
                        last=std::time::Instant::now();
                    }
                }).await?;
                target.sync_all().await?;
            }
            control.ready().await?;
            ensure!(self.allowed()&&self.revision.load(Ordering::Acquire)==revision,"Clipboard changed before transfer completed");
            Ok(top.into_iter().map(|name|directory.join(name)).collect())
        }.await;
        match result {
            Ok(paths) => {
                self.output
                    .event(json!({"kind":"clipboardFiles","revision":revision,"paths":paths}));
                self.output.event(json!({"kind":"fileTransfer","id":id,"direction":"download","stage":"completed","name":"Clipboard files","completedBytes":control.done.load(Ordering::Relaxed),"totalBytes":control.total.load(Ordering::Relaxed)}));
            }
            Err(error) => {
                let _ = tokio::fs::remove_dir_all(&directory).await;
                self.output.event(json!({"kind":"fileTransfer","id":id,"direction":"download","stage":if *control.state.borrow()==2 || self.revision.load(Ordering::Acquire)!=revision {"cancelled"} else {"failed"},"name":"Clipboard files","error":error.to_string()}));
            }
        }
        control.state.send_replace(3);
        self.downloads.lock().unwrap().remove(&id);
    }
}

fn relative_path(d: &FileDescriptor) -> Result<PathBuf> {
    let combined = match &d.relative_path {
        Some(p) => format!("{p}\\{}", d.name),
        None => d.name.clone(),
    };
    let mut path = PathBuf::new();
    for component in combined.split(['\\', '/']) {
        ensure!(
            !component.is_empty()
                && component != "."
                && component != ".."
                && !component.contains([':', '\0', '<', '>', '"', '|', '?', '*'])
                && !component.chars().any(char::is_control)
                && !component.ends_with(['.', ' ']),
            "Unsafe clipboard filename"
        );
        ensure!(
            !ironrdp_cliprdr::is_windows_device_name(component),
            "Reserved clipboard filename"
        );
        path.push(component);
    }
    ensure!(
        combined.encode_utf16().count() < 260,
        "Clipboard filename exceeds RDP limit"
    );
    Ok(path)
}
fn enumerate(path: &Path, relative: &Path, files: &mut Vec<LocalFile>) -> Result<()> {
    ensure!(files.len() < 10000, "Too many clipboard files");
    let metadata = std::fs::symlink_metadata(path)?;
    ensure!(
        !metadata.file_type().is_symlink(),
        "Copying symbolic links is not supported"
    );
    ensure!(
        metadata.is_dir() || metadata.is_file(),
        "Clipboard item is not a regular file or directory"
    );
    let name = relative
        .file_name()
        .and_then(|s| s.to_str())
        .context("Invalid filename")?;
    let mut d = FileDescriptor::new(name)
        .with_file_size(if metadata.is_file() {
            metadata.len()
        } else {
            0
        })
        .with_attributes(if metadata.is_dir() {
            ClipboardFileAttributes::DIRECTORY
        } else {
            ClipboardFileAttributes::NORMAL
        });
    if let Some(parent) = relative.parent().filter(|p| !p.as_os_str().is_empty()) {
        d = d.with_relative_path(parent.to_string_lossy().replace('/', "\\"));
    }
    relative_path(&d)?;
    if let Ok(time) = metadata.modified().and_then(|t| {
        t.duration_since(SystemTime::UNIX_EPOCH)
            .map_err(std::io::Error::other)
    }) {
        d = d.with_last_write_time(
            time.as_secs()
                .saturating_mul(10_000_000)
                .saturating_add(116444736000000000),
        );
    }
    files.push(LocalFile {
        path: path.to_owned(),
        descriptor: d,
        modified: metadata.modified().ok(),
    });
    if metadata.is_dir() {
        let mut entries = std::fs::read_dir(path)?.collect::<std::io::Result<Vec<_>>>()?;
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            enumerate(&entry.path(), &relative.join(entry.file_name()), files)?;
        }
    }
    Ok(())
}
pub struct Factory(pub Arc<Shared>);
impl CliprdrBackendFactory for Factory {
    fn build_cliprdr_backend(&self) -> Box<dyn CliprdrBackend> {
        self.0.cancel();
        self.0.offers.lock().unwrap().clear();
        self.0.formats.lock().unwrap().clear();
        self.0.locks.lock().unwrap().clear();
        Box::new(Backend {
            shared: self.0.clone(),
        })
    }
}
#[derive(Debug)]
struct Backend {
    shared: Arc<Shared>,
}
ironrdp_core::impl_as_any!(Backend);
impl CliprdrBackend for Backend {
    fn temporary_directory(&self) -> &str {
        ""
    }
    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES
            | ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED
            | ClipboardGeneralCapabilityFlags::FILECLIP_NO_FILE_PATHS
            | ClipboardGeneralCapabilityFlags::CAN_LOCK_CLIPDATA
            | ClipboardGeneralCapabilityFlags::HUGE_FILE_SUPPORT_ENABLED
    }
    fn on_ready(&mut self) {
        self.shared.output.event(json!({"kind":"clipboardReady","files":self.shared.capabilities.lock().unwrap().contains(ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED)}));
    }
    fn on_format_list_response(&mut self, ok: bool) {
        if let Some(Some(id)) = self.shared.offers.lock().unwrap().pop_front() {
            self.shared
                .output
                .event(json!({"kind":"clipboardOfferAccepted","offerId":id,"accepted":ok}));
        }
    }
    fn on_request_format_list(&mut self) {
        self.shared.send(Message::SendInitiateCopy(vec![]));
    }
    fn on_process_negotiated_capabilities(&mut self, c: ClipboardGeneralCapabilityFlags) {
        *self.shared.capabilities.lock().unwrap() = c;
    }
    fn on_remote_copy(&mut self, formats: &[ClipboardFormat]) {
        if std::env::var_os("TERMPILOT_RDP_DIAGNOSTICS").is_some() {
            self.shared.output.event(json!({"kind":"clipboardFormats","formats":formats.iter().map(|f|format!("{:?}",f)).collect::<Vec<_>>()}));
        }
        if !self.shared.allowed() {
            return;
        }
        self.shared.cancel();
        if let Some(f) = formats.iter().find(|f| {
            f.name
                .as_ref()
                .is_some_and(|n| n.value() == "FileGroupDescriptorW")
        }) {
            self.shared
                .output
                .event(json!({"kind":"clipboardPreparing","files":true}));
            self.shared
                .request_format(self.shared.revision.load(Ordering::Acquire), f.id, 0);
        } else if formats
            .iter()
            .any(|f| f.id == ClipboardFormatId::CF_UNICODETEXT)
        {
            self.shared
                .output
                .event(json!({"kind":"clipboardPreparing","files":false}));
            self.shared.request_format(
                self.shared.revision.load(Ordering::Acquire),
                ClipboardFormatId::CF_UNICODETEXT,
                0,
            );
        }
    }
    fn on_format_data_request(&mut self, r: FormatDataRequest) {
        let snapshot = self.shared.current.lock().unwrap().clone();
        let result = if self.shared.allowed() && r.format == ClipboardFormatId::CF_UNICODETEXT {
            FormatDataResponse::new_unicode_string(&snapshot.text)
        } else {
            FormatDataResponse::new_error()
        };
        use ironrdp_core::IntoOwned;
        self.shared
            .send(Message::SendFormatData(result.into_owned()));
    }
    fn on_format_data_response(&mut self, r: FormatDataResponse<'_>) {
        if std::env::var_os("TERMPILOT_RDP_DIAGNOSTICS").is_some() {
            self.shared
                .output
                .event(json!({"kind":"clipboardResponse","error":r.is_error()}));
        }
        let Some((revision, format, attempt)) = self.shared.formats.lock().unwrap().pop_front()
        else {
            return;
        };
        if !self.shared.allowed() || self.shared.revision.load(Ordering::Acquire) != revision {
            return;
        }
        if r.is_error() {
            // Explorer may advertise a directory before its delayed file descriptor is ready.
            // Retry only this clipboard generation; never publish an older copy's response.
            if attempt < 3 {
                let shared = self.shared.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(300 * (1u64 << attempt))).await;
                    shared.request_format(revision, format, attempt + 1);
                });
            } else {
                self.shared.output.event(json!({"kind":"clipboardError","message":"远端未能提供剪贴板内容，请重新复制文件后重试"}));
            }
        } else if format == ClipboardFormatId::CF_UNICODETEXT {
            match r.to_unicode_string() {
                Ok(text) => self
                    .shared
                    .output
                    .event(json!({"kind":"clipboard","hasText":true,"text":text})),
                Err(_) => self
                    .shared
                    .output
                    .event(json!({"kind":"clipboardError","message":"远端剪贴板文本格式无效"})),
            }
        }
    }
    fn on_lock(&mut self, id: LockDataId) {
        let mut locks = self.shared.locks.lock().unwrap();
        if locks.len() < 16 {
            // Each Explorer copy owns its progress and controls, even when it
            // reuses the same clipboard contents in a second destination.
            locks
                .entry(id.0)
                .or_insert_with(|| self.shared.current.lock().unwrap().new_transfer());
        }
    }
    fn on_unlock(&mut self, id: LockDataId) {
        if let Some(snapshot) = self.shared.locks.lock().unwrap().remove(&id.0) {
            if snapshot.control.set(2) {
                snapshot.cancelled.store(true, Ordering::Release);
                if snapshot.control.done.load(Ordering::Relaxed) > 0
                    || snapshot.control.requests.load(Ordering::Relaxed) > 0
                {
                    snapshot.control.event(
                        &self.shared.output,
                        &snapshot.id,
                        "upload",
                        "cancelled",
                    );
                }
            }
        }
    }
    fn on_file_contents_request(&mut self, r: FileContentsRequest) {
        let snapshot = match r.data_id {
            Some(id) => self.shared.locks.lock().unwrap().get(&id).cloned(),
            None => {
                let mut current = self.shared.current.lock().unwrap();
                if *current.control.state.borrow() == 3 {
                    *current = current.new_transfer();
                }
                Some(current.clone())
            }
        };
        let shared = self.shared.clone();
        if let Some(snapshot) = &snapshot {
            if snapshot
                .control
                .requests
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                    (n < 64).then_some(n + 1)
                })
                .is_err()
            {
                shared.send(Message::SendFileContentsResponse(
                    FileContentsResponse::new_error(r.stream_id),
                ));
                return;
            }
        }
        tokio::spawn(async move {
            let bytes = r.requested_size.min(8 * 1024 * 1024).max(1).div_ceil(65536);
            let _memory = shared.file_bytes.clone().acquire_many_owned(bytes).await;
            let result = async {
                ensure!(
                    r.requested_size <= 8 * 1024 * 1024,
                    "Invalid file contents request"
                );
                if let Some(snapshot) = &snapshot {
                    snapshot.control.ready().await?;
                }
                let worker = shared.file_workers.clone().acquire_owned().await?;
                let snapshot = snapshot.clone();
                let shared = shared.clone();
                let request = r.clone();
                tokio::task::spawn_blocking(move || {
                    let _worker = worker;
                    shared.read_upload(snapshot, request)
                })
                .await?
            }
            .await;
            if let (Err(error), Some(snapshot)) = (&result, &snapshot) {
                shared.output.event(json!({"kind":"fileTransfer","id":snapshot.id,"name":"Clipboard files","direction":"upload","stage":if snapshot.cancelled.load(Ordering::Acquire){"cancelled"}else{"failed"},"error":error.to_string()}));
            }
            let sender = shared.sender.lock().unwrap().clone();
            if let Some(sender) = sender {
                if sender
                    .send_clipboard(Message::SendFileContentsResponse(
                        result.unwrap_or_else(|_| FileContentsResponse::new_error(r.stream_id)),
                    ))
                    .is_ok()
                {
                    let _ = sender.flush_clipboard().await;
                }
            }
            if let Some(snapshot) = &snapshot {
                snapshot.control.requests.fetch_sub(1, Ordering::AcqRel);
            }
        });
    }

    fn on_file_contents_response(&mut self, r: FileContentsResponse<'_>) {
        if let Some(tx) = self.shared.pending.lock().unwrap().remove(&r.stream_id()) {
            let result = if r.is_error() {
                Err(anyhow::Error::new(RemoteReadRejected))
            } else if r.data().len() > CHUNK as usize {
                Err(anyhow::anyhow!("Remote file chunk too large"))
            } else {
                Ok(r.data().to_vec())
            };
            let _ = tx.send(result);
        }
    }
    fn on_remote_file_list(&mut self, files: &[FileDescriptor], lock: Option<u32>) {
        let Some((revision, _, _)) = self.shared.formats.lock().unwrap().pop_front() else {
            return;
        };
        if !self.shared.allowed() || self.shared.revision.load(Ordering::Acquire) != revision {
            return;
        }
        let shared = self.shared.clone();
        let files = files.to_vec();
        tokio::spawn(async move {
            shared.download(files, lock, revision).await;
        });
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn pause_resume_and_cancel_are_scoped_and_do_not_block_other_transfers() {
        let (output, task) = Output::start_with_writer(tokio::io::sink());
        let shared = Shared::new(output, PathBuf::new());
        let download = Arc::new(TransferControl::default());
        let unrelated = Arc::new(TransferControl::default());
        shared
            .downloads
            .lock()
            .unwrap()
            .insert("download".into(), download.clone());
        shared
            .downloads
            .lock()
            .unwrap()
            .insert("other".into(), unrelated.clone());
        let upload = Arc::new(Snapshot {
            id: "upload".into(),
            ..Snapshot::default()
        });
        *shared.current.lock().unwrap() = upload.clone();
        for (id, control) in [("download", &*download), ("upload", &upload.control)] {
            shared.control_transfer(id, "pauseTransfer");
            assert!(
                tokio::time::timeout(Duration::from_millis(20), control.ready())
                    .await
                    .is_err()
            );
            assert!(
                tokio::time::timeout(Duration::from_millis(20), unrelated.ready())
                    .await
                    .unwrap()
                    .is_ok()
            );
            shared.control_transfer(id, "resumeTransfer");
            control.ready().await.unwrap();
            shared.control_transfer(id, "pauseTransfer");
            shared.control_transfer(id, "cancelTransfer");
            assert!(control.ready().await.is_err());
            shared.control_transfer(id, "resumeTransfer");
            assert!(
                control.ready().await.is_err(),
                "Cancelled work must never restart"
            );
        }
        assert!(unrelated.ready().await.is_ok());
        drop(shared);
        task.await.unwrap().unwrap();
    }
    #[tokio::test]
    async fn upload_reuses_handle_and_rejects_changed_or_cancelled_source() {
        let root = std::env::temp_dir().join(format!("termpilot-upload-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("中文.bin");
        let bytes = (0..65536).map(|n| (n % 251) as u8).collect::<Vec<_>>();
        std::fs::write(&path, &bytes).unwrap();
        let mut files = Vec::new();
        enumerate(&path, Path::new("中文.bin"), &mut files).unwrap();
        let snapshot = Arc::new(Snapshot {
            files,
            id: "upload".into(),
            ..Snapshot::default()
        });
        snapshot
            .control
            .total
            .store(bytes.len() as u64, Ordering::Relaxed);
        let (output, task) = Output::start_with_writer(tokio::io::sink());
        let shared = Shared::new(output, root.clone());
        for position in [32768, 0, 49152, 16384] {
            let response = shared
                .read_upload(
                    Some(snapshot.clone()),
                    FileContentsRequest {
                        stream_id: 1,
                        index: 0,
                        flags: FileContentsFlags::RANGE,
                        position,
                        requested_size: 16384,
                        data_id: None,
                    },
                )
                .unwrap();
            assert_eq!(
                response.data(),
                &bytes[position as usize..position as usize + 16384]
            );
        }
        assert_eq!(snapshot.handles.lock().unwrap().len(), 1);
        std::fs::write(&path, b"changed").unwrap();
        assert!(
            shared
                .read_upload(
                    Some(snapshot.clone()),
                    FileContentsRequest {
                        stream_id: 2,
                        index: 0,
                        flags: FileContentsFlags::RANGE,
                        position: 0,
                        requested_size: 1,
                        data_id: None
                    }
                )
                .unwrap_err()
                .to_string()
                .contains("changed")
        );
        snapshot.cancelled.store(true, Ordering::Release);
        assert!(
            shared
                .read_upload(
                    Some(snapshot.clone()),
                    FileContentsRequest {
                        stream_id: 3,
                        index: 0,
                        flags: FileContentsFlags::RANGE,
                        position: 0,
                        requested_size: 1,
                        data_id: None
                    }
                )
                .unwrap_err()
                .to_string()
                .contains("cancelled")
        );
        drop(snapshot);
        drop(shared);
        task.await.unwrap().unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn progress_counts_unique_ranges_including_out_of_order_requests() {
        let mut p = UploadProgress::default();
        assert_eq!(p.record(0, 5, 10), 5);
        assert_eq!(p.record(0, 0, 5), 10);
        assert_eq!(p.record(0, 0, 10), 10);
        assert_eq!(p.record(1, 0, 20), 30);
        assert_eq!(p.record(0, 15, 20), 35);
        assert_eq!(p.record(0, 9, 16), 40);
    }
    #[test]
    fn rejects_escape_and_reserved_paths() {
        for name in [
            "../escape",
            "/absolute",
            "a\\..\\b",
            "C:\\x",
            "CON",
            "a:stream",
            "x.",
        ] {
            assert!(relative_path(&FileDescriptor::new(name)).is_err(), "{name}");
        }
        assert_eq!(
            relative_path(&FileDescriptor::new("文件.txt").with_relative_path("目录\\nested"))
                .unwrap(),
            Path::new("目录/nested/文件.txt")
        );
    }
}
