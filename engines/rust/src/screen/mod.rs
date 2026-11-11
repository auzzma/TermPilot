//! Framed native screen-sharing IPC. Slow UI consumers retain only the newest
//! picture per tile; control and file events remain ordered and bounded.
pub mod apple;
pub mod hp;
mod keyboard;
pub mod pixels;
pub mod vnc;
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    pin::Pin,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    task::{Context as TaskContext, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, ReadBuf},
    sync::{mpsc, watch},
};
use tokio_util::sync::CancellationToken;

pub struct Packet {
    pub header: Value,
    pub payload: Vec<u8>,
}
#[derive(Clone)]
pub struct Output {
    events: mpsc::Sender<Packet>,
    video: Arc<Mutex<BTreeMap<u64, Packet>>>,
    audio: mpsc::Sender<Packet>,
}
impl Output {
    pub async fn emit(&self, header: Value, payload: Vec<u8>) -> Result<()> {
        self.events
            .send(Packet { header, payload })
            .await
            .context("Screen client closed")
    }
    pub async fn status(&self, stage: &str) -> Result<()> {
        self.emit(json!({"kind":"status","stage":stage}), Vec::new())
            .await
    }
    pub fn frame(&self, header: Value, payload: Vec<u8>) {
        if let Some(tile) = header["tile"].as_u64().filter(|tile| *tile < 16) {
            self.video
                .lock()
                .unwrap()
                .insert(tile, Packet { header, payload });
        }
    }
    pub fn audio(&self, payload: Vec<u8>) {
        let _ = self.audio.try_send(Packet {
            header: json!({"kind":"audio"}),
            payload,
        });
    }
}
#[derive(Default)]
pub struct Traffic {
    pub received: AtomicU64,
    pub sent: AtomicU64,
}
impl Traffic {
    pub fn snapshot(&self) -> (u64, u64) {
        (
            self.received.load(Ordering::Relaxed),
            self.sent.load(Ordering::Relaxed),
        )
    }
}
pub struct Counted<T> {
    pub inner: T,
    pub traffic: Arc<Traffic>,
}
impl<T: AsyncRead + Unpin> AsyncRead for Counted<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let before = buffer.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(cx, buffer);
        self.traffic
            .received
            .fetch_add((buffer.filled().len() - before) as u64, Ordering::Relaxed);
        result
    }
}
impl<T: AsyncWrite + Unpin> AsyncWrite for Counted<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        data: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let result = Pin::new(&mut self.inner).poll_write(cx, data);
        if let Poll::Ready(Ok(n)) = result {
            self.traffic.sent.fetch_add(n as u64, Ordering::Relaxed);
        }
        result
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}
fn screen_error_event(error: &anyhow::Error) -> Value {
    let code = if error.downcast_ref::<std::io::Error>().is_some_and(|io| io.kind() == std::io::ErrorKind::AddrNotAvailable) {
        "addressNotAvailable".to_owned()
    } else {
        error.to_string()
    };
    let mut event = json!({"kind":"error","code":code});
    match code.as_str() {
        "authenticationRejected" => event["message"] = json!("Remote authentication failed. Check the account and password."),
        "serverProof" => event["message"] = json!("The remote server's authentication proof could not be verified."),
        "addressNotAvailable" => event["message"] = json!("Local network address unavailable. Check the network or VPN connection."),
        _ => {}
    }
    event
}

async fn write_packet<W: AsyncWrite + Unpin>(output: &mut W, mut packet: Packet) -> Result<()> {
    ensure!(
        packet.payload.len() <= 64 * 1024 * 1024,
        "Screen payload limit"
    );
    packet.header["payloadLength"] = json!(packet.payload.len());
    let bytes = serde_json::to_vec(&packet.header)?;
    ensure!((2..=65536).contains(&bytes.len()), "Screen header limit");
    output.write_u32(bytes.len() as u32).await?;
    output.write_all(&bytes).await?;
    output.write_all(&packet.payload).await?;
    output.flush().await?;
    Ok(())
}
pub async fn run() -> Result<()> {
    serve(tokio::io::stdin(), tokio::io::stdout()).await
}

