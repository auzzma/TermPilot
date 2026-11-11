pub mod connection;
pub mod control;
pub mod crypto;
pub mod feedback;
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
pub mod file_fs;
#[cfg(windows)]
#[path = "file_fs_windows.rs"]
pub mod file_fs;
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android", windows))]
pub mod files;
pub mod media;
pub mod offers;
#[cfg(any(target_os = "macos", windows))]
pub mod broker;

#[cfg(any(target_os = "macos", windows))]
use broker::MediaSocket;
#[cfg(not(any(target_os = "macos", windows)))]
type MediaSocket = UdpSocket;

use crate::{
    ipc::{number, text},
    screen::{Output, Traffic},
};
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tokio::sync::mpsc;
#[cfg(not(any(target_os = "macos", windows)))]
use {std::net::Ipv4Addr, tokio::net::UdpSocket};
use tokio_util::sync::CancellationToken;

struct Tasks(Vec<tokio::task::JoinHandle<()>>);
impl Drop for Tasks {
    fn drop(&mut self) {
        for task in &self.0 {
            task.abort();
        }
    }
}
#[cfg(unix)]
async fn lock(config: &Value) -> Result<std::fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    let directory = std::path::Path::new(text(config, "lockDirectory"));
    ensure!(directory.is_absolute(), "Invalid screen lock directory");
    match std::fs::create_dir(directory) {
        Ok(()) => std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    let meta = std::fs::symlink_metadata(directory)?;
    ensure!(
        meta.is_dir() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o077 == 0,
        "Unsafe screen lock directory"
    );
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(directory.join("screen-sharing.lock"))?;
    let until = Instant::now() + Duration::from_secs(2);
    loop {
        match try_screen_lock(&file) {
            Ok(()) => return Ok(file),
            Err(std::fs::TryLockError::Error(error)) => return Err(error.into()),
            Err(std::fs::TryLockError::WouldBlock) => {
                ensure!(Instant::now() < until, "busy");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}
#[cfg(all(unix, not(target_os = "android")))]
fn try_screen_lock(file: &std::fs::File) -> Result<(), std::fs::TryLockError> {
    file.try_lock()
}
#[cfg(target_os = "android")]
fn try_screen_lock(file: &std::fs::File) -> Result<(), std::fs::TryLockError> {
    // Rust's std file-lock backend does not implement Android. Bionic supplies
    // flock; its lifetime follows this descriptor just like the desktop lock.
    use std::os::fd::AsRawFd;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::WouldBlock {
        Err(std::fs::TryLockError::WouldBlock)
    } else {
        Err(std::fs::TryLockError::Error(error))
    }
}
#[cfg(windows)]
async fn lock(config: &Value) -> Result<std::fs::File> {
    use std::os::windows::fs::OpenOptionsExt;
    let directory = file_fs::absolute(text(config, "lockDirectory"))?;
    std::fs::create_dir_all(&directory)?;
    let _guard = file_fs::open_source(&directory)?;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .share_mode(3)
        .custom_flags(0x00200000)
        .open(directory.join("screen-sharing.lock"))?;
    file.try_lock().map_err(|_| anyhow::anyhow!("busy"))?;
    Ok(file)
}
#[cfg(not(any(target_os = "macos", windows)))]
async fn udp(port: u16, address: SocketAddr) -> Result<Arc<UdpSocket>> {
    let socket = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port)).map_err(|e| {
        if e.kind() == std::io::ErrorKind::AddrInUse {
            anyhow::anyhow!("udpPortsInUse")
        } else {
            e.into()
        }
    })?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let bytes: libc::c_int = 4 * 1024 * 1024;
        unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_RCVBUF,
                (&bytes as *const libc::c_int).cast(),
                std::mem::size_of_val(&bytes) as libc::socklen_t,
            );
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawSocket;
        #[link(name = "ws2_32")]
        unsafe extern "system" {
            fn setsockopt(s: usize, level: i32, name: i32, value: *const u8, length: i32) -> i32;
        }
        let bytes: i32 = 4 * 1024 * 1024;
        unsafe {
            setsockopt(
                socket.as_raw_socket() as usize,
                0xffff,
                0x1002,
                (&bytes as *const i32).cast(),
                4,
            );
        }
    }
    socket.set_nonblocking(true)?;
    let socket = UdpSocket::from_std(socket)?;
    socket.connect(address).await?;
    Ok(Arc::new(socket))
}
async fn send(socket: &MediaSocket, data: &[u8], traffic: &Traffic) -> Result<()> {
    let n = socket.send(data).await?;
    traffic.sent.fetch_add(n as u64, Ordering::Relaxed);
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android", windows)))]
pub async fn run(
    _: Value,
    _: Output,
    _: mpsc::Receiver<Value>,
    _: Arc<Traffic>,
    _: CancellationToken,
) -> Result<()> {
    anyhow::bail!("highPerformancePlatformPending")
}
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android", windows))]
pub async fn run(
    mut config: Value,
    output: Output,
    mut commands: mpsc::Receiver<Value>,
    traffic: Arc<Traffic>,
    stop: CancellationToken,
) -> Result<()> {
    ensure!(config["proxy"].is_null(), "vncProxyUnsupported");
    let display = offers::DisplayMode::from_config(&config)?;
    let port = number(&config, "port", 5900);
    ensure!(
        (1..65535).contains(&port) && !text(&config, "username").is_empty(),
        "vncInvalidEndpoint"
    );
    #[cfg(not(any(target_os = "macos", windows)))]
    let _lock = lock(&config).await?;
    output.status("resolve").await?;
    let address = tokio::time::timeout(
        Duration::from_secs(10),
        tokio::net::lookup_host((text(&config, "host"), port as u16)),
    )
    .await
    .context("connectionTimeout")??
    .find(SocketAddr::is_ipv4)
    .context("IPv4 address required")?;
    output.status("udpBind").await?;
    #[cfg(any(target_os = "macos", windows))]
    let media_client = tokio::select! {
        _ = stop.cancelled() => return Ok(()),
        result = broker::connect(&config, address) => result?,
    };
    #[cfg(any(target_os = "macos", windows))]
    let (control, video, media_stop) = (media_client.control.clone(), media_client.video.clone(), media_client.closed.clone());
    #[cfg(any(target_os = "macos", windows))]
    output.emit(json!({"kind":"mediaTransport","transport":broker::TRANSPORT,"brokerPID":media_client.pid}), Vec::new()).await?;
    #[cfg(not(any(target_os = "macos", windows)))]
    let media_stop = CancellationToken::new();
    #[cfg(not(any(target_os = "macos", windows)))]
    let control = udp(port as u16, address).await?;
    #[cfg(not(any(target_os = "macos", windows)))]
    let video = udp(
        port as u16 + 1,
        SocketAddr::new(address.ip(), port as u16 + 1),
    )
    .await?;
    let (mut tasks, (wire, mut packets)) =
        (Tasks(Vec::new()), mpsc::channel::<(bool, Vec<u8>)>(2048));
    let stats = Arc::new(media::Stats::default());
    for (is_video, socket) in [(true, video.clone()), (false, control.clone())] {
        let wire = wire.clone();
        let traffic = traffic.clone();
        let stats = stats.clone();
        tasks.0.push(tokio::spawn(async move {
            let mut buffer = vec![0; 65536];
            loop {
                let n = match socket.recv(&mut buffer).await {
                    Ok(n) => n,
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::ConnectionRefused
                                | std::io::ErrorKind::ConnectionReset
                                | std::io::ErrorKind::Interrupted
                        ) =>
                    {
                        tokio::time::sleep(Duration::from_millis(10)).await;
                        continue;
                    }
                    Err(_) => break,
                };
                traffic.received.fetch_add(n as u64, Ordering::Relaxed);
                if n > 16384 {
                    stats.oversized_packets.fetch_add(1, Ordering::Relaxed);
                    stats.dropped.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
                if wire.try_send((is_video, buffer[..n].to_vec())).is_err() {
                    stats.receive_queue_drops.fetch_add(1, Ordering::Relaxed);
                    stats.dropped.fetch_add(1, Ordering::Relaxed);
                }
            }
        }));
    }
    drop(wire);
    let punch_stop = stop.child_token();
    let punch_token = punch_stop.clone();
    let (c, v, t) = (control.clone(), video.clone(), traffic.clone());
    tasks.0.push(tokio::spawn(async move{loop{let _=send(&c,&[0],&t).await;let _=send(&v,&[0],&t).await;tokio::select!{_=punch_token.cancelled()=>break,_=tokio::time::sleep(Duration::from_millis(100))=>{}}}}));
    let connection = tokio::select! {_=stop.cancelled()=>return Ok(()),_=media_stop.cancelled()=>anyhow::bail!("mediaBrokerDisconnected"),result=tokio::time::timeout(Duration::from_secs(80),async{connection::warmup(address).await;connection::connect(address,&config,&output,traffic.clone()).await})=>result.context("connectionTimeout")??};
    punch_stop.cancel();
    if let Some(Value::String(mut password)) =
        config.as_object_mut().and_then(|c| c.remove("password"))
    {
        use zeroize::Zeroize;
        password.zeroize();
    }
    let connection::Connection {
        mut reader,
        writer,
        keys,
        width,
        height,
        tiles,
        leftover,
    } = connection;
    ensure!(
        display.accepts_encoded(width, height, tiles),
        "displayMode"
    );
    let mut video_rx = crypto::Rtp::new(&*keys.video_server)?;
    let mut audio_rx = crypto::Rtp::new(&*keys.audio_server)?;
    let audio_tx = crypto::Rtp::new(&*keys.audio_viewer)?;
    let mut rtcp_tx = crypto::Rtcp::new(&*keys.video_viewer)?;
    let mut rtcp_rx = crypto::Rtcp::new(&*keys.video_server)?;
    let audio_enabled = Arc::new(AtomicBool::new(config["audio"].as_bool().unwrap_or(true)));
    let (media_tx, media_rx) = mpsc::channel(1024);
    let (feedback_tx, mut feedback_rx) = mpsc::channel(256);
    let codec = offers::VideoCodec::from_config(&config);
    let (o, a, s) = (output.clone(), audio_enabled.clone(), stats.clone());
    let mut decoder = tokio::task::spawn_blocking(move || {
        media::run(media_rx, feedback_tx, o, a, s, tiles as usize, codec)
    });
    output.status("video").await?;
    output
        .emit(
            json!({"kind":"connected","width":display.width,"height":display.height,"tiles":tiles,"videoCodec":codec.name(),"decoder":if codec == offers::VideoCodec::H264 {"Rust · H.264"} else if cfg!(any(windows, target_os="android", feature="portable-media-validation")) {"Rust · HEVC 4:4:4"} else {"Rust · VideoToolbox"}}),
            Vec::new(),
        )
        .await?;
    let writer = Arc::new(tokio::sync::Mutex::new(writer));
    let mut files = files::Files::new(writer.clone(), output.clone());
    let mut controls = control::Controls::for_display(display, tiles);
    for message in leftover {
        dispatch(&message, &mut controls, &mut files, &writer, &output).await?;
    }
    let mut interval = tokio::time::interval(Duration::from_millis(500));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut media_tick = tokio::time::interval(Duration::from_millis(10));
    media_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut tick = 0u64;
    let mut sources = Vec::new();
    let mut reports = HashMap::new();
    let mut last_fir = HashMap::new();
    let mut last_frame = 0;
    let mut frame_time = Instant::now();
    let mut video_time: Option<Instant> = None;
    let mut video_packets = 0u64;
    let mut decoder_finished = false;
    let result:Result<()>=async{loop{tokio::select!{
        _=stop.cancelled()=>break,
        _=media_stop.cancelled()=>anyhow::bail!("mediaBrokerDisconnected"),
        status=&mut decoder=>{decoder_finished=true;status??;break;},
        _=files.flush_pending()=>{},
        _=media_tick.tick()=>{let _=media_tx.try_send(media::Input::Tick);},
        message=reader.read(), if !files.is_backpressured()=>{dispatch(&message?,&mut controls,&mut files,&writer,&output).await?;},
        command=commands.recv()=>{let Some(command)=command else{break};
            if text(&command,"kind")=="credentialKey" {
                let acknowledgement=controls.credential_key(&command,&mut *writer.lock().await).await?;
                output.emit(acknowledgement,Vec::new()).await?;continue;
            }
            if controls.command(&command,&mut *writer.lock().await).await?{continue;}match text(&command,"kind"){
            "audio"=>audio_enabled.store(command["enabled"].as_bool()==Some(true),Ordering::Relaxed),
            "refresh"=>{let _=media_tx.try_send(media::Input::Refresh);},
            _=>{if let Err(error)=files.command(&command).await{let message=error.to_string();let code=if ["invalidPath","invalidName","expiredDrag","invalidRequest","tooManyFiles","unsupportedFileType"].contains(&message.as_str()){message.as_str()}else{"ioError"};output.emit(json!({"kind":"fileTransfer","requestID":command["requestID"],"stage":"failed","code":code}),Vec::new()).await?;}}
        }},
        packet=packets.recv()=>{let Some((video_packet,bytes))=packet else{anyhow::bail!(if cfg!(any(target_os="macos", windows)) {"mediaBrokerDisconnected"}else{"UDP receive channel closed"})};
            let message=if video_packet{video_rx.decrypt(&bytes)?.map(media::Input::Video)}else if bytes.len()>=2&&(192..=223).contains(&bytes[1]){if let Some(plain)=rtcp_rx.decrypt(&bytes)?{feedback::received_reports(&plain,&mut reports);}None}else{audio_rx.decrypt(&bytes)?.map(|p|media::Input::Audio(p.payload))};
            if let Some(message)=message{if video_packet{video_time=Some(Instant::now());video_packets+=1;}
                if media_tx.try_send(message).is_err(){stats.decode_queue_drops.fetch_add(1,Ordering::Relaxed);stats.dropped.fetch_add(1,Ordering::Relaxed);}}
        },
        event=feedback_rx.recv()=>{if let Some(event)=event{match event{
            media::Feedback::Sources(new)=>{sources=new;last_fir.retain(|s,_|sources.contains(s));reports.retain(|s,_|sources.contains(s));},
            event @ (media::Feedback::Fir(_) | media::Feedback::Refresh)=>for target in match event {media::Feedback::Fir(targets)=>targets,_=>sources.clone()}{if last_fir.get(&target).is_some_and(|at:&Instant|at.elapsed()<Duration::from_millis(250)){continue;}last_fir.insert(target,Instant::now());send(&control,&rtcp_tx.encrypt(&feedback::fir(keys.video_ssrc,target,tick as u8))?,&traffic).await?;},
            media::Feedback::Nack(target,missing)=>{send(&control,&rtcp_tx.encrypt(&feedback::nack(keys.video_ssrc,target,&missing))?,&traffic).await?;},
            media::Feedback::Ack(donl)=>{send(&video,&rtcp_tx.encrypt(&feedback::ack(keys.video_ssrc,donl))?,&traffic).await?;}
        }}},
        _=interval.tick()=>{
            tick+=1;send(&control,&audio_tx.encrypt(keys.audio_ssrc,tick,(tick*480)as u32,&[0,0x68,0x34,0])?,&traffic).await?;
            let sequences=video_rx.sequences().into_iter().filter(|(s,_)|sources.contains(s)).collect::<Vec<_>>();send(&control,&rtcp_tx.encrypt(&feedback::report(keys.video_ssrc,&sequences,&reports,tick.is_multiple_of(10)))?,&traffic).await?;
            if tick>4{writer.lock().await.send(&offers::framebuffer(true,false)).await?;}files.tick().await?;
            // Apple stops encoding an unchanged screen. Request recovery only
            // when authenticated video is still arriving without decoded output.
            let frames=stats.frames.load(Ordering::Relaxed);if frames!=last_frame{last_frame=frames;frame_time=Instant::now();}else if frame_time.elapsed()>Duration::from_secs(2)&&video_time.is_some_and(|at|at.elapsed()<Duration::from_secs(1)){let _=media_tx.try_send(media::Input::Refresh);}
            if tick.is_multiple_of(2){output.emit(json!({"kind":"mediaDiagnostics","videoCodec":codec.name(),"nativeDecoder":stats.native_decoder_name(),"nativeSubmitted":stats.native_submitted.load(Ordering::Relaxed),"nativeOutputs":stats.native_outputs.load(Ordering::Relaxed),"nativeColorFormat":stats.native_color.load(Ordering::Relaxed),"frames":frames,"decodeErrors":stats.errors.load(Ordering::Relaxed),"lastVideoDecodeError":stats.last_video_error.load(Ordering::Relaxed),"audioDecodeErrors":stats.audio_errors.load(Ordering::Relaxed),"audioFrames":stats.audio_frames.load(Ordering::Relaxed),"dropped":stats.dropped.load(Ordering::Relaxed),"receiveQueueDrops":stats.receive_queue_drops.load(Ordering::Relaxed),"decodeQueueDrops":stats.decode_queue_drops.load(Ordering::Relaxed),"oversizedPackets":stats.oversized_packets.load(Ordering::Relaxed),"assemblyDrops":stats.assembly_drops.load(Ordering::Relaxed),"lateUnits":stats.late_units.load(Ordering::Relaxed),"missingUnits":stats.missing_units.load(Ordering::Relaxed),"codecQueueDrops":stats.codec_queue_drops.load(Ordering::Relaxed),"recoverySkips":stats.recovery_skips.load(Ordering::Relaxed),"overloadRecoveries":stats.overload_recoveries.load(Ordering::Relaxed),"decoderResets":stats.decoder_resets.load(Ordering::Relaxed),"decodeMicros":stats.decode_micros.load(Ordering::Relaxed),"decodeCalls":stats.decode_calls.load(Ordering::Relaxed),"maxDecodeMicros":stats.max_decode_micros.load(Ordering::Relaxed),"maxQueueMicros":stats.max_queue_micros.load(Ordering::Relaxed),"maxCodecQueueBytes":stats.max_codec_queue_bytes.load(Ordering::Relaxed),"sources":sources.len(),"parameters":stats.parameters.load(Ordering::Relaxed),"units":stats.units.load(Ordering::Relaxed),"videoPackets":video_packets,"videoIdleSeconds":video_time.map(|at|at.elapsed().as_secs_f64()),"frameIdleSeconds":frame_time.elapsed().as_secs_f64(),"nalTypes":stats.nal_types.load(Ordering::Relaxed)}),Vec::new()).await?;}
        }
    }}Ok(())}.await;
    files.close().await;
    let _ = controls.release(&mut *writer.lock().await).await;
    writer.lock().await.close().await;
    drop(tasks);
    drop(media_tx);
    if !decoder_finished {
        let _ = tokio::time::timeout(Duration::from_secs(3), decoder).await;
    }
    #[cfg(any(target_os = "macos", windows))]
    media_client.close().await;
    result
}

#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android", windows))]
async fn dispatch(
    message: &[u8],
    controls: &mut control::Controls,
    files: &mut files::Files,
    writer: &Arc<tokio::sync::Mutex<connection::Writer>>,
    output: &Output,
) -> Result<()> {
    if !controls.clipboard_in_progress() {
        if let Some(unrelated) = files.message(message).await? {
            for message in unrelated {
                controls
                    .message(&message, &mut *writer.lock().await, output)
                    .await?;
            }
            return Ok(());
        }
    }
    controls
        .message(message, &mut *writer.lock().await, output)
        .await?;
    Ok(())
}
