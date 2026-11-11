//! Opt-in Apple codec negotiation probe. Not linked into shipped applications.
//! Uses the production SRP/control/SRTP implementation. Authenticated compressed
//! packets go only to private stdout for an in-memory validator; no keys, pixels,
//! clipboard content or remote input are written to disk or sent by this probe.
//! H.264 bank parameters follow the AGPL iShareScreen revision in UPSTREAM.
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::{Duration, Instant},
};
use termpilot_engine::screen::hp::{crypto, feedback};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    net::UdpSocket,
    sync::mpsc,
};

mod ipc {
    pub use termpilot_engine::ipc::text;
}
mod screen {
    pub use termpilot_engine::screen::{apple, Counted, Traffic};
    pub struct Output;
    impl Output {
        pub async fn status(&self, _stage: &str) -> anyhow::Result<()> {
            Ok(())
        }
    }
}
#[path = "../src/screen/hp/connection.rs"]
mod connection;

mod offers {
    use anyhow::{ensure, Result};
    use flate2::{read::ZlibDecoder, write::ZlibEncoder, Compression};
    use std::io::{Read, Write};
    use termpilot_engine::screen::hp::offers as base;
    pub use termpilot_engine::screen::hp::offers::{
        encodings, framebuffer, viewer_info, virtual_display, DisplayMode, VideoCodec,
    };

