//! Existing standard RFB feature set, shared by macOS and Windows.
use super::{
    apple,
    keyboard::KeyPacer,
    pixels::{classic, Frame},
    Counted, Output, Traffic,
};
use crate::{
    ipc::{number, text},
    transport,
};
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{mpsc, Mutex},
};
use tokio_util::sync::CancellationToken;

async fn bytes<R: AsyncRead + Unpin>(read: &mut R, n: usize) -> Result<Vec<u8>> {
    ensure!(n <= 64 * 1024 * 1024, "vncInvalidData");
    let mut data = vec![0; n];
    read.read_exact(&mut data).await?;
    Ok(data)
}
fn request(w: u16, h: u16, incremental: bool) -> Vec<u8> {
    let mut bytes = vec![3, u8::from(incremental), 0, 0, 0, 0];
    bytes.extend(w.to_be_bytes());
    bytes.extend(h.to_be_bytes());
    bytes
}
fn key_event(key: u32, down: bool) -> Vec<u8> {
    let mut bytes = vec![4, u8::from(down), 0, 0];
    bytes.extend(key.to_be_bytes());
    bytes
}
fn pointer(x: u16, y: u16, buttons: u8) -> Vec<u8> {
    let mut bytes = vec![5, buttons];
    bytes.extend(x.to_be_bytes());
    bytes.extend(y.to_be_bytes());
    bytes
}
async fn send<W: AsyncWrite + Unpin>(write: &Mutex<W>, data: &[u8]) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(15), async {
        let mut write = write.lock().await;
        write.write_all(data).await?;
        write.flush().await
    })
    .await
    .context("connectionTimeout")??;
    Ok(())
}

async fn send_key<W: AsyncWrite + Unpin>(
    write: &Mutex<W>,
    pacer: &mut KeyPacer,
    key: u32,
    down: bool,
) -> Result<()> {
    pacer.before_send().await;
    send(write, &key_event(key, down)).await?;
    pacer.after_send();
    Ok(())
}

