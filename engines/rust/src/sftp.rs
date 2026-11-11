//! SFTP v3 with byte-preserving paths/handles, bounded multiplexing and explicit
//! filename encoding. The generic UTF-8-only client cannot retain GB18030 names.
use crate::transport::Stream;
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU32, AtomicU8, AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, WriteHalf},
    sync::{oneshot, Mutex, Semaphore},
};
use tokio_util::sync::CancellationToken;

const MAX_PACKET: usize = 4 * 1024 * 1024;
pub fn string(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend((bytes.len() as u32).to_be_bytes());
    out.extend(bytes);
}
pub struct Reader<'a>(pub &'a [u8]);
impl<'a> Reader<'a> {
    pub fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        ensure!(self.0.len() >= n, "Truncated SFTP response");
        let (a, b) = self.0.split_at(n);
        self.0 = b;
        Ok(a)
    }
    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into()?))
    }
    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.take(8)?.try_into()?))
    }
    pub fn string(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        ensure!(n <= MAX_PACKET, "SFTP field limit");
        self.take(n)
    }
}
#[derive(Debug)]
pub struct Status(pub u32, pub String);
impl std::fmt::Display for Status {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SFTP {}: {}", self.0, self.1)
    }
}
impl std::error::Error for Status {}
pub fn missing(error: &anyhow::Error) -> bool {
    error.downcast_ref::<Status>().is_some_and(|s| s.0 == 2)
}
fn eof(error: &anyhow::Error) -> bool {
    error.downcast_ref::<Status>().is_some_and(|s| s.0 == 1)
}
#[derive(Clone, Default, Debug)]
pub struct Attributes {
    pub size: Option<u64>,
    pub permissions: Option<u32>,
    pub mtime: Option<u32>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
}
impl Attributes {
    fn parse(r: &mut Reader<'_>) -> Result<Self> {
        let flags = r.u32()?;
        ensure!(flags & !0x8000000f == 0, "Unsupported SFTP attributes");
        let mut a = Self::default();
        if flags & 1 != 0 {
            a.size = Some(r.u64()?);
        }
        if flags & 2 != 0 {
            a.uid = Some(r.u32()?);
            a.gid = Some(r.u32()?);
        }
        if flags & 4 != 0 {
            a.permissions = Some(r.u32()?);
        }
        if flags & 8 != 0 {
            r.u32()?;
            a.mtime = Some(r.u32()?);
        }
        if flags & 0x80000000 != 0 {
            let count = r.u32()?;
            ensure!(count <= 1024, "SFTP extended attribute count");
            for _ in 0..count {
                r.string()?;
                r.string()?;
            }
        }
        Ok(a)
    }
    fn encode(&self) -> Vec<u8> {
        let mut flags = 0;
        let mut bytes = Vec::new();
        if let Some(size) = self.size {
            flags |= 1;
            bytes.extend(size.to_be_bytes());
        }
        if let Some(mode) = self.permissions {
            flags |= 4;
            bytes.extend(mode.to_be_bytes());
        }
        if let Some(time) = self.mtime {
            flags |= 8;
            bytes.extend(time.to_be_bytes());
            bytes.extend(time.to_be_bytes());
        }
        let mut out = (flags as u32).to_be_bytes().to_vec();
        out.extend(bytes);
        out
    }
    pub fn kind(&self) -> &'static str {
        match self.permissions.unwrap_or(0) & 0o170000 {
            0o040000 => "directory",
            0o100000 => "file",
            0o120000 => "symbolicLink",
            _ => "other",
        }
    }
    pub fn entry(&self, name: &str) -> Value {
        json!({"name":name,"kind":self.kind(),"size":self.size,"permissions":self.permissions,"modifiedAt":self.mtime.and_then(|t|chrono::DateTime::from_timestamp(t as i64,0)).map(|t|t.to_rfc3339()),"linkTarget":null})
    }
}
type Pending = Arc<std::sync::Mutex<HashMap<u32, oneshot::Sender<Vec<u8>>>>>;
struct PendingRequest {
    id: u32,
    map: Pending,
}
impl Drop for PendingRequest {
    fn drop(&mut self) {
        self.map.lock().unwrap().remove(&self.id);
    }
}
pub struct Sftp {
    writer: Mutex<WriteHalf<Stream>>,
    pending: Arc<std::sync::Mutex<HashMap<u32, oneshot::Sender<Vec<u8>>>>>,
    sequence: AtomicU32,
    permits: Semaphore,
    cancel: CancellationToken,
    reader: tokio::task::JoinHandle<()>,
    encoding: AtomicU8,
    auto_encoding: bool,
    pub extensions: HashMap<String, Vec<u8>>,
    pub max_read: AtomicUsize,
    pub max_write: AtomicUsize,
}
impl Drop for Sftp {
    fn drop(&mut self) {
        self.cancel.cancel();
        self.reader.abort();
    }
}
async fn packet<R: AsyncRead + Unpin>(read: &mut R) -> Result<Vec<u8>> {
    let size = read.read_u32().await? as usize;
    ensure!((1..=MAX_PACKET).contains(&size), "SFTP packet limit");
    let mut data = vec![0; size];
    read.read_exact(&mut data).await?;
    Ok(data)
}
async fn send<W: AsyncWrite + Unpin>(write: &mut W, data: &[u8]) -> Result<()> {
    ensure!(data.len() <= MAX_PACKET, "SFTP request limit");
    // ChannelStream sends each write as an SSH channel packet. Keeping the
    // length with its payload avoids a separate encrypted packet for 4 bytes.
    let mut packet = Vec::with_capacity(4 + data.len());
    packet.extend((data.len() as u32).to_be_bytes());
    packet.extend(data);
    write.write_all(&packet).await?;
    write.flush().await?;
    Ok(())
}
impl Sftp {
    pub async fn new(mut stream: Stream, encoding: &str) -> Result<Arc<Self>> {
        send(&mut stream, &[1, 0, 0, 0, 3]).await?;
        let initial = tokio::time::timeout(Duration::from_secs(20), packet(&mut stream)).await??;
        let mut fields = Reader(&initial);
        ensure!(
            fields.take(1)? == [2] && fields.u32()? == 3,
            "SFTP version 3 required"
        );
        let mut extensions = HashMap::new();
        while !fields.0.is_empty() {
            let key = String::from_utf8(fields.string()?.to_vec())?;
            let value = fields.string()?.to_vec();
            ensure!(extensions.len() < 128, "SFTP extension limit");
            extensions.insert(key, value);
        }
        let (read, write) = tokio::io::split(stream);
        let pending: Arc<std::sync::Mutex<HashMap<u32, oneshot::Sender<Vec<u8>>>>> = Arc::default();
        let cancel = CancellationToken::new();
        let (send_to, stop) = (pending.clone(), cancel.clone());
        let reader = tokio::spawn(async move {
            let mut read = read;
            loop {
                let result = tokio::select! {_=stop.cancelled()=>break,p=packet(&mut read)=>p};
                let Ok(data) = result else {
                    break;
                };
                if data.len() < 5 {
                    break;
                }
                let id = u32::from_be_bytes(data[1..5].try_into().unwrap());
                if let Some(sender) = send_to.lock().unwrap().remove(&id) {
                    let _ = sender.send(data);
                }
            }
            stop.cancel();
            send_to.lock().unwrap().clear();
        });
        let client = Arc::new(Self {
            writer: Mutex::new(write),
            pending,
            sequence: AtomicU32::new(1),
            permits: Semaphore::new(64),
            cancel,
            reader,
            encoding: AtomicU8::new(if encoding == "gb18030" { 1 } else { 0 }),
            auto_encoding: encoding == "auto" || encoding.is_empty(),
            extensions,
            max_read: AtomicUsize::new(32768),
            max_write: AtomicUsize::new(32768),
        });
        if client.extensions.contains_key("limits@openssh.com") {
            let mut request = Vec::new();
            string(&mut request, b"limits@openssh.com");
            let response = client.request(200, request).await?;
            ensure!(response[0] == 201, "Invalid SFTP limits reply");
            let mut limits = Reader(&response[5..]);
            let packet = limits.u64()?;
            let read = limits.u64()?;
            let write = limits.u64()?;
            limits.u64()?;
            ensure!(
                limits.0.is_empty() && packet >= 4096,
                "Invalid SFTP packet limit"
            );
            let cap = (packet as usize)
                .saturating_sub(1024)
                .clamp(4096, 256 * 1024 - 1024);
            client.max_read.store(
                if read == 0 {
                    256 * 1024
                } else {
                    (read as usize).clamp(1, 256 * 1024)
                },
                Ordering::Relaxed,
            );
            client.max_write.store(
                if write == 0 {
                    cap
                } else {
                    (write as usize).min(cap).max(1)
                },
                Ordering::Relaxed,
            );
        }
        Ok(client)
    }
    pub fn path(&self, path: &str) -> Result<Vec<u8>> {
        ensure!(
            !path.contains('\0') && path.len() <= 65536,
            "Invalid remote path"
        );
        if self.encoding.load(Ordering::Relaxed) == 1 {
            let (bytes, _, failed) = encoding_rs::GB18030.encode(path);
            ensure!(!failed, "Filename cannot be represented in GB18030");
            Ok(bytes.into_owned())
        } else {
            Ok(path.as_bytes().to_vec())
        }
    }
    pub fn name(&self, name: &[u8]) -> Result<String> {
        if self.auto_encoding && std::str::from_utf8(name).is_err() {
            self.encoding.store(1, Ordering::Relaxed);
        }
        if self.encoding.load(Ordering::Relaxed) == 1 {
            let (text, _, failed) = encoding_rs::GB18030.decode(name);
            ensure!(!failed, "Invalid GB18030 filename");
            Ok(text.into_owned())
        } else {
            Ok(std::str::from_utf8(name)?.into())
        }
    }
    async fn request(&self, kind: u8, payload: Vec<u8>) -> Result<Vec<u8>> {
        let _permit = tokio::select! {_=self.cancel.cancelled()=>bail!("SFTP closed"),p=self.permits.acquire()=>p?};
        let id = self.sequence.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        match self.pending.lock().unwrap().entry(id) {
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(tx);
            }
            _ => bail!("SFTP sequence collision"),
        }
        let _cleanup = PendingRequest {
            id,
            map: self.pending.clone(),
        };
        let mut data = vec![kind];
        data.extend(id.to_be_bytes());
        data.extend(payload);
        let work = async {
            {
                let mut writer = self.writer.lock().await;
                let mut guard = WriteGuard(Some(self.cancel.clone()));
                send(&mut *writer, &data).await?;
                guard.0 = None;
            }
            let response = rx.await.context("SFTP connection closed")?;
            if response[0] == 101 {
                let mut fields = Reader(&response[5..]);
                let code = fields.u32()?;
                let message = String::from_utf8_lossy(fields.string()?)
                    .chars()
                    .take(4096)
                    .collect::<String>();
                if code != 0 {
                    return Err(Status(code, message).into());
                }
            }
            Ok(response)
        };
        let result = tokio::select! {_=self.cancel.cancelled()=>Err(anyhow::anyhow!("SFTP closed")),result=tokio::time::timeout(Duration::from_secs(30),work)=>result.context("SFTP request timed out")?};
        self.pending.lock().unwrap().remove(&id);
        result
    }
    async fn path_request(&self, kind: u8, path: &str) -> Result<Vec<u8>> {
        let mut data = Vec::new();
        string(&mut data, &self.path(path)?);
        self.request(kind, data).await
    }
    pub async fn stat(&self, path: &str, follow: bool) -> Result<Attributes> {
        let data = self.path_request(if follow { 17 } else { 7 }, path).await?;
        ensure!(data[0] == 105, "SFTP attributes expected");
        Attributes::parse(&mut Reader(&data[5..]))
    }
    pub async fn exists(&self, path: &str) -> Result<bool> {
        match self.stat(path, false).await {
            Ok(_) => Ok(true),
            Err(e) if missing(&e) => Ok(false),
            Err(e) => Err(e),
        }
    }
    pub async fn setstat(&self, path: &str, attrs: Attributes) -> Result<()> {
        let mut data = Vec::new();
        string(&mut data, &self.path(path)?);
        data.extend(attrs.encode());
        let response = self.request(9, data).await?;
        ensure!(response[0] == 101, "SFTP status expected");
        Ok(())
    }
    pub async fn open(&self, path: &str, flags: u32, attrs: Attributes) -> Result<Vec<u8>> {
        let mut data = Vec::new();
        string(&mut data, &self.path(path)?);
        data.extend(flags.to_be_bytes());
        data.extend(attrs.encode());
        let response = self.request(3, data).await?;
        ensure!(response[0] == 102, "SFTP handle expected");
        Ok(Reader(&response[5..]).string()?.to_vec())
    }
    pub async fn close(&self, handle: &[u8]) -> Result<()> {
        let mut data = Vec::new();
        string(&mut data, handle);
        let response = self.request(4, data).await?;
        ensure!(response[0] == 101, "SFTP close status expected");
        Ok(())
    }
    pub async fn read(&self, handle: &[u8], offset: u64, length: usize) -> Result<Vec<u8>> {
        ensure!(length <= 1024 * 1024, "Read length limit");
        let mut data = Vec::new();
        string(&mut data, handle);
        data.extend(offset.to_be_bytes());
        data.extend((length as u32).to_be_bytes());
        let response = match self.request(5, data).await {
            Ok(r) => r,
            Err(e) if eof(&e) => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        ensure!(response[0] == 103, "SFTP data expected");
        let bytes = Reader(&response[5..]).string()?.to_vec();
        ensure!(bytes.len() <= length, "SFTP read overrun");
        Ok(bytes)
    }
    pub async fn write(&self, handle: &[u8], offset: u64, bytes: &[u8]) -> Result<()> {
        let mut data = Vec::new();
        string(&mut data, handle);
        data.extend(offset.to_be_bytes());
        string(&mut data, bytes);
        let r = self.request(6, data).await?;
        ensure!(r[0] == 101, "SFTP write status expected");
        Ok(())
    }
    fn names(&self, response: &[u8]) -> Result<Vec<(String, Attributes)>> {
        ensure!(response[0] == 104, "SFTP names expected");
        let mut fields = Reader(&response[5..]);
        let count = fields.u32()?;
        ensure!(count <= 100000, "SFTP directory item limit");
        let mut entries = Vec::new();
        for _ in 0..count {
            let name = fields.string()?;
            fields.string()?;
            let attrs = Attributes::parse(&mut fields)?;
            entries.push((self.name(name)?, attrs));
        }
        ensure!(fields.0.is_empty(), "Trailing SFTP directory data");
        Ok(entries)
    }
    pub async fn canonicalize(&self, path: &str) -> Result<String> {
        let response = self.path_request(16, path).await?;
        Ok(self
            .names(&response)?
            .into_iter()
            .next()
            .context("Empty canonical path")?
            .0)
    }
    pub async fn read_link(&self, path: &str) -> Result<String> {
        let response = self.path_request(19, path).await?;
        Ok(self
            .names(&response)?
            .into_iter()
            .next()
            .context("Empty symlink")?
            .0)
    }
    pub async fn list(&self, path: &str) -> Result<Vec<(String, Attributes)>> {
        let response = self.path_request(11, path).await?;
        ensure!(response[0] == 102, "SFTP directory handle expected");
        let handle = Reader(&response[5..]).string()?.to_vec();
        let work = async {
            let mut entries = Vec::new();
            let mut empty_batches = 0;
            loop {
                let mut payload = Vec::new();
                string(&mut payload, &handle);
                let response = match self.request(12, payload).await {
                    Ok(r) => r,
                    Err(e) if eof(&e) => break,
                    Err(e) => return Err(e),
                };
                let batch = self.names(&response)?;
                // Some servers return NAME(count=0) once before EOF for an
                // empty directory. Bound repeated empty replies to avoid a
                // malicious server keeping this operation alive indefinitely.
                if batch.is_empty() {
                    empty_batches += 1;
                    ensure!(empty_batches <= 8, "SFTP directory did not reach EOF");
                } else {
                    empty_batches = 0;
                }
                entries.extend(
                    batch
                        .into_iter()
                        .filter(|(name, _)| name != "." && name != ".."),
                );
                ensure!(entries.len() <= 100000, "Directory item limit");
            }
            Ok(entries)
        }
        .await;
        let closed = self.close(&handle).await;
        let result = work?;
        closed?;
        Ok(result)
    }
    pub async fn mkdir(&self, path: &str) -> Result<()> {
        let mut data = Vec::new();
        string(&mut data, &self.path(path)?);
        data.extend(
            Attributes {
                permissions: Some(0o755),
                ..Default::default()
            }
            .encode(),
        );
        let r = self.request(14, data).await?;
        ensure!(r[0] == 101, "SFTP mkdir status expected");
        Ok(())
    }
    pub async fn remove(&self, path: &str, directory: bool) -> Result<()> {
        let r = self
            .path_request(if directory { 15 } else { 13 }, path)
            .await?;
        ensure!(r[0] == 101, "SFTP remove status expected");
        Ok(())
    }
    pub async fn rename(&self, old: &str, new: &str, replace: bool) -> Result<()> {
        let mut data = Vec::new();
        let extended = replace && self.extensions.contains_key("posix-rename@openssh.com");
        if extended {
            string(&mut data, b"posix-rename@openssh.com");
        }
        string(&mut data, &self.path(old)?);
        string(&mut data, &self.path(new)?);
        let r = self.request(if extended { 200 } else { 18 }, data).await?;
        ensure!(r[0] == 101, "SFTP rename status expected");
        Ok(())
    }
    pub async fn shutdown(&self) {
        self.cancel.cancel();
        let _ = self.writer.lock().await.shutdown().await;
    }
}

struct WriteGuard(Option<CancellationToken>);
impl Drop for WriteGuard {
    fn drop(&mut self) {
        if let Some(cancel) = &self.0 {
            cancel.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn attributes_truncation_and_bounds() {
        for n in 0..32 {
            let bytes = vec![0xff; n];
            assert!(Attributes::parse(&mut Reader(&bytes)).is_err());
        }
        let a = Attributes {
            size: Some(99),
            permissions: Some(0o100644),
            mtime: Some(123),
            ..Default::default()
        };
        let b = a.encode();
        let c = Attributes::parse(&mut Reader(&b)).unwrap();
        assert_eq!(c.size, a.size);
        assert_eq!(c.kind(), "file");
    }
}