    pub struct Keys(base::Keys);
    pub static REPORTED_TILES: std::sync::atomic::AtomicU64 =
        std::sync::atomic::AtomicU64::new(u64::MAX);
    impl std::ops::Deref for Keys {
        type Target = base::Keys;
        fn deref(&self) -> &Self::Target {
            &self.0
        }
    }
    fn varint(mut n: u64, out: &mut Vec<u8>) {
        while n > 127 {
            out.push(n as u8 | 128);
            n >>= 7;
        }
        out.push(n as u8);
    }
    fn num(out: &mut Vec<u8>, f: u64, n: u64) {
        varint(f << 3, out);
        varint(n, out);
    }
    fn bytes(out: &mut Vec<u8>, f: u64, b: &[u8]) {
        varint(f << 3 | 2, out);
        varint(b.len() as u64, out);
        out.extend(b);
    }
    fn fields(pairs: &[(u64, u64)]) -> Vec<u8> {
        let mut b = vec![];
        for &(f, n) in pairs {
            num(&mut b, f, n);
        }
        b
    }
    fn read(data: &[u8], at: &mut usize) -> Result<u64> {
        let mut n = 0;
        for shift in (0..63).step_by(7) {
            ensure!(*at < data.len(), "probe varint");
            let b = data[*at];
            *at += 1;
            n |= ((b & 127) as u64) << shift;
            if b & 128 == 0 {
                return Ok(n);
            }
        }
        anyhow::bail!("probe varint")
    }
    fn proto(data: &[u8], field: u64) -> Result<(u64, Option<&[u8]>)> {
        let mut at = 0;
        while at < data.len() {
            let tag = read(data, &mut at)?;
            match tag & 7 {
                0 => {
                    let v = read(data, &mut at)?;
                    if tag >> 3 == field {
                        return Ok((v, None));
                    }
                }
                2 => {
                    let n = read(data, &mut at)? as usize;
                    ensure!(n <= data.len() - at, "probe protobuf");
                    if tag >> 3 == field {
                        return Ok((0, Some(&data[at..at + n])));
                    }
                    at += n;
                }
                1 => at += 8,
                5 => at += 4,
                _ => anyhow::bail!("probe protobuf"),
            }
        }
        Ok((0, None))
    }
    pub fn dimensions_for_codec(message: &[u8], _: VideoCodec) -> Result<Option<(u16, u16, u16)>> {
        dimensions(message)
    }
    pub fn dimensions(message: &[u8]) -> Result<Option<(u16, u16, u16)>> {
        let result = base::dimensions(message);
        if let Ok(Some((_, _, tiles))) = result {
            REPORTED_TILES.store(tiles as u64, std::sync::atomic::Ordering::Relaxed);
        }
        if result.is_err() {
            // Diagnose only non-secret dimensions. Do not export a media answer,
            // whose other fields can contain session keys.
            for (start, _) in message
                .windows(8)
                .enumerate()
                .filter(|(_, b)| *b == b"bplist00")
            {
                for end in start + 40..=message.len() {
                    let Ok(value) =
                        plist::Value::from_reader(std::io::Cursor::new(&message[start..end]))
                    else {
                        continue;
                    };
                    let Some(blob) = value
                        .as_dictionary()
                        .and_then(|d| d.get("avcMediaStreamNegotiatorMediaBlob"))
                        .and_then(|v| v.as_data())
                    else {
                        continue;
                    };
                    let mut decoded = vec![];
                    ZlibDecoder::new(blob)
                        .take(1048577)
                        .read_to_end(&mut decoded)?;
                    ensure!(decoded.len() <= 1048576, "probe protobuf size");
                    if let Some(desc) = proto(&decoded, 5)?.1 {
                        let (w, h, tiles) =
                            (proto(desc, 4)?.0, proto(desc, 5)?.0, proto(desc, 6)?.0);
                        REPORTED_TILES.store(tiles, std::sync::atomic::Ordering::Relaxed);
                        eprintln!("Probe canvas: width={} height={} tiles={}", w, h, tiles);
                        // The real H.264 one-picture answer omits tile count.
                        // Use the explicit request only for this opt-in case;
                        // the validator must verify actual full-size AVC output.
                        if std::env::var("TERMPILOT_CODEC_PROBE").as_deref() == Ok("h264")
                            && std::env::var("TERMPILOT_CODEC_TILES").as_deref() == Ok("1")
                            && tiles == 0
                            && (1..=8192).contains(&w)
                            && (1..=8192).contains(&h)
                            && w * h <= 16_777_216
                        {
                            return Ok(Some((w as u16, h as u16, 1)));
                        }
                    }
                    break;
                }
            }
        }
        result
    }
    impl Keys {
        pub fn new() -> Self {
            Self(base::Keys::new())
        }
        pub fn message_for_codec(&self, _: VideoCodec) -> Result<Vec<u8>> {
            self.message()
        }
        pub fn message(&self) -> Result<Vec<u8>> {
            let original = self.0.message()?;
            if std::env::var("TERMPILOT_CODEC_PROBE").as_deref() != Ok("h264") {
                return Ok(original);
            }
            let audio_len = u16::from_be_bytes(original[10..12].try_into()?) as usize;
            let video_start = 0x80 + audio_len + 92;
            let mut plist =
                plist::Value::from_reader(std::io::Cursor::new(&original[video_start..]))?;
            let dict = plist.as_dictionary_mut().unwrap();
            let mut proto = vec![];
            ZlibDecoder::new(dict["avcMediaStreamNegotiatorMediaBlob"].as_data().unwrap())
                .read_to_end(&mut proto)?;
            // Only replace VideoSettings; preserve all audio tiers and metadata.
            let res = fields(&[(1, 1), (2, 1), (3, 50115), (4, 0)]);
            let alt = fields(&[(1, 1), (2, 2), (3, 50115), (4, 0)]);
            let mut bank = fields(&[(1, 123)]);
            for r in [&res, &alt, &res, &alt] {
                bytes(&mut bank, 2, r);
            }
            bytes(
                &mut bank,
                3,
                b"FLS;MS:-1;LF:-1;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;",
            );
            num(&mut bank, 4, 1);
            let tiles = std::env::var("TERMPILOT_CODEC_TILES")
                .unwrap_or_else(|_| "1".into())
                .parse::<u64>()?;
            ensure!([1, 4].contains(&tiles), "probe tile count");
            let mut desc = fields(&[(1, self.video_ssrc as u64), (2, 0)]);
            bytes(&mut desc, 3, &bank);
            desc.extend(fields(&[(6, tiles), (7, 0), (8, 63), (9, 1), (12, 1)]));
            let mut changed = vec![];
            let mut at = 0;
            let mut replaced = false;
            while at < proto.len() {
                let start = at;
                let tag = read(&proto, &mut at)?;
                match tag & 7 {
                    0 => {
                        read(&proto, &mut at)?;
                    }
                    2 => {
                        let len = read(&proto, &mut at)? as usize;
                        at += len;
                    }
                    _ => anyhow::bail!("probe wire type"),
                }
                ensure!(at <= proto.len(), "probe bounds");
                if tag >> 3 == 5 {
                    bytes(&mut changed, 5, &desc);
                    replaced = true;
                } else {
                    changed.extend(&proto[start..at]);
                }
            }
            ensure!(replaced, "probe video settings");
            let mut zipped = ZlibEncoder::new(vec![], Compression::default());
            zipped.write_all(&changed)?;
            dict.insert(
                "avcMediaStreamNegotiatorMediaBlob".into(),
                plist::Value::Data(zipped.finish()?),
            );
            let mut video = vec![];
            plist.to_writer_binary(&mut video)?;
            let mut out = original[..video_start].to_vec();
            out[12..14].copy_from_slice(&(video.len() as u16).to_be_bytes());
            out.extend(video);
            let size = (out.len() - 4) as u16;
            out[2..4].copy_from_slice(&size.to_be_bytes());
            Ok(out)
        }
    }
}