pub async fn run(
    config: Value,
    output: Output,
    mut commands: mpsc::Receiver<Value>,
    traffic: Arc<Traffic>,
    stop: CancellationToken,
) -> Result<()> {
    output.status("tcp").await?;
    let port = number(&config, "port", 5900);
    ensure!((1..=65535).contains(&port), "vncInvalidEndpoint");
    let stream = transport::connect(text(&config, "host"), port as u16, &config["proxy"]).await?;
    let mut stream = Counted {
        inner: stream,
        traffic,
    };
    let handshake = async {
        let banner = bytes(&mut stream, 12).await?;
        ensure!(
            banner.starts_with(b"RFB 003.") && banner[11] == b'\n',
            "vncProtocolUnsupported"
        );
        let offered = std::str::from_utf8(&banner[8..11])?.parse::<u16>()?;
        ensure!(offered >= 3, "vncProtocolUnsupported");
        let version = if offered >= 8 {
            8
        } else if offered >= 7 {
            7
        } else {
            3
        };
        stream
            .write_all(format!("RFB 003.{version:03}\n").as_bytes())
            .await?;
        let choices = if version == 3 {
            let security = stream.read_u32().await?;
            ensure!(security <= 255, "vncAuthenticationUnsupported");
            vec![security as u8]
        } else {
            let n = stream.read_u8().await?;
            bytes(&mut stream, n as usize).await?
        };
        output.status("authenticate").await?;
        let (user, password) = (text(&config, "username"), text(&config, "password"));
        if choices.contains(&33) && !user.is_empty() && !password.is_empty() {
            apple::authenticate(&mut stream, user, password).await?;
        } else if choices.contains(&2) && !password.is_empty() {
            if version != 3 {
                stream.write_all(&[2]).await?;
            }
            ensure!(
                password.chars().all(|c| c as u32 <= 255),
                "vncPasswordEncoding"
            );
            let challenge = bytes(&mut stream, 16).await?;
            stream.write_all(&classic(&challenge, password)?).await?;
            ensure!(stream.read_u32().await? == 0, "authenticationRejected");
        } else if choices.contains(&1) && user.is_empty() && password.is_empty() {
            if version != 3 {
                stream.write_all(&[1]).await?;
            }
            if version >= 8 {
                ensure!(stream.read_u32().await? == 0, "authenticationRejected");
            }
        } else {
            bail!("vncAuthenticationUnsupported");
        }
        output.status("negotiate").await?;
        stream.write_all(&[1]).await?;
        let header = bytes(&mut stream, 24).await?;
        let w = u16::from_be_bytes(header[0..2].try_into()?);
        let h = u16::from_be_bytes(header[2..4].try_into()?);
        let length = u32::from_be_bytes(header[20..24].try_into()?) as usize;
        ensure!(length <= 65536, "vncInvalidData");
        bytes(&mut stream, length).await?;
        let frame = Frame::new(w as usize, h as usize)?;
        stream
            .write_all(&[
                0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 2, 0, 0, 5,
            ])
            .await?;
        for encoding in [6i32, 1, 0, -223, -224] {
            stream.write_all(&encoding.to_be_bytes()).await?;
        }
        stream.write_all(&request(w, h, false)).await?;
        output
            .emit(
                json!({"kind":"connected","width":w,"height":h,"decoder":"VNC · Rust Zlib / Raw"}),
                Vec::new(),
            )
            .await?;
        Ok::<_, anyhow::Error>((
            frame,
            KeyPacer::new(offered == 889 || choices.contains(&33)),
        ))
    };
    let (mut frame, mut key_pacer) = tokio::select! {_=stop.cancelled()=>return Ok(()),result=tokio::time::timeout(Duration::from_secs(60),handshake)=>result.context("connectionTimeout")??};
    let dimensions = Arc::new(AtomicU64::new(
        ((frame.width as u64) << 32) | frame.height as u64,
    ));
    let clipboard = Arc::new(StdMutex::new(None::<String>));
    let enabled = Arc::new(AtomicBool::new(false));
    let (read, write) = tokio::io::split(stream);
    let write = Arc::new(Mutex::new(write));
    let (reader_output, reader_write, reader_dimensions, reader_clipboard, reader_enabled) = (
        output.clone(),
        write.clone(),
        dimensions.clone(),
        clipboard.clone(),
        enabled.clone(),
    );
    let mut reader = tokio::spawn(async move {
        let mut read = read;
        loop {
            // Waiting for a new update is unbounded. Once a message starts,
            // its body must complete within a bounded deadline.
            let kind = read.read_u8().await?;
            tokio::time::timeout(Duration::from_secs(15),async {
                match kind {
                    0=>{
                        read.read_u8().await?;let count=read.read_u16().await?;ensure!(count<=4096||count==65535,"vncInvalidData");let mut changed=false;
                        for index in 0..count {
                            ensure!(index<4096,"vncInvalidData");let x=read.read_u16().await?as usize;let y=read.read_u16().await?as usize;let w=read.read_u16().await?as usize;let h=read.read_u16().await?as usize;let encoding=read.read_i32().await?;
                            if encoding==-224{break;}
                            if encoding==-223{
                                frame=Frame::new(w,h)?;reader_dimensions.store(((w as u64)<<32)|h as u64,Ordering::Relaxed);
                                reader_output.emit(json!({"kind":"desktopSize","width":w,"height":h}),Vec::new()).await?;changed=true;continue;
                            }
                            frame.bounds(x,y,w,h)?;
                            match encoding {
                                0=>frame.raw(x,y,w,h,&bytes(&mut read,w*h*4).await?)?,
                                1=>{let sx=read.read_u16().await?as usize;let sy=read.read_u16().await?as usize;frame.copy(x,y,w,h,sx,sy)?;}
                                6=>{let n=read.read_u32().await?as usize;ensure!(n<=w*h*4+65536,"vncInvalidData");frame.zlib(x,y,w,h,&bytes(&mut read,n).await?)?;}
                                _=>bail!("vncEncodingUnsupported")
                            }changed=true;
                        }
                        if changed {reader_output.frame(json!({"kind":"frame","tile":0,"width":frame.width,"height":frame.height,"pixelFormat":"bgrx","yStride":frame.width*4}),frame.pixels.clone());}
                        send(&reader_write,&request(frame.width as u16,frame.height as u16,true)).await?;
                    }
                    2=>{},
                    3=>{
                        bytes(&mut read,3).await?;let n=read.read_u32().await?as usize;ensure!(n<=524288,"vncInvalidData");
                        let value=bytes(&mut read,n).await?.into_iter().map(char::from).collect::<String>();*reader_clipboard.lock().unwrap()=Some(value);
                        if reader_enabled.load(Ordering::Relaxed){reader_output.emit(json!({"kind":"clipboardChanged"}),Vec::new()).await?;}
                    }
                    _=>bail!("vncProtocolUnsupported")
                }Ok::<_,anyhow::Error>(())
            }).await.context("connectionTimeout")??;
        }
        #[allow(unreachable_code)]
        Ok::<_, anyhow::Error>(())
    });
    let mut keys = HashSet::new();
    let mut position = (0u16, 0u16, 0u8);
    let result:Result<()>=async { loop {tokio::select!{
        _=stop.cancelled()=>break,
        result=&mut reader=>{result??;break;},
        command=commands.recv()=>{
            let Some(command)=command else{break;};let size=dimensions.load(Ordering::Relaxed);let(w,h)=((size>>32)as u16,size as u16);
            match text(&command,"kind"){
                "key"=>{let key=number(&command,"key",0);if !(1..=0x11ffffff).contains(&key){continue;}let down=command["down"].as_bool()==Some(true);if down{keys.insert(key as u32);}else{keys.remove(&(key as u32));}send_key(&write,&mut key_pacer,key as u32,down).await?;}
                "pointer"=>{let x=command["x"].as_i64().unwrap_or(0).clamp(0,w as i64-1)as u16;let y=command["y"].as_i64().unwrap_or(0).clamp(0,h as i64-1)as u16;let b=number(&command,"buttons",0)as u8&7;let b=(b&1)|((b&2)<<1)|((b&4)>>1);position=(x,y,b);send(&write,&pointer(x,y,b)).await?;}
                "scroll"=>{let dy=command["dy"].as_i64().unwrap_or(0).clamp(-10,10);for _ in 0..dy.abs(){let(x,y,b)=position;send(&write,&[pointer(x,y,b|if dy<0{8}else{16}),pointer(x,y,b)].concat()).await?;}}
                "release"=>{for key in keys.drain(){send_key(&write,&mut key_pacer,key,false).await?;}position.2=0;send(&write,&pointer(position.0,position.1,0)).await?;}
                "refresh"=>send(&write,&request(w,h,false)).await?,
                "clipboardSync"=>{enabled.store(command["enabled"].as_bool()==Some(true),Ordering::Relaxed);}
                "clipboardSend"=>{
                    let value=text(&command,"text");if value.len()>524288||!enabled.load(Ordering::Relaxed){continue;}
                    if !value.chars().all(|c|c as u32<=255){output.emit(json!({"kind":"clipboardUnsupported"}),Vec::new()).await?;continue;}
                    let payload=value.chars().map(|c|c as u8).collect::<Vec<_>>();let mut message=vec![6,0,0,0];message.extend((payload.len()as u32).to_be_bytes());message.extend(payload);send(&write,&message).await?;*clipboard.lock().unwrap()=Some(value.into());
                }
                "clipboardFetch"=>{let value=if enabled.load(Ordering::Relaxed){clipboard.lock().unwrap().clone()}else{None};output.emit(json!({"kind":"clipboard","requestID":command["requestID"],"hasText":value.is_some()}),value.unwrap_or_default().into_bytes()).await?;}
                _=>{}
            }
        }
    }}Ok(())}.await;
    reader.abort();
    for key in keys {
        let _ = send_key(&write, &mut key_pacer, key, false).await;
    }
    let _ = send(&write, &pointer(position.0, position.1, 0)).await;
    let _ = write.lock().await.shutdown().await;
    result
}