/// Embed the same framed protocol in a native client without spawning a worker.
pub async fn serve<R, W>(read: R, write: W) -> Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let mut input = BufReader::new(read);
    let config = crate::ipc::read_json_limit(&mut input, 1024 * 1024)
        .await?
        .context("Screen configuration missing")?;
    ensure!(
        crate::ipc::text(&config, "kind") == "connect",
        "Screen connection command required"
    );
    let (events, mut controls) = mpsc::channel(64);
    let (audio, mut sounds) = mpsc::channel(50);
    let (frame_rate, mut frame_rate_changes) = watch::channel(
        termpilot_core::frame::normalized_frame_rate(config["frameRate"].as_u64()),
    );
    let output = Output {
        events,
        audio,
        video: Arc::default(),
    };
    let stop = CancellationToken::new();
    let writer_stop = stop.clone();
    let video = output.video.clone();
    let writer = tokio::spawn(async move {
        let mut stdout = write;
        // Pacing changes live; stale tiles remain bounded when consumers stall.
        let mut frames =
            tokio::time::interval(Duration::from_secs(1) / *frame_rate_changes.borrow());
        frames.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let result:Result<()>=async { loop { tokio::select! {
            biased;
            packet=controls.recv()=>match packet {Some(p)=>write_packet(&mut stdout,p).await?,None=>break},
            packet=sounds.recv()=>if let Some(p)=packet{write_packet(&mut stdout,p).await?;},
            Ok(())=frame_rate_changes.changed()=>{
                let period=Duration::from_secs(1) / *frame_rate_changes.borrow_and_update();
                frames=tokio::time::interval_at(tokio::time::Instant::now()+period,period);
                frames.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            },
            _=frames.tick()=>{let packets=std::mem::take(&mut *video.lock().unwrap());for(_,packet)in packets{write_packet(&mut stdout,packet).await?;}}
        }}Ok(()) }.await;
        writer_stop.cancel();
        result
    });
    let (commands, receiver) = mpsc::channel(64);
    let input_stop = stop.clone();
    let reader = tokio::spawn(async move {
        loop {
            let result = crate::ipc::read_json_limit(&mut input, 1024 * 1024).await;
            let Ok(Some(command)) = result else {
                break;
            };
            if crate::ipc::text(&command, "kind") == "disconnect" {
                break;
            }
            if crate::ipc::text(&command, "kind") == "frameRate" {
                let rate = termpilot_core::frame::normalized_frame_rate(command["fps"].as_u64());
                frame_rate.send_if_modified(|current| {
                    if *current == rate {
                        return false;
                    }
                    *current = rate;
                    true
                });
                continue;
            }
            if commands.send(command).await.is_err() {
                break;
            }
        }
        input_stop.cancel();
    });
    let traffic = Arc::new(Traffic::default());
    let (stats, stats_stop, stats_output) = (traffic.clone(), stop.clone(), output.clone());
    let performance = tokio::spawn(async move {
        let mut previous = stats.snapshot();
        let mut time = tokio::time::Instant::now();
        loop {
            tokio::select! {_=stats_stop.cancelled()=>break,_=tokio::time::sleep(Duration::from_secs(1))=>{}}
            let now = stats.snapshot();
            let elapsed = time.elapsed().as_secs_f64();
            time = tokio::time::Instant::now();
            let _=stats_output.emit(json!({"kind":"performance","receiveBytesPerSecond":(now.0-previous.0)as f64/elapsed,"sendBytesPerSecond":(now.1-previous.1)as f64/elapsed}),Vec::new()).await;
            previous = now;
        }
    });
    let result = if crate::ipc::text(&config, "mode") == "standardVNC" {
        vnc::run(config, output.clone(), receiver, traffic, stop.clone()).await
    } else {
        hp::run(config, output.clone(), receiver, traffic, stop.clone()).await
    };
    if let Err(error) = &result {
        let _ = output.emit(screen_error_event(error), Vec::new()).await;
    }
    stop.cancel();
    reader.abort();
    performance.abort();
    output.video.lock().unwrap().clear();
    let _ = output
        .emit(json!({"kind":"disconnected"}), Vec::new())
        .await;
    drop(output);
    let _ = tokio::time::timeout(Duration::from_secs(2), writer).await;
    result
}


#[cfg(test)]
mod connection_error_tests {
    use super::*;

    #[test]
    fn unavailable_network_address_is_distinct_from_authentication_and_port_conflicts() {
        let os_error = std::io::Error::from(std::io::ErrorKind::AddrNotAvailable);
        let error = anyhow::Error::new(os_error).context("video transport");
        assert_eq!(screen_error_event(&error)["code"], "addressNotAvailable");
        for code in ["authenticationRejected", "serverProof", "udpPortsInUse"] {
            assert_eq!(screen_error_event(&anyhow::anyhow!(code))["code"], code);
        }
    }
}
