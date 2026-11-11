use anyhow::{Context, Result};
use serde_json::{Value, json};
use std::{
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context as Cx, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf},
    sync::{mpsc, watch},
};

#[derive(Debug)]
pub struct Packet {
    pub header: Value,
    pub payload: Vec<u8>,
}
impl Packet {
    fn prepare(&mut self) -> Result<()> {
        if self.header["kind"] == "clipboard" {
            if let Some(text) = self
                .header
                .as_object_mut()
                .and_then(|h| h.remove("text"))
                .and_then(|v| v.as_str().map(str::to_owned))
            {
                self.payload = text.into_bytes();
            }
        } else if self.header["kind"] == "clipboardFiles" {
            if let Some(paths) = self.header.as_object_mut().and_then(|h| h.remove("paths")) {
                self.payload = serde_json::to_vec(&paths)?;
            }
        }
        self.header["payloadLength"] = json!(self.payload.len());
        Ok(())
    }
}
#[derive(Clone, Debug)]
pub struct Output {
    events: mpsc::Sender<Packet>,
    image: Arc<Mutex<Option<Packet>>>,
    frame_rate: watch::Sender<u32>,
}
impl Output {
    pub fn start() -> (Self, tokio::task::JoinHandle<Result<()>>) {
        Self::start_with_writer(tokio::io::stdout())
    }
    pub(crate) fn start_with_writer(
        mut stdout: impl AsyncWrite + Unpin + Send + 'static,
    ) -> (Self, tokio::task::JoinHandle<Result<()>>) {
        let (events, mut rx) = mpsc::channel::<Packet>(64);
        let image = Arc::new(Mutex::new(None));
        let (frame_rate, mut frame_rate_changes) =
            watch::channel(termpilot_core::frame::DEFAULT_FRAME_RATE);
        let output = Self {
            events,
            image: image.clone(),
            frame_rate,
        };
        let task = tokio::spawn(async move {
            let mut frames =
                tokio::time::interval(Duration::from_secs(1) / *frame_rate_changes.borrow());
            frames.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                let packet = tokio::select! {
                    biased;
                    e = rx.recv() => match e {Some(p) => Some(p), None => break},
                    Ok(()) = frame_rate_changes.changed() => {
                        let period = Duration::from_secs(1) / *frame_rate_changes.borrow_and_update();
                        frames = tokio::time::interval_at(tokio::time::Instant::now() + period, period);
                        frames.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                        continue;
                    },
                    _ = frames.tick() => image.lock().unwrap().take(),
                };
                if let Some(mut p) = packet {
                    p.prepare()?;
                    let header = serde_json::to_vec(&p.header)?;
                    termpilot_core::frame::validate_header(&header)
                        .map_err(|e| anyhow::anyhow!(e.message))?;
                    stdout.write_u32(header.len() as u32).await?;
                    stdout.write_all(&header).await?;
                    stdout.write_all(&p.payload).await?;
                    stdout.flush().await?;
                }
            }
            Ok(())
        });
        (output, task)
    }
    pub fn set_frame_rate(&self, value: Option<u64>) {
        let rate = termpilot_core::frame::normalized_frame_rate(value);
        self.frame_rate.send_if_modified(|current| {
            if *current == rate {
                return false;
            }
            *current = rate;
            true
        });
    }
    pub async fn emit(&self, header: Value) -> Result<()> {
        self.events
            .send(Packet {
                header,
                payload: Vec::new(),
            })
            .await
            .context("RDP UI closed")
    }
    pub fn event(&self, header: Value) {
        // Callback-side control traffic is small; a full channel is an explicit error.
        if self
            .events
            .try_send(Packet {
                header,
                payload: Vec::new(),
            })
            .is_err()
        {
            tracing::error!("RDP control event queue is full or closed");
        }
    }
    pub fn frame(&self, width: u16, height: u16, buffer: Vec<u32>) {
        let mut payload = Vec::with_capacity(buffer.len() * 4);
        for pixel in buffer {
            payload.extend_from_slice(&pixel.to_le_bytes());
        }
        *self.image.lock().unwrap() = Some(Packet {
            header: json!({"kind":"frame","tile":0,"width":width,"height":height,"yStride":width as u32*4,"pixelFormat":"bgrx","codec":"raw"}),
            payload,
        });
    }
}
#[derive(Default)]
pub struct Traffic {
    pub received: AtomicU64,
    pub sent: AtomicU64,
}
pub struct Counted<T> {
    pub inner: T,
    pub traffic: Arc<Traffic>,
}
impl<T: AsyncRead + Unpin> AsyncRead for Counted<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Cx<'_>,
        b: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let n = b.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(cx, b);
        self.traffic
            .received
            .fetch_add((b.filled().len() - n) as u64, Ordering::Relaxed);
        result
    }
}
impl<T: AsyncWrite + Unpin> AsyncWrite for Counted<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Cx<'_>,
        b: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let r = Pin::new(&mut self.inner).poll_write(cx, b);
        if let Poll::Ready(Ok(n)) = r {
            self.traffic.sent.fetch_add(n as u64, Ordering::Relaxed);
        }
        r
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Cx<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Cx<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    #[tokio::test(start_paused = true)]
    async fn frame_rate_changes_without_reconnecting_and_keeps_latest_image() {
        let (writer, mut reader) = tokio::io::duplex(4096);
        let (output, task) = Output::start_with_writer(writer);
        async fn pixel(reader: &mut tokio::io::DuplexStream) -> u32 {
            let length = reader.read_u32().await.unwrap();
            let mut header = vec![0; length as usize];
            reader.read_exact(&mut header).await.unwrap();
            assert_eq!(
                serde_json::from_slice::<Value>(&header).unwrap()["payloadLength"],
                4
            );
            reader.read_u32_le().await.unwrap()
        }
        for (rate, early, remaining, value) in [(30, 32, 2, 1), (60, 15, 2, 2), (30, 32, 2, 3)] {
            output.set_frame_rate(Some(rate));
            output.frame(1, 1, vec![0]);
            output.frame(1, 1, vec![value]);
            tokio::task::yield_now().await;
            tokio::time::advance(Duration::from_millis(early)).await;
            assert!(
                tokio::time::timeout(Duration::ZERO, reader.read_u32())
                    .await
                    .is_err()
            );
            tokio::time::advance(Duration::from_millis(remaining)).await;
            assert_eq!(pixel(&mut reader).await, value);
        }
        drop(output);
        task.await.unwrap().unwrap();
    }
    #[test]
    fn large_file_lists_use_payload_instead_of_exceeding_header_limit() {
        let paths = (0..10000)
            .map(|n| format!("/tmp/TermPilot/RDP/snapshot/{n}-中文.txt"))
            .collect::<Vec<_>>();
        let mut packet = Packet {
            header: json!({"kind":"clipboardFiles","paths":paths}),
            payload: vec![],
        };
        packet.prepare().unwrap();
        let header = serde_json::to_vec(&packet.header).unwrap();
        assert!(header.len() < 65536);
        assert!(packet.payload.len() > 65536);
        assert_eq!(
            termpilot_core::frame::validate_header(&header).unwrap(),
            packet.payload.len()
        );
        assert_eq!(
            serde_json::from_slice::<Vec<String>>(&packet.payload).unwrap(),
            paths
        );
    }
}
