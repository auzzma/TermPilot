mod audio;
mod clipboard;
mod input;
mod wire;
// Both Rust workers use the same proxy and JSON transport implementation.
#[path = "../../rust/src/ipc.rs"]
mod ipc;
#[path = "../../rust/src/transport.rs"]
mod transport;

use anyhow::{Context, Result, ensure};
use ironrdp_client::{
    config::{ClientStream, ClipboardType, ConfigBuilder, Destination},
    rdp::{AutoReconnectDecision, RdpClient, RdpOutputEvent},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{Arc, Mutex, atomic::Ordering},
    time::Duration,
};
use tokio::io::BufReader;

// ConnectorError's Display ignores alternate formatting. Include its source
// chain explicitly so transport failures retain the endpoint and OS reason.
fn connection_error_message(error: &(dyn std::error::Error + 'static)) -> String {
    let mut message = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        message.push_str(": ");
        message.push_str(&cause.to_string());
        source = cause.source();
    }
    message
}

/// Run the shared RDP client over private in-process or desktop IPC streams.
pub async fn serve<R, W>(read: R, write: W) -> Result<()>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
    W: tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    // Core sync (reqwest/ring) and IronRDP (aws-lc-rs) enable both providers.
    // Select one before TLS on every entry path, including the standalone worker.
    // An embedding client may already have selected a provider; keep that choice.
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    let (output, writer) = wire::Output::start_with_writer(write);
    let result = run(output.clone(), read).await;
    if let Err(e) = &result {
        let _ = output
            .emit(json!({"kind":"error","code":e.to_string(),"message":e.to_string()}))
            .await;
    }
    drop(output);
    let _ = tokio::time::timeout(Duration::from_secs(2), writer).await;
    result
}
async fn run<R: tokio::io::AsyncRead + Unpin>(output: wire::Output, read: R) -> Result<()> {
    let mut reader = ipc::JsonReader::new(BufReader::new(read));
    let mut cfg = reader.read().await?.context("RDP configuration required")?;
    ensure!(cfg["kind"] == "connect", "RDP connect command required");
    output.set_frame_rate(cfg["frameRate"].as_u64());
    let host = ipc::text(&cfg, "host").to_owned();
    let port = cfg["port"].as_u64().unwrap_or(3389);
    termpilot_core::connection::validate_endpoint(&host, port)
        .map_err(|e| anyhow::anyhow!(e.message))?;
    let user = ipc::text(&cfg, "username").to_owned();
    ensure!(!user.is_empty(), "Username required");
    let (domain, username) = user
        .split_once('\\')
        .map(|(d, u)| (Some(d.to_owned()), u.to_owned()))
        .unwrap_or((None, user));
    let password = ipc::text(&cfg, "password").to_owned();
    let proxy = cfg["proxy"].clone();
    ensure!(
        proxy.is_null()
            || matches!(ipc::text(&proxy, "type"), "http" | "socks5")
            || matches!(ipc::text(&proxy, "kind"), "http" | "socks5"),
        "RDP supports HTTP CONNECT or SOCKS5 proxies"
    );
    let traffic = Arc::new(wire::Traffic::default());
    let trusted: Arc<Mutex<HashSet<String>>> = Arc::default();
    if let Some(pin) = cfg["certificateSHA256"]
        .as_str()
        .filter(|s| s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit()))
    {
        trusted.lock().unwrap().insert(pin.to_lowercase());
    }
    let decisions: Arc<Mutex<HashMap<String, std::sync::mpsc::Sender<bool>>>> = Arc::default();
    let (trust, answers, notice) = (trusted.clone(), decisions.clone(), output.clone());
    let callback = Arc::new(
        move |certificate: &[u8], endpoint: &str, error: &str| -> bool {
            let fingerprint = hex::encode(Sha256::digest(certificate));
            if trust.lock().unwrap().contains(&fingerprint) {
                return true;
            }
            let id = uuid::Uuid::new_v4().to_string();
            let (tx, rx) = std::sync::mpsc::channel();
            answers.lock().unwrap().insert(id.clone(), tx);
            notice.event(json!({"kind":"certificate","id":id,"endpoint":endpoint,"sha256":fingerprint,"message":error}));
            let accept = rx.recv_timeout(Duration::from_secs(120)).unwrap_or(false);
            answers.lock().unwrap().remove(&id);
            if accept {
                trust.lock().unwrap().insert(fingerprint);
            }
            accept
        },
    );
    let audio_enabled = Arc::new(std::sync::atomic::AtomicBool::new(
        cfg["audio"].as_bool().unwrap_or(true),
    ));
    let mut builder = ConfigBuilder::new()
        .with_destination(Destination::from_parts(&host, port as u16))
        .with_client_build(1)
        .with_client_dir("TermPilot")
        .with_platform(ironrdp_pdu::rdp::capability_sets::MajorPlatformType::WINDOWS)
        .with_username(username)
        .with_password(password)
        .with_client_name("TermPilot")
        .with_desktop_width(cfg["width"].as_u64().unwrap_or(1920).clamp(320, 3840) as u16)
        .with_desktop_height(cfg["height"].as_u64().unwrap_or(1080).clamp(200, 2160) as u16)
        .with_color_depth(32)
        // The upstream default disables full-window dragging. Request live window
        // contents while preserving the existing menu-animation and font settings.
        .with_performance_flags(
            ironrdp_pdu::rdp::client_info::PerformanceFlags::DISABLE_MENUANIMATIONS
                | ironrdp_pdu::rdp::client_info::PerformanceFlags::ENABLE_FONT_SMOOTHING,
        )
        .with_credssp(true)
        .with_tls(true)
        .with_autologon(true)
        .with_certificate_validation(ironrdp_tls::CertificateValidation::Strict)
        .with_certificate_validation_callback(callback)
        .with_pointer_software_rendering(true)
        // Windows requires RDPDR to establish its RDPSND endpoint (MS-RDPEA §6).
        // The default no-op device backend exposes no drives, printers or other devices.
        .with_rdpdr(true)
        .with_sound(true)
        .with_audio_capture(false)
        .with_clipboard(ClipboardType::Enable);
    if let Some(domain) = domain.or_else(|| {
        cfg["domain"]
            .as_str()
            .filter(|d| !d.is_empty())
            .map(str::to_owned)
    }) {
        builder = builder.with_domain(domain);
    }
    // Proxy connection errors propagate; the factory cannot fall back to direct TCP.
    let stats = traffic.clone();
    let status = output.clone();
    let mute = audio_enabled.clone();
    let audio_statistics = Arc::new(audio::Statistics::default());
    let audio_stats = audio_statistics.clone();
    let audio_output = output.clone();
    let config = builder
        .build()?
        .with_audio_factory(Arc::new(move || {
            Box::new(audio::Playback::new(
                mute.clone(),
                audio_stats.clone(),
                audio_output.clone(),
            ))
        }))
        .with_stream_factory(Arc::new(move || {
            let (host, proxy, stats, status) =
                (host.clone(), proxy.clone(), stats.clone(), status.clone());
            Box::pin(async move {
                status
                    .emit(json!({"kind":"status","stage":"建立 RDP 连接"}))
                    .await?;
                let stream = transport::connect(&host, port as u16, &proxy).await?;
                status
                    .emit(json!({"kind":"status","stage":"验证证书与账户"}))
                    .await?;
                Ok((
                    Box::new(wire::Counted {
                        inner: stream,
                        traffic: stats,
                    }) as Box<dyn ClientStream>,
                    ([127, 0, 0, 1], 0).into(),
                ))
            })
        }));
    cfg["password"] = Value::Null;
    let cache = cfg["cacheDirectory"]
        .as_str()
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("TermPilot/RDP"));
    ensure!(cache.is_absolute(), "RDP cache path must be absolute");
    let shared = clipboard::Shared::new(output.clone(), cache);
    let (tx, mut events) = ironrdp_client::output_channel::output_channel(32);
    let client = RdpClient::new(config, tx)
        .with_cliprdr_backend_factory(Box::new(clipboard::Factory(shared.clone())))
        .with_auto_reconnect(3);
    let sender = client.input_sender();
    shared.set_sender(sender.clone());
    let task = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("RDP runtime")
            .block_on(client.run());
    });
    let mut input = input::Input::default();
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    let mut dimensions = (0, 0);
    let mut previous = (0, 0);
    let mut sampled = std::time::Instant::now();
    loop {
        tokio::select! {
            command=reader.read()=>{
                let Some(command)=command? else {break;};
                if std::env::var_os("TERMPILOT_RDP_DIAGNOSTICS").is_some() { output.emit(json!({"kind":"inputDiagnostic","command":command["kind"]})).await?; }
                match ipc::text(&command,"kind") {
                    "disconnect"=>break,
                    "frameRate"=>output.set_frame_rate(command["fps"].as_u64()),
                    "certificateDecision"=>{if let Some(tx)=decisions.lock().unwrap().remove(ipc::text(&command,"id")){let _=tx.send(command["accept"].as_bool().unwrap_or(false));}},
                    "clipboardSync"=>shared.scope(command["enabled"].as_bool(),None),
                    "clipboardActive"=>shared.scope(None,command["active"].as_bool()),
                    "clipboardSend"|"clipboardOffer"=>{if let Err(e)=shared.offer(&command).await{output.emit(json!({"kind":"clipboardError","message":e.to_string()})).await?;}},
                    "cancelTransfer" | "pauseTransfer" | "resumeTransfer" => {
                        if let Some(id) = command["requestID"].as_str().or_else(||command["id"].as_str()) { shared.control_transfer(id, command["kind"].as_str().unwrap()); }
                        else if command["kind"] == "cancelTransfer" { shared.abort(); }
                    },
                    "audio"=>audio_enabled.store(command["enabled"].as_bool().unwrap_or(false),Ordering::Release),
                    _=>if let Some(event)=input.command(&command){tokio::time::timeout(Duration::from_secs(5),sender.send(event)).await.context("RDP input timed out")?.map_err(|_|anyhow::anyhow!("RDP input channel closed"))?;},
                }
            },
            event=events.recv()=>{
                let Some(event)=event else {
                    output.emit(json!({"kind":"error","code":"rdpWorkerStopped","message":"RDP connection worker stopped unexpectedly. Reconnect or update the application."})).await?;
                    break;
                };
                match event {
                    RdpOutputEvent::Connected|RdpOutputEvent::AutoReconnected=>output.emit(json!({"kind":"connected","protocol":"rdp","codec":"raw","pixelFormat":"bgrx"})).await?,
                    RdpOutputEvent::Image{buffer,width,height}=>{
                        if dimensions!=(width.get(),height.get()) {
                            dimensions=(width.get(),height.get());
                            output.emit(json!({"kind":"desktopSize","width":width.get(),"height":height.get()})).await?;
                        }
                        output.frame(width.get(),height.get(),buffer)
                    },
                    RdpOutputEvent::ConnectionFailure(error)=>{output.emit(json!({"kind":"error","code":error.to_string(),"message":connection_error_message(&error)})).await?;break;},
                    RdpOutputEvent::Terminated(reason)=>{output.emit(json!({"kind":"disconnected","message":format!("{reason:?}")})).await?;break;},
                    RdpOutputEvent::AutoReconnecting{attempt,response,..}=>{output.emit(json!({"kind":"status","stage":format!("RDP 正在重新连接（{attempt}/3）")})).await?;let _=response.send(AutoReconnectDecision::Continue);},
                    _=>{},
                }
            },
            _=tick.tick()=>{
                let now=(traffic.received.load(Ordering::Relaxed),traffic.sent.load(Ordering::Relaxed));let elapsed=sampled.elapsed().as_secs_f64().max(0.001);
                output.emit(json!({"kind":"performance","receiveBytesPerSecond":(now.0-previous.0) as f64/elapsed,"sendBytesPerSecond":(now.1-previous.1) as f64/elapsed})).await?;
                if std::env::var_os("TERMPILOT_RDP_DIAGNOSTICS").is_some() {
                    output.emit(json!({"kind":"audioDiagnostic","receivedPackets":audio_statistics.received.load(Ordering::Relaxed),"forwardedPackets":audio_statistics.forwarded.load(Ordering::Relaxed),"mutedPackets":audio_statistics.muted.load(Ordering::Relaxed)})).await?;
                }
                previous=now;sampled=std::time::Instant::now();
            }
        }
    }
    shared.cancel();
    decisions.lock().unwrap().clear();
    sender.request_close();
    if tokio::time::timeout(
        Duration::from_secs(2),
        tokio::task::spawn_blocking(move || task.join()),
    )
    .await
    .is_err()
    {
        return Err(anyhow::anyhow!("RDP shutdown timed out"));
    }
    Ok(())
}
