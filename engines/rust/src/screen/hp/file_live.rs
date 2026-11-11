//! Ignored integration test. The harness supplies saved-host credentials over
//! private stdin and creates/removes a dedicated remote test directory.
use super::*;
use crate::screen::{
    hp::{connection, control::Controls, crypto, feedback},
    Traffic,
};
use sha2::Digest;
use std::io::{Read, Write};

struct Live {
    files: Files,
    reader: connection::Reader,
    writer: SharedWriter,
    controls: Controls,
    events: mpsc::Receiver<crate::screen::Packet>,
    output: Output,
    control: Arc<tokio::net::UdpSocket>,
    _video: Arc<tokio::net::UdpSocket>,
    audio: crypto::Rtp,
    rtcp: crypto::Rtcp,
    audio_ssrc: u32,
    video_ssrc: u32,
    tick: u64,
    drains: Vec<tokio::task::JoinHandle<()>>,
}
impl Live {
    // Synthetic drag announcements must be inserted between complete native
    // records. After cancellation the socket can still contain the remainder
    // of a file record; a real peer serializes its next drag after that record.
    async fn synthetic_message(&mut self, message: &[u8]) -> Result<()> {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
        while !self.files.wire.buffer.is_empty() {
            ensure!(
                tokio::time::Instant::now() < deadline,
                "Incomplete record after cancellation"
            );
            if let Ok(result) = tokio::time::timeout(Duration::from_secs(1), self.next()).await {
                result?;
            }
        }
        self.files.message(message).await?;
        Ok(())
    }
    async fn next(&mut self) -> Result<crate::screen::Packet> {
        loop {
            tokio::select! {
                event=self.events.recv()=>return event.context("Event channel closed"),
                _=self.files.flush_pending()=>{},
                message=self.reader.read(), if !self.files.is_backpressured()=>{let message=message?;if !self.controls.clipboard_in_progress(){if let Some(other)=self.files.message(&message).await?{for m in other{self.controls.message(&m,&mut *self.writer.lock().await,&self.output).await?;}continue;}}self.controls.message(&message,&mut *self.writer.lock().await,&self.output).await?;},
                _=tokio::time::sleep(Duration::from_millis(300))=>{self.tick+=1;self.control.send(&self.audio.encrypt(self.audio_ssrc,self.tick,self.tick as u32*480,&[0,0x68,0x34,0])?).await?;self.control.send(&self.rtcp.encrypt(&feedback::report(self.video_ssrc,&[],&HashMap::new(),self.tick.is_multiple_of(10)))?).await?;}
            }
        }
    }
    async fn transfers(&mut self, requests: &[String]) -> Result<()> {
        let mut done = std::collections::HashSet::new();
        let until = tokio::time::Instant::now() + Duration::from_secs(600);
        while done.len() < requests.len() {
            let packet = tokio::time::timeout_at(until, self.next())
                .await
                .context("File transfer timeout")??;
            let h = packet.header;
            if h["kind"] == "fileTransferDiagnostic" {
                eprintln!("native integrity: {}", text(&h, "message"));
            }
            if h["kind"] == "fileTransfer" {
                let id = text(&h, "requestID");
                if requests.iter().any(|r| r == id) {
                    ensure!(
                        !["failed", "cancelled"].contains(&text(&h, "stage")),
                        "File transfer failed: {}",
                        text(&h, "code")
                    );
                    if h["stage"] == "completed" {
                        done.insert(id.to_string());
                    }
                }
            }
        }
        Ok(())
    }
    async fn pause_resume_transfer(
        &mut self,
        request: &str,
        seconds: u64,
        cancel: bool,
    ) -> Result<()> {
        loop {
            let p = tokio::time::timeout(Duration::from_secs(30), self.next()).await??;
            if p.header["requestID"] != request {
                continue;
            }
            ensure!(
                !["failed", "cancelled", "completed"].contains(&text(&p.header, "stage")),
                "Transfer ended before pause: {}",
                text(&p.header, "stage")
            );
            if p.header["completedBytes"].as_u64().unwrap_or(0) > 0 {
                break;
            }
        }
        self.files
            .command(&json!({"kind":"filePause","requestID":request}))
            .await?;
        let job = self
            .files
            .shared
            .queued
            .lock()
            .unwrap()
            .get(request)
            .context("Missing paused job")?
            .clone();
        let until = tokio::time::Instant::now() + Duration::from_secs(seconds);
        let mut settled = None;
        while tokio::time::Instant::now() < until {
            match tokio::time::timeout(Duration::from_secs(1), self.next()).await {
                Ok(Ok(p)) if p.header["requestID"] == request => {
                    ensure!(
                        !["failed", "cancelled", "completed"].contains(&text(&p.header, "stage")),
                        "Paused transfer ended: {} {}",
                        text(&p.header, "stage"),
                        text(&p.header, "code")
                    );
                }
                Ok(Err(e)) => return Err(e),
                _ => {}
            }
            if until.saturating_duration_since(tokio::time::Instant::now())
                < Duration::from_secs(seconds.saturating_sub(1))
            {
                let bytes = job.completed.load(Ordering::Relaxed);
                if let Some(previous) = settled {
                    ensure!(bytes == previous, "Paused byte count changed");
                } else {
                    settled = Some(bytes);
                }
            }
        }
        self.files
            .command(
                &json!({"kind":if cancel {"fileCancel"}else{"fileResume"},"requestID":request}),
            )
            .await?;
        if cancel {
            loop {
                let p = tokio::time::timeout(Duration::from_secs(10), self.next()).await??;
                if p.header["requestID"] == request && p.header["stage"] == "cancelled" {
                    break;
                }
            }
        } else {
            self.transfers(&[request.to_string()]).await?;
        }
        eprintln!(
            "native transfer {} after {} second pause: passed",
            if cancel { "cancel" } else { "resume" },
            seconds
        );
        Ok(())
    }
    async fn fetch_clipboard(&mut self, id: &str) -> Result<Option<String>> {
        self.controls
            .command(
                &json!({"kind":"clipboardFetch","requestID":id}),
                &mut *self.writer.lock().await,
            )
            .await?;
        let until = tokio::time::Instant::now() + Duration::from_secs(15);
        loop {
            let packet = tokio::time::timeout_at(until, self.next()).await??;
            if packet.header["kind"] == "clipboard" && packet.header["requestID"] == id {
                return if packet.header["hasText"] == true {
                    Ok(Some(String::from_utf8(packet.payload)?))
                } else {
                    Ok(None)
                };
            }
        }
    }
}
impl Drop for Live {
    fn drop(&mut self) {
        for task in &self.drains {
            task.abort();
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "requires authorized remote Mac; credentials arrive only on private stdin"]
async fn production_native_files() -> Result<()> {
    let raw = tokio::task::spawn_blocking(|| {
        let mut raw = zeroize::Zeroizing::new(String::new());
        std::io::stdin()
            .take(1024 * 1024)
            .read_to_string(&mut raw)?;
        Ok::<_, anyhow::Error>(raw)
    })
    .await??;
    let config: Value = serde_json::from_str(&raw)?;
    let remote = text(&config, "remote_directory");
    let local = fs::absolute(text(&config, "local_directory"))?;
    ensure!(
        remote.starts_with("/private/tmp/TermPilot-Rust-Native-") && local.is_dir(),
        "Invalid test directory"
    );
    let address = tokio::net::lookup_host((text(&config, "host"), 5900))
        .await?
        .find(std::net::SocketAddr::is_ipv4)
        .context("IPv4 address")?;
    let control = Arc::new(tokio::net::UdpSocket::bind("0.0.0.0:5900").await?);
    let video = Arc::new(tokio::net::UdpSocket::bind("0.0.0.0:5901").await?);
    control.connect(address).await?;
    video
        .connect(std::net::SocketAddr::new(address.ip(), 5901))
        .await?;
    let mut drains = Vec::new();
    for socket in [control.clone(), video.clone()] {
        drains.push(tokio::spawn(async move {
            let mut b = vec![0; 65536];
            loop {
                if socket.recv(&mut b).await.is_err() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            }
        }));
    }
    let punch = {
        let (c, v) = (control.clone(), video.clone());
        tokio::spawn(async move {
            loop {
                let _ = c.send(&[0]).await;
                let _ = v.send(&[0]).await;
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
    };
    let (events, mut initial) = mpsc::channel::<crate::screen::Packet>(128);
    let (relay, receiver) = mpsc::channel(128);
    drains.push(tokio::spawn(async move {
        while let Some(packet) = initial.recv().await {
            if packet.header["kind"] == "status" || packet.header["kind"] == "fileTransfer" {
                eprintln!(
                    "native test: {} {} {}",
                    text(&packet.header, "kind"),
                    text(&packet.header, "stage"),
                    text(&packet.header, "code")
                );
            }
            if relay.send(packet).await.is_err() {
                break;
            }
        }
    }));
    let (audio, _sounds) = mpsc::channel(4);
    let output = Output {
        events,
        audio,
        video: Arc::default(),
    };
    connection::warmup(address).await;
    let connection = tokio::time::timeout(
        Duration::from_secs(80),
        connection::connect(address, &config, &output, Arc::new(Traffic::default())),
    )
    .await
    .context("Native test handshake timeout")??;
    punch.abort();
    let writer = Arc::new(Mutex::new(connection.writer));
    let files = Files::new(writer.clone(), output.clone());
    let mut live = Live {
        files,
        reader: connection.reader,
        writer,
        controls: Controls::new(),
        events: receiver,
        output,
        control,
        _video: video,
        audio: crypto::Rtp::new(&*connection.keys.audio_viewer)?,
        rtcp: crypto::Rtcp::new(&*connection.keys.video_viewer)?,
        audio_ssrc: connection.keys.audio_ssrc,
        video_ssrc: connection.keys.video_ssrc,
        tick: 0,
        drains,
    };
    for message in connection.leftover {
        live.controls
            .message(&message, &mut *live.writer.lock().await, &live.output)
            .await?;
    }
    let result:Result<Value>=async{
        let source=local.join("上传-中文");std::fs::create_dir(&source)?;std::fs::create_dir(source.join("空目录"))?;let data=(0..2*1024*1024+137).map(|n|(n%251)as u8).collect::<Vec<_>>();std::fs::write(source.join("数据.bin"),&data)?;std::fs::write(source.join("空文件.txt"),b"")?;
        let file=fs::open_source(&source.join("数据.bin"))?;let resource=(0..65536+23).map(|n|(n%239)as u8).collect::<Vec<_>>();fs::set_attribute(&file,fs::RESOURCE,&resource,0)?;
        let mut finder=[0u8;32];finder[..8].copy_from_slice(b"TEXTttxt");fs::set_attribute(&file,fs::FINDER,&finder,0)?;
        let small_files=config["small_files"].as_u64().unwrap_or(0);ensure!(small_files<=10000,"Too many test files");
        let mut small_sources=Vec::new();
        for n in 0..small_files {
            let relative=PathBuf::from(format!("目录-{:02}/文件-{:04}.txt",n/100,n));
            std::fs::create_dir_all(source.join(relative.parent().unwrap()))?;
            let mut contents=vec![0u8;1024];rand::RngCore::fill_bytes(&mut rand::thread_rng(),&mut contents);
            std::fs::write(source.join(&relative),&contents)?;small_sources.push((relative,contents));
        }
        live.files.command(&json!({"kind":"dragEnter","paths":[source]})).await?;live.files.command(&json!({"kind":"dragDrop"})).await?;
        let pending=live.files.pending.as_ref().context("Missing pending drag")?;let sid=pending.sid;let ids=pending.ids.iter().flatten().cloned().collect::<Vec<_>>();
        // Exercise the exact production destination callback after explicit
        // drop, with a synthetic destination envelope (no OS gesture claim).
        let mut destination=vec![0x1e,0,0,0];destination.extend(sid.to_be_bytes());put_bytes(&mut destination,remote.as_bytes());live.files.message(&destination).await?;live.transfers(&ids).await?;
        let remote_source=format!("{remote}/上传-中文");let announce=drag_archive(std::slice::from_ref(&remote_source),rand::random::<u32>().max(1))?;live.files.message(&announce).await?;
        let download=local.join("下载-中文");let request=uuid::Uuid::new_v4().to_string();live.files.command(&json!({"kind":"fileDownload","requestID":request,"source":remote_source,"destination":download})).await?;live.transfers(std::slice::from_ref(&request)).await?;
        ensure!(download.join("空目录").is_dir()&&std::fs::metadata(download.join("空文件.txt"))?.len()==0,"Empty item mismatch");let received=std::fs::read(download.join("数据.bin"))?;ensure!(received==data,"Native file hash mismatch");let received_file=fs::open_source(&download.join("数据.bin"))?;ensure!(fs::attribute(&received_file,fs::RESOURCE,65536+23,0)?==resource,"Resource fork mismatch");ensure!(fs::attribute(&received_file,fs::FINDER,32,0)?==finder,"FinderInfo mismatch");
        for (relative,contents) in &small_sources { ensure!(std::fs::read(download.join(relative))?==*contents,"Small-file download content mismatch"); }
        // Exercise a much larger incompressible file as well as the small
        // compressed fixture. This catches wire/summary errors hidden by text.
        let large_source=local.join("native-large.pkg");
        let large_bytes=config["large_bytes"].as_u64().unwrap_or(32*1024*1024+37);
        let mut block=vec![0u8;1024*1024];let mut remaining=large_bytes;
        let mut expected=sha2::Sha256::new();let mut source_file=std::fs::File::create(&large_source)?;
        while remaining>0 {
            let length=remaining.min(block.len()as u64)as usize;
            rand::RngCore::fill_bytes(&mut rand::thread_rng(),&mut block[..length]);
            source_file.write_all(&block[..length])?;expected.update(&block[..length]);remaining-=length as u64;
        }
        source_file.sync_all()?;drop(source_file);
        let expected=expected.finalize();
        live.files.command(&json!({"kind":"dragEnter","paths":[large_source]})).await?;
        live.files.command(&json!({"kind":"dragDrop"})).await?;
        let pending=live.files.pending.as_ref().context("Missing large drag")?;
        let ids=pending.ids.iter().flatten().cloned().collect::<Vec<_>>();
        let mut destination=vec![0x1e,0,0,0];destination.extend(pending.sid.to_be_bytes());put_bytes(&mut destination,remote.as_bytes());
        let upload_started=Instant::now();
        live.files.message(&destination).await?;
        if let Some(seconds) = config["pause_seconds"].as_u64() { live.pause_resume_transfer(&ids[0], seconds, false).await?; }
        else { live.transfers(&ids).await?; }
        let upload_seconds=upload_started.elapsed().as_secs_f64();
        let large_remote=format!("{remote}/native-large.pkg");
        live.files.message(&drag_archive(std::slice::from_ref(&large_remote),rand::random::<u32>().max(1))?).await?;
        let large_download=local.join("large-download.pkg");let large_request=uuid::Uuid::new_v4().to_string();
        let download_started=Instant::now();
        live.files.command(&json!({"kind":"fileDownload","requestID":large_request,"source":large_remote,"destination":large_download})).await?;
        if let Some(seconds) = config["pause_seconds"].as_u64() { live.pause_resume_transfer(&large_request, seconds, false).await?; }
        else { live.transfers(std::slice::from_ref(&large_request)).await?; }
        let download_seconds=download_started.elapsed().as_secs_f64();
        let mut received_hash=sha2::Sha256::new();let mut received_file=std::fs::File::open(&large_download)?;
        loop { let count=received_file.read(&mut block)?;if count==0 { break; } received_hash.update(&block[..count]); }
        ensure!(received_hash.finalize()==expected,"Large-file download content mismatch");
        if config["pause_seconds"].is_number() {
            let cancelled = local.join("cancelled-download.pkg");
            let id = uuid::Uuid::new_v4().to_string();
            live.files.command(&json!({"kind":"fileDownload","requestID":id,"source":large_remote,"destination":cancelled})).await?;
            live.pause_resume_transfer(&id, 2, true).await?;
            tokio::time::sleep(Duration::from_millis(100)).await;
            ensure!(!cancelled.exists(), "Cancelled download was published");
        }
        // A single-file Finder promise uses a different summary envelope than
        // a directory. Exercise it separately, including the resource fork.
        let single_source=format!("{remote}/上传-中文/数据.bin");
        live.synthetic_message(&drag_archive(std::slice::from_ref(&single_source),rand::random::<u32>().max(1))?).await?;
        let single_download=local.join("single.bin");let single_request=uuid::Uuid::new_v4().to_string();
        live.files.command(&json!({"kind":"fileDownload","requestID":single_request,"source":single_source,"destination":single_download})).await?;
        live.transfers(std::slice::from_ref(&single_request)).await?;
        ensure!(std::fs::read(&single_download)?==data,"Single-file download content mismatch");
        let empty_source=format!("{remote}/上传-中文/空文件.txt");
        live.files.message(&drag_archive(std::slice::from_ref(&empty_source),rand::random::<u32>().max(1))?).await?;
        let empty_download=local.join("empty.txt");let empty_request=uuid::Uuid::new_v4().to_string();
        live.files.command(&json!({"kind":"fileDownload","requestID":empty_request,"source":empty_source,"destination":empty_download})).await?;
        live.transfers(std::slice::from_ref(&empty_request)).await?;
        ensure!(std::fs::metadata(&empty_download)?.len()==0,"Empty single-file download mismatch");
        live.controls.command(&json!({"kind":"clipboardSync","enabled":true}),&mut *live.writer.lock().await).await?;
        let saved=live.fetch_clipboard("before").await?;let value="TermPilot Rust 双向剪切板验证 📋\n";
        live.controls.command(&json!({"kind":"clipboardSend","text":value}),&mut *live.writer.lock().await).await?;
        let clipboard_result=live.fetch_clipboard("after").await;
        if let Some(saved)=saved{live.controls.command(&json!({"kind":"clipboardSend","text":saved}),&mut *live.writer.lock().await).await?;}
        ensure!(clipboard_result?.as_deref()==Some(value),"Clipboard roundtrip mismatch");
        Ok(json!({"passed":true,"production_engine":true,"small_file_count":small_files,"performance":{"bytes":large_bytes,"upload_seconds":upload_seconds,"download_seconds":download_seconds,"includes_pause":config["pause_seconds"].is_number()},"data_bytes":data.len(),"resource_fork_bytes":resource.len(),"sha256":hex::encode(sha2::Sha256::digest(&data)),"transfer_controls":config["pause_seconds"].as_u64().map(|seconds|json!({"upload_pause_seconds":seconds,"download_pause_seconds":seconds,"paused_bytes_stable":true,"resumed_contents_match":true,"paused_cancel":true,"transfer_after_cancel":true})),"checks":["Native upload directory","Native compressed download","Incompressible file upload/download","Single-file download with resource fork","Chinese names","Empty directory/file","SHA256 roundtrip","ResourceFork","FinderInfo","Remote UTF-8 clipboard send/fetch"],"scope":"Production wire/state machine; synthetic drag destination, OS gestures require native UI acceptance"}))
    }.await;
    live.files.close().await;
    live.writer.lock().await.close().await;
    let report = result?;
    std::fs::write(
        text(&config, "report_path"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    Ok(())
}