async fn emit(out: &mut tokio::io::Stdout, mut header: Value, payload: &[u8]) -> Result<()> {
    header["payloadLength"] = json!(payload.len());
    let h = serde_json::to_vec(&header)?;
    out.write_u32(h.len() as u32).await?;
    out.write_all(&h).await?;
    out.write_all(payload).await?;
    Ok(())
}
#[tokio::main]
async fn main() -> Result<()> {
    let cfg = termpilot_engine::ipc::read_json(&mut BufReader::new(tokio::io::stdin()))
        .await?
        .ok_or_else(|| anyhow::anyhow!("Missing private configuration"))?;
    let codec = std::env::var("TERMPILOT_CODEC_PROBE")?;
    ensure!(
        ["h264", "hevc"].contains(&codec.as_str()),
        "Select h264 or hevc explicitly"
    );
    let seconds = cfg["seconds"].as_u64().unwrap_or(20).clamp(5, 60);
    let address: SocketAddr = format!("{}:5900", ipc::text(&cfg, "host")).parse()?;
    let control = Arc::new(UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 5900)).await?);
    let video = Arc::new(UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 5901)).await?);
    control.connect(address).await?;
    video.connect(SocketAddr::new(address.ip(), 5901)).await?;
    let (tx, mut rx) = mpsc::channel(8192);
    let mut tasks = vec![];
    for (is_video, socket) in [(true, video.clone()), (false, control.clone())] {
        let tx = tx.clone();
        tasks.push(tokio::spawn(async move {
            let mut buffer = vec![0; 65536];
            loop {
                let n = match socket.recv(&mut buffer).await {
                    Ok(n) => n,
                    Err(_) => {
                        tokio::time::sleep(Duration::from_millis(10)).await;
                        continue;
                    }
                };
                if tx.send((is_video, buffer[..n].to_vec())).await.is_err() {
                    break;
                }
            }
        }));
    }
    drop(tx);
    let c = control.clone();
    let v = video.clone();
    let punch = tokio::spawn(async move {
        loop {
            let _ = c.send(&[0]).await;
            let _ = v.send(&[0]).await;
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    });
    connection::warmup(address).await;
    let connected = tokio::time::timeout(
        Duration::from_secs(75),
        connection::connect(address, &cfg, &screen::Output, Arc::default()),
    )
    .await;
    punch.abort();
    let mut conn = connected??;
    let mut out = tokio::io::stdout();
    emit(&mut out,json!({"kind":"negotiated","requested":codec,"width":conn.width,"height":conn.height,"tiles":conn.tiles}),&[]).await?;
    let mut decrypt = crypto::Rtp::new(&*conn.keys.video_server)?;
    let heartbeat = crypto::Rtp::new(&*conn.keys.audio_viewer)?;
    let mut rtcp_tx = crypto::Rtcp::new(&*conn.keys.video_viewer)?;
    let mut rtcp_rx = crypto::Rtcp::new(&*conn.keys.video_server)?;
    let mut seen = HashSet::new();
    let mut reports = HashMap::new();
    let mut interval = tokio::time::interval(Duration::from_millis(500));
    let mut tick = 0;
    let until = tokio::time::Instant::now() + Duration::from_secs(seconds);
    let started = Instant::now();
    let mut packets = 0u64;
    loop {
        tokio::select! {
            _=tokio::time::sleep_until(until)=>break,
            message=conn.reader.read()=>{message?;},
            item=rx.recv()=>{let Some((is_video,bytes))=item else{break;};
                if is_video {if let Some(p)=decrypt.decrypt(&bytes)? {
                    packets+=1;
                    if seen.insert(p.ssrc){control.send(&rtcp_tx.encrypt(&feedback::fir(conn.keys.video_ssrc,p.ssrc,tick as u8))?).await?;}
                    emit(&mut out,json!({"kind":"rtp","ssrc":p.ssrc,"sequence":p.sequence,"timestamp":p.timestamp,"marker":p.marker,"elapsed":started.elapsed().as_secs_f64()}),&p.payload).await?;
                }} else if bytes.len()>2&&(192..=223).contains(&bytes[1]) {if let Some(plain)=rtcp_rx.decrypt(&bytes)?{feedback::received_reports(&plain,&mut reports);}}
            },
            _=interval.tick()=>{tick+=1;
                control.send(&heartbeat.encrypt(conn.keys.audio_ssrc,tick,(tick*480) as u32,&[0,0x68,0x34,0])?).await?;
                control.send(&rtcp_tx.encrypt(&feedback::report(conn.keys.video_ssrc,&decrypt.sequences(),&reports,tick%10==0))?).await?;
                conn.writer.send(&offers::framebuffer(true,false)).await?;
                if tick%10==0 {for s in &seen {control.send(&rtcp_tx.encrypt(&feedback::fir(conn.keys.video_ssrc,*s,tick as u8))?).await?;}}
            }
        }
    }
    conn.writer.close().await;
    for t in tasks {
        t.abort();
    }
    emit(&mut out,json!({"kind":"complete","packets":packets,"durationSeconds":started.elapsed().as_secs_f64()}),&[]).await?;
    out.flush().await?;
    Ok(())
}
