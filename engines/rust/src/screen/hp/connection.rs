use super::{
    crypto::Control,
    offers::{self, Keys},
};
use crate::{
    ipc::text,
    screen::{apple, Counted, Output, Traffic},
};
use anyhow::{bail, ensure, Context, Result};
use serde_json::Value;
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, ReadHalf, WriteHalf},
    net::TcpStream,
};

type Stream = BufReader<Counted<TcpStream>>;
pub struct Reader {
    stream: ReadHalf<Stream>,
    cipher: Control,
    pending: Vec<u8>,
    failures: u8,
    partial_since: Option<tokio::time::Instant>,
}
pub struct Writer {
    stream: WriteHalf<Stream>,
    pub cipher: Control,
    poisoned: bool,
}
pub struct Connection {
    pub reader: Reader,
    pub writer: Writer,
    pub keys: Keys,
    pub width: u16,
    pub height: u16,
    pub tiles: u16,
    pub leftover: Vec<Vec<u8>>,
}
impl Reader {
    // Cancellation-safe: read() consumes network bytes only in a ready poll,
    // then appends them before another await. Partial records stay owned here.
    pub async fn read(&mut self) -> Result<Vec<u8>> {
        loop {
            if self.pending.len() >= 2 {
                let size = u16::from_be_bytes(self.pending[..2].try_into()?) as usize;
                ensure!(
                    (32..=65520).contains(&size) && size.is_multiple_of(16),
                    "Invalid encrypted record size"
                );
                if self.pending.len() >= size + 2 {
                    let plain = self.cipher.decrypt(&self.pending[2..size + 2])?;
                    self.pending.drain(..size + 2);
                    self.partial_since = if self.pending.is_empty() {
                        None
                    } else {
                        Some(tokio::time::Instant::now())
                    };
                    if let Some(plain) = plain {
                        self.failures = 0;
                        return Ok(plain);
                    }
                    self.failures += 1;
                    ensure!(self.failures <= 3, "Control authentication failed");
                    continue;
                }
            }
            let mut bytes = [0; 16384];
            let n = if let Some(since) = self.partial_since {
                tokio::time::timeout_at(
                    since + Duration::from_secs(15),
                    self.stream.read(&mut bytes),
                )
                .await
                .context("Partial control record timed out")??
            } else {
                self.stream.read(&mut bytes).await?
            };
            if self.pending.is_empty() {
                self.partial_since = Some(tokio::time::Instant::now());
            }
            ensure!(n != 0, "Remote screen connection closed");
            self.pending.extend(&bytes[..n]);
            ensure!(
                self.pending.len() <= 81920,
                "Encrypted control buffer limit"
            );
        }
    }
}
impl Writer {
    #[cfg(test)]
    pub(super) fn test_writer(stream: TcpStream) -> Self {
        let stream = BufReader::new(Counted {
            inner: stream,
            traffic: Arc::default(),
        });
        Self {
            stream: tokio::io::split(stream).1,
            cipher: Control::pair(&[3; 16], &[5; 36]).unwrap().0,
            poisoned: false,
        }
    }
    pub async fn send(&mut self, message: &[u8]) -> Result<()> {
        ensure!(!self.poisoned, "disconnected");
        ensure!(message.len() <= 8 * 1024 * 1024, "Control message limit");
        let result = tokio::time::timeout(Duration::from_secs(15), async {
            for chunk in message.chunks(60000) {
                let wire = self.cipher.encrypt(chunk)?;
                self.stream.write_all(&wire).await?;
            }
            self.stream.flush().await?;
            Ok::<_, anyhow::Error>(())
        })
        .await
        .context("connectionTimeout")
        .and_then(|result| result);
        if result.is_err() {
            self.poisoned = true;
            let _ = self.stream.shutdown().await;
        }
        result
    }
    pub async fn close(&mut self) {
        let _ = self.stream.shutdown().await;
    }
}
async fn bytes(stream: &mut Stream, count: usize) -> Result<Vec<u8>> {
    ensure!(count <= 65536, "Handshake size limit");
    let mut data = vec![0; count];
    stream.read_exact(&mut data).await?;
    Ok(data)
}
async fn cipher(stream: &mut Stream, key: &[u8; 16]) -> Result<(Control, Control)> {
    let mut found = None;
    for _ in 0..64 {
        match stream.read_u8().await? {
            0x14 => {
                bytes(stream, 7).await?;
            }
            0 => {
                stream.read_u8().await?;
                let count = stream.read_u16().await?;
                ensure!(count <= 128, "Handshake rectangle limit");
                for _ in 0..count {
                    let rect = bytes(stream, 12).await?;
                    let encoding = i32::from_be_bytes(rect[8..12].try_into()?);
                    match encoding {
                        1103 => {
                            found = Some(Control::pair(key, &bytes(stream, 36).await?)?);
                        }
                        1010 | 1011 => {
                            let n = stream.read_u16().await?;
                            bytes(stream, n as usize).await?;
                        }
                        _ => bail!("Unexpected encryption handshake rectangle"),
                    }
                }
                if let Some(pair) = found {
                    return Ok(pair);
                }
            }
            _ => bail!("Unexpected encryption handshake message"),
        }
    }
    bail!("Server did not enable encrypted control")
}
pub async fn warmup(address: SocketAddr) {
    let _ = tokio::time::timeout(Duration::from_secs(3), async {
        let mut stream = TcpStream::connect(address).await?;
        let mut version = [0; 12];
        stream.read_exact(&mut version).await?;
        stream.write_all(b"RFB 003.889\n").await?;
        let n = stream.read_u8().await?;
        let mut types = vec![0; n as usize];
        stream.read_exact(&mut types).await?;
        stream.shutdown().await
    })
    .await;
    tokio::time::sleep(Duration::from_millis(1400)).await;
}
pub async fn connect(
    address: SocketAddr,
    config: &Value,
    output: &Output,
    traffic: Arc<Traffic>,
) -> Result<Connection> {
    let display = offers::DisplayMode::from_config(config)?;
    output.status("tcp").await?;
    let stream = TcpStream::connect(address).await?;
    stream.set_nodelay(true)?;
    let mut stream = BufReader::new(Counted {
        inner: stream,
        traffic,
    });
    let version = bytes(&mut stream, 12).await?;
    ensure!(
        version.starts_with(b"RFB 003.") && version[11] == b'\n',
        "vncProtocolUnsupported"
    );
    stream.write_all(b"RFB 003.889\n").await?;
    let count = stream.read_u8().await?;
    let types = bytes(&mut stream, count as usize).await?;
    ensure!(types.contains(&33), "vncAuthenticationUnsupported");
    output.status("authenticate").await?;
    let key = zeroize::Zeroizing::new(
        apple::authenticate(
            &mut stream,
            text(config, "username"),
            text(config, "password"),
        )
        .await?,
    );
    output.status("negotiate").await?;
    stream.write_all(&[0xc1]).await?;
    let init = bytes(&mut stream, 24).await?;
    let name = u32::from_be_bytes(init[20..24].try_into()?) as usize;
    bytes(&mut stream, name).await?;
    if let Ok(result) = tokio::time::timeout(Duration::from_secs(2), stream.fill_buf()).await {
        let peek = result?;
        if peek.starts_with(&[0, 0x4a, 0, 1])
            || (!peek.is_empty() && peek.len() < 4 && [0, 0x4a, 0, 1].starts_with(peek))
        {
            bail!("consoleAccount");
        }
    }
    stream.write_all(&offers::viewer_info()).await?;
    tokio::time::sleep(Duration::from_millis(100)).await;
    stream.write_all(&offers::virtual_display(display)).await?;
    stream.write_all(&offers::encodings()).await?;
    let (tx, rx) = tokio::time::timeout(Duration::from_secs(12), cipher(&mut stream, &key))
        .await
        .context("encryptionTimeout")??;
    stream.write_all(&[0x12, 0, 0, 2, 0, 1, 0, 0]).await?;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let (read, write) = tokio::io::split(stream);
    let mut reader = Reader {
        stream: read,
        cipher: rx,
        pending: Vec::new(),
        partial_since: None,
        failures: 0,
    };
    let mut writer = Writer {
        stream: write,
        cipher: tx,
        poisoned: false,
    };
    let mut leftover = Vec::new();
    let until = tokio::time::Instant::now() + Duration::from_millis(500);
    while let Ok(result) = tokio::time::timeout_at(until, reader.read()).await {
        let message = result?;
        ensure!(leftover.len() < 64, "Negotiation message limit");
        leftover.push(message);
    }
    let keys = Keys::new();
    let codec = offers::VideoCodec::from_config(config);
    let offer = keys.message_for_codec(codec)?;
    writer.send(&offers::encodings()).await?;
    writer.send(&offer).await?;
    writer.send(&offers::framebuffer(false, true)).await?;
    for attempt in 0..17 {
        let until = tokio::time::Instant::now() + Duration::from_secs(3);
        while let Ok(result) = tokio::time::timeout_at(until, reader.read()).await {
            let message = result?;
            if let Some((width, height, tiles)) = offers::dimensions_for_codec(&message, codec)? {
                return Ok(Connection {
                    reader,
                    writer,
                    keys,
                    width,
                    height,
                    tiles,
                    leftover,
                });
            }
            ensure!(leftover.len() < 256, "Negotiation message limit");
            leftover.push(message);
        }
        if attempt < 16 {
            tokio::time::sleep(Duration::from_millis(200)).await;
            writer.send(&offer).await?;
        }
    }
    bail!("mediaNegotiationFailed")
}
