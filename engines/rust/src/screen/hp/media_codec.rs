//! Bounded IPC to the independently replaceable native codec utility.
use super::{Callback, Stats};
use crate::screen::Output;
use anyhow::{ensure, Context, Result};
use serde_json::json;
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::Duration,
};
pub(super) struct Native {
    child: Child,
    input: ChildStdin,
    replies: mpsc::Receiver<Result<(i32, Vec<Picture>)>>,
    callback: Callback,
}
struct Picture {
    kind: u32,
    tile: u32,
    width: u32,
    height: u32,
    data: Vec<u8>,
}
fn read_reply(reader: &mut impl Read) -> Result<(i32, Vec<Picture>)> {
    fn word(reader: &mut impl Read) -> Result<u32> {
        let mut b = [0; 4];
        reader.read_exact(&mut b)?;
        Ok(u32::from_le_bytes(b))
    }
    let status = word(reader)? as i32;
    let count = word(reader)?;
    ensure!(count <= 16, "Invalid codec output count");
    let mut pictures = Vec::new();
    for _ in 0..count {
        let kind = word(reader)?;
        let tile = word(reader)?;
        let _tag = word(reader)?;
        let width = word(reader)?;
        let height = word(reader)?;
        let length = word(reader)?;
        ensure!(
            ((kind == 1 || kind == 3)
                && tile < 16
                && width > 0
                && width <= 4096
                && height > 0
                && height <= 2160
                && (if kind == 3 {
                    width % 2 == 0 && height % 2 == 0 && length == width * height * 3 / 2
                } else {
                    length == width * height * 3
                }))
                || (kind == 2
                    && width > 0
                    && width <= 4096
                    && height == 48000
                    && length == width * 8),
            "Invalid codec output"
        );
        let mut data = vec![0; length as usize];
        reader.read_exact(&mut data)?;
        pictures.push(Picture {
            kind,
            tile,
            width,
            height,
            data,
        });
    }
    Ok((status, pictures))
}
impl Native {
    pub(super) fn new(
        output: Output,
        audio_enabled: Arc<AtomicBool>,
        stats: Arc<Stats>,
    ) -> Result<Self> {
        let path = std::env::current_exe()?.with_file_name(if cfg!(windows) {
            "termpilot-media.exe"
        } else {
            "termpilot-media"
        });
        let mut command = Command::new(path);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
        let mut child = command
            .spawn()
            .context("Missing Windows media codec (termpilot-media.exe)")?;
        let input = child.stdin.take().context("Missing codec stdin")?;
        let mut reader = child.stdout.take().context("Missing codec stdout")?;
        let (tx, replies) = mpsc::sync_channel(2);
        std::thread::spawn(move || loop {
            let reply = read_reply(&mut reader);
            let done = reply.is_err();
            if tx.send(reply).is_err() || done {
                break;
            }
        });
        let mut native = Self {
            child,
            input,
            replies,
            callback: Callback {
                output,
                audio_enabled,
                stats,
            },
        };
        let status = native.request(3, 0, 0, &[0xf8, 0xe6, 0x51, 0x32, 0xe0, 0])?;
        ensure!(status >= 0, "Audio decoder configuration failed ({status})");
        Ok(native)
    }
    fn request(&mut self, kind: u32, tile: u32, tag: u32, data: &[u8]) -> Result<i32> {
        ensure!(data.len() <= 16 * 1024 * 1024, "Codec input limit");
        for n in [kind, tile, tag, data.len() as u32] {
            self.input.write_all(&n.to_le_bytes())?;
        }
        self.input.write_all(data)?;
        self.input.flush()?;
        let reply = self.replies.recv_timeout(Duration::from_secs(10));
        let (status, pictures) = match reply {
            Ok(Ok(reply)) => reply,
            other => {
                let _ = self.child.kill();
                return match other {
                    Ok(Err(error)) => Err(error),
                    _ => Err(anyhow::anyhow!("Native media codec stopped responding")),
                };
            }
        };
        for p in pictures {
            if p.kind == 1 || p.kind == 3 {
                let cw = if p.kind == 3 { p.width / 2 } else { p.width };
                let ch = if p.kind == 3 { p.height / 2 } else { p.height };
                self.callback.stats.frames.fetch_add(1, Ordering::Relaxed);
                self.callback.output.frame(json!({"kind":"frame","tile":p.tile,"width":p.width,"height":p.height,"yStride":p.width,"uvStride":cw*2,"chromaWidth":cw,"chromaHeight":ch,"biplanar":true,"yLength":p.width*p.height,"uLength":cw*ch*2,"vLength":0}),p.data);
            } else {
                self.callback
                    .stats
                    .audio_frames
                    .fetch_add(p.width as u64, Ordering::Relaxed);
                if self.callback.audio_enabled.load(Ordering::Relaxed) {
                    self.callback.output.audio(p.data);
                }
            }
        }
        Ok(status)
    }
    pub(super) fn health(&mut self) -> Result<()> {
        ensure!(
            self.child.try_wait()?.is_none(),
            "Windows media codec exited; reconnect the session"
        );
        Ok(())
    }
    pub(super) fn configure(&mut self, params: &BTreeMap<(u8, u32), Vec<u8>>) -> Result<()> {
        let mut bytes = Vec::new();
        for data in params.values() {
            bytes.extend((data.len() as u32).to_be_bytes());
            bytes.extend(data);
        }
        let status = self.request(1, 0, 0, &bytes)?;
        ensure!(status >= 0, "Video decoder configuration failed ({status})");
        Ok(())
    }
    pub(super) fn decode(&mut self, nal: &[u8], tile: usize, donl: u16) -> i32 {
        let before = self.callback.stats.frames.load(Ordering::Relaxed);
        match self.request(2, tile as u32, donl as u32, nal) {
            Ok(status) if status < 0 => status,
            Ok(_) => (self.callback.stats.frames.load(Ordering::Relaxed) - before) as i32,
            Err(_) => -1,
        }
    }
    pub(super) fn audio(&mut self, payload: &[u8]) {
        if !matches!(self.request(4, 0, 0, payload), Ok(status) if status >= 0) {
            self.callback.stats.errors.fetch_add(1, Ordering::Relaxed);
            self.callback
                .stats
                .audio_errors
                .fetch_add(1, Ordering::Relaxed);
        }
    }
}
impl Drop for Native {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
