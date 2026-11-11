use super::{connection::Writer, offers};
use crate::{
    ipc::{number, text},
    screen::{keyboard::KeyPacer, Output},
};
use aes::Aes128;
use anyhow::{ensure, Result};
use cipher::{BlockEncrypt, KeyInit};
use flate2::{Compress, Compression, Decompress, FlushCompress, FlushDecompress};
use serde_json::{json, Value};
use std::collections::HashSet;

pub fn pointer(key: &[u8; 16], x: u16, y: u16, buttons: u8) -> Vec<u8> {
    let mut block = [0; 16];
    block[10] = 255;
    block[11] = buttons;
    block[12..14].copy_from_slice(&x.to_be_bytes());
    block[14..16].copy_from_slice(&y.to_be_bytes());
    Aes128::new(key.into()).encrypt_block((&mut block).into());
    let mut out = vec![0x10, 0];
    out.extend(block);
    out
}
fn key(key: u32, down: bool) -> Vec<u8> {
    let mut out = vec![4, down as u8, 0, 0];
    out.extend(key.to_be_bytes());
    out
}
pub fn deflate(data: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(data.len() * 2 + 128);
    let mut c = Compress::new(Compression::default(), true);
    c.compress_vec(data, &mut out, FlushCompress::Sync)?;
    ensure!(
        c.total_in() == data.len() as u64,
        "Deflate did not consume input"
    );
    Ok(out)
}
pub fn inflate(data: &[u8], size: usize, limit: usize) -> Result<Vec<u8>> {
    ensure!(size <= limit && data.len() <= limit, "Archive limit");
    let mut out = vec![0; size + 1];
    let mut d = Decompress::new(true);
    d.decompress(data, &mut out, FlushDecompress::Sync)?;
    ensure!(
        d.total_in() == data.len() as u64 && d.total_out() == size as u64,
        "Invalid archive length"
    );
    out.truncate(size);
    Ok(out)
}
pub fn put_bytes(out: &mut Vec<u8>, data: &[u8]) {
    out.extend((data.len() as u32).to_be_bytes());
    out.extend(data);
}
pub fn take<'a>(data: &mut &'a [u8], n: usize) -> Result<&'a [u8]> {
    ensure!(n <= data.len(), "Truncated archive");
    let (a, b) = data.split_at(n);
    *data = b;
    Ok(a)
}
pub fn word(data: &mut &[u8]) -> Result<usize> {
    Ok(u32::from_be_bytes(take(data, 4)?.try_into()?) as usize)
}
pub fn read_bytes<'a>(data: &mut &'a [u8]) -> Result<&'a [u8]> {
    let n = word(data)?;
    take(data, n)
}
pub fn clipboard_send(value: &str) -> Result<Vec<u8>> {
    ensure!(value.len() <= 524288, "Clipboard text limit");
    let mut archive = 1u32.to_be_bytes().to_vec();
    put_bytes(&mut archive, b"public.utf8-plain-text");
    archive.extend([0; 8]);
    put_bytes(&mut archive, value.as_bytes());
    let packed = deflate(&archive)?;
    let mut out = vec![0x1f, 0, 0, 0, 0, 0, 0, 0];
    out.extend((archive.len() as u32).to_be_bytes());
    put_bytes(&mut out, &packed);
    Ok(out)
}
fn clipboard_text(packet: &[u8]) -> Result<Option<String>> {
    ensure!(packet.len() >= 16 && packet[0] == 0x1f, "Clipboard header");
    let mut body = &packet[8..];
    let size = word(&mut body)?;
    let packed = word(&mut body)?;
    ensure!(body.len() == packed, "Clipboard size");
    let raw = inflate(body, size, 8 * 1024 * 1024)?;
    if raw.is_empty() {
        return Ok(None);
    }
    let mut data = raw.as_slice();
    let count = word(&mut data)?;
    ensure!(count <= 256, "Clipboard item limit");
    let mut candidates = Vec::new();
    for _ in 0..count {
        let uti = read_bytes(&mut data)?;
        word(&mut data)?;
        let aliases = word(&mut data)?;
        ensure!(aliases <= 256, "Clipboard alias limit");
        for _ in 0..aliases {
            let alias = read_bytes(&mut data)?;
            let bytes = read_bytes(&mut data)?;
            candidates.push((alias, bytes));
        }
        let bytes = read_bytes(&mut data)?;
        candidates.push((uti, bytes));
    }
    ensure!(data.is_empty(), "Clipboard trailing bytes");
    candidates.sort_by_key(|(uti, _)| {
        if *uti == b"public.utf8-plain-text" {
            0
        } else {
            1
        }
    });
    for (uti, bytes) in candidates {
        let uti = std::str::from_utf8(uti).unwrap_or("");
        if bytes.len() > 524288 {
            continue;
        }
        let text = if uti.starts_with("public.") && uti.contains("text") {
            if uti.contains("utf16") {
                let big = uti.contains("external");
                let units = bytes.chunks_exact(2).map(|b| {
                    if big {
                        u16::from_be_bytes([b[0], b[1]])
                    } else {
                        u16::from_le_bytes([b[0], b[1]])
                    }
                });
                char::decode_utf16(units)
                    .map(|c| c.unwrap_or(char::REPLACEMENT_CHARACTER))
                    .collect::<String>()
            } else {
                String::from_utf8_lossy(bytes).into_owned()
            }
        } else if uti == "com.apple.traditional-mac-plain-text" {
            bytes.iter().copied().map(char::from).collect()
        } else {
            continue;
        };
        if text.len() <= 524288 {
            return Ok(Some(text));
        }
    }
    Ok(None)
}
pub struct Controls {
    display: offers::DisplayMode,
    tiles: u16,
    enabled: bool,
    pending: Option<String>,
    queued: Option<String>,
    clipboard: Vec<u8>,
    expected: usize,
    keys: HashSet<u32>,
    key_pacer: KeyPacer,
    position: (u16, u16, u8),
}
impl Default for Controls {
    fn default() -> Self {
        Self::new()
    }
}

impl Controls {
    pub fn new() -> Self {
        Self::for_display(offers::DisplayMode::default(), 4)
    }
    pub fn for_display(display: offers::DisplayMode, tiles: u16) -> Self {
        Self {
            display,
            tiles,
            enabled: false,
            pending: None,
            queued: None,
            clipboard: Vec::new(),
            expected: 0,
            keys: HashSet::new(),
            key_pacer: KeyPacer::new(true),
            position: (0, 0, 0),
        }
    }
    pub fn clipboard_in_progress(&self) -> bool {
        !self.clipboard.is_empty()
    }
    /// One credential character per IPC request. The client waits for the
    /// returned acknowledgement before sending another, so cancellation never
    /// leaves an entire password/Return queued behind a stalled connection.
    pub async fn credential_key(&mut self, command: &Value, write: &mut Writer) -> Result<Value> {
        let request = text(command, "requestID");
        let code = command["key"].as_u64().and_then(|v| u32::try_from(v).ok());
        let code = code.filter(|code| valid_credential_key(*code));
        ensure!(request.len() == 36 && request.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') && code.is_some(), "invalidCredentialInput");
        let code = code.unwrap();
        for down in [true, false] {
            self.command(&json!({"kind":"key","key":code,"down":down}), write).await?;
        }
        Ok(json!({"kind":"credentialKeySent","requestID":request}))
    }
    pub async fn release(&mut self, write: &mut Writer) -> Result<()> {
        for keycode in self.keys.drain() {
            self.key_pacer.before_send().await;
            write.send(&key(keycode, false)).await?;
            self.key_pacer.after_send();
        }
        self.position.2 = 0;
        write
            .send(&pointer(
                &write.cipher.key,
                self.position.0,
                self.position.1,
                0,
            ))
            .await
    }
    pub async fn command(&mut self, command: &Value, write: &mut Writer) -> Result<bool> {
        match text(command, "kind") {
            "key" => {
                let code = number(command, "key", 0);
                if (1..=0x11ffffff).contains(&code) {
                    let down = command["down"].as_bool() == Some(true);
                    if down {
                        if self.keys.len() >= 256 {
                            return Ok(true);
                        }
                        self.keys.insert(code as u32);
                    } else {
                        self.keys.remove(&(code as u32));
                    }
                    self.key_pacer.before_send().await;
                    write.send(&key(code as u32, down)).await?;
                    self.key_pacer.after_send();
                }
            }
            "pointer" => {
                self.position = (
                    command["x"].as_i64().unwrap_or(0).clamp(0, i64::from(self.display.width) - 1) as u16,
                    command["y"].as_i64().unwrap_or(0).clamp(0, i64::from(self.display.height) - 1) as u16,
                    number(command, "buttons", 0) as u8 & 7,
                );
                write
                    .send(&pointer(
                        &write.cipher.key,
                        self.position.0,
                        self.position.1,
                        self.position.2,
                    ))
                    .await?;
            }
            "scroll" => {
                let dy = command["dy"].as_i64().unwrap_or(0).clamp(-10, 10);
                for _ in 0..dy.abs() {
                    write
                        .send(&pointer(
                            &write.cipher.key,
                            self.position.0,
                            self.position.1,
                            self.position.2 | if dy < 0 { 8 } else { 16 },
                        ))
                        .await?;
                    write
                        .send(&pointer(
                            &write.cipher.key,
                            self.position.0,
                            self.position.1,
                            self.position.2,
                        ))
                        .await?;
                }
            }
            "release" => self.release(write).await?,
            "clipboardSync" => {
                self.enabled = command["enabled"].as_bool() == Some(true);
                if self.enabled {
                    write.send(&[0x15, 0, 0, 1, 0, 0, 0, 0]).await?;
                } else {
                    self.queued = None;
                }
            }
            "clipboardSend" => {
                let value = text(command, "text");
                if self.enabled && value.len() <= 524288 {
                    write.send(&clipboard_send(value)?).await?;
                }
            }
            "clipboardFetch" => {
                let id = text(command, "requestID");
                if self.enabled && (1..=80).contains(&id.len()) {
                    if self.pending.is_some() {
                        self.queued = Some(id.into());
                    } else {
                        self.pending = Some(id.into());
                        write.send(&[0x0b, 0, 0, 0, 0, 0, 0, 0]).await?;
                    }
                }
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
    pub async fn message(
        &mut self,
        message: &[u8],
        write: &mut Writer,
        output: &Output,
    ) -> Result<bool> {
        if self.clipboard_in_progress() || message.first() == Some(&0x1f) {
            self.clipboard.extend(message);
            ensure!(
                self.clipboard.len() <= 8 * 1024 * 1024 + 16,
                "Clipboard buffer limit"
            );
            if self.expected == 0 && self.clipboard.len() >= 16 {
                let unpacked = u32::from_be_bytes(self.clipboard[8..12].try_into()?) as usize;
                let packed = u32::from_be_bytes(self.clipboard[12..16].try_into()?) as usize;
                ensure!(
                    unpacked <= 8 * 1024 * 1024 && packed <= 8 * 1024 * 1024,
                    "Clipboard archive limit"
                );
                self.expected = 16 + packed;
            }
            if self.expected != 0 && self.clipboard.len() >= self.expected {
                ensure!(
                    self.clipboard.len() == self.expected,
                    "Clipboard framing mismatch"
                );
                let value = clipboard_text(&std::mem::take(&mut self.clipboard))?;
                self.expected = 0;
                if let Some(id) = self.pending.take() {
                    output
                        .emit(
                            json!({"kind":"clipboard","requestID":id,"hasText":value.is_some()}),
                            value.unwrap_or_default().into_bytes(),
                        )
                        .await?;
                }
                if self.enabled {
                    if let Some(id) = self.queued.take() {
                        self.pending = Some(id);
                        write.send(&[0x0b, 0, 0, 0, 0, 0, 0, 0]).await?;
                    }
                }
            }
            return Ok(true);
        }
        match message.first().copied() {
            Some(0x14) => {
                if message.len() >= 8 && message[6..8] == [0, 2] && self.enabled {
                    output
                        .emit(json!({"kind":"clipboardChanged"}), Vec::new())
                        .await?;
                }
            }
            Some(0) => {
                self.framebuffer(message, write).await?;
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
    async fn framebuffer(&mut self, message: &[u8], write: &mut Writer) -> Result<()> {
        if message.len() < 4 {
            return Ok(());
        }
        let count = u16::from_be_bytes(message[2..4].try_into()?) as usize;
        ensure!(count <= 256, "Control rectangle limit");
        let mut data = &message[4..];
        let mut layout = false;
        for _ in 0..count {
            let rect = take(&mut data, 12)?;
            let encoding = i32::from_be_bytes(rect[8..12].try_into()?);
            match encoding {
                1104 => {
                    take(&mut data, 4)?;
                    let n = word(&mut data)?;
                    take(&mut data, n)?;
                }
                1010 | 1011 | 1002 | 1107 | 1109 | 1110 | 1105 => {
                    let size = u16::from_be_bytes(take(&mut data, 2)?.try_into()?) as usize;
                    let payload = take(&mut data, size)?;
                    if encoding == 1105 {
                        layout = true;
                        if payload.len() >= 10 {
                            let w = u16::from_be_bytes(payload[6..8].try_into()?);
                            let h = u16::from_be_bytes(payload[8..10].try_into()?);
                            ensure!(
                                w == 0 || h == 0 || self.display.accepts_encoded(w, h, self.tiles),
                                "displayMode"
                            );
                        }
                    }
                }
                -224 => break,
                _ => return Ok(()),
            }
        }
        write.send(&offers::framebuffer(!layout, false)).await?;
        Ok(())
    }
}
fn valid_credential_key(code: u32) -> bool {
    code == 0xff0d || (0x20..=0x7e).contains(&code) || (0xa0..=0xff).contains(&code)
        || (0x01000100..=0x0110ffff).contains(&code)
            && char::from_u32(code & 0x00ffffff).is_some_and(|c| !c.is_control() && !matches!(c, '\u{2028}' | '\u{2029}'))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn pointer_uses_selected_desktop_and_clamps_outside_drag() -> Result<()> {
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let stream = tokio::net::TcpStream::connect(listener.local_addr()?).await?;
        let (mut peer, _) = listener.accept().await?;
        let mut writer = Writer::test_writer(stream);
        let mut cipher = super::super::crypto::Control::pair(&[3; 16], &[5; 36])?.1;
        for (width,height) in offers::DisplayMode::PRESETS {
            let mut controls = Controls::for_display(offers::DisplayMode {width,height}, 4);
            for (x,y,expected_x,expected_y) in [(i64::from(width)-1,i64::from(height)-1,width-1,height-1),(9000,-5,width-1,0)] {
                controls.command(&json!({"kind":"pointer","x":x,"y":y,"buttons":1}), &mut writer).await?;
                let length = peer.read_u16().await?;
                let mut encrypted = vec![0; usize::from(length)];
                peer.read_exact(&mut encrypted).await?;
                let plain = cipher.decrypt(&encrypted)?.expect("authenticated pointer");
                assert_eq!(plain, pointer(&writer.cipher.key, expected_x, expected_y, 1));
            }
        }
        Ok(())
    }
    #[test]
    fn credential_keys_accept_printable_unicode_and_only_return_as_a_control_key() {
        for code in [0x20, 0x21, 0x22, 0x5c, 0xe9, 0x01004e2d, 0x0101f511, 0xff0d] {
            assert!(valid_credential_key(code));
        }
        for code in [0, 9, 10, 13, 0x7f, 0x85, 0xffeb, 0xffff, 0x0100d800, 0x01002028, 0x01110000] {
            assert!(!valid_credential_key(code));
        }
    }

    #[tokio::test]
    async fn credential_pairs_use_encrypted_control_and_acknowledge_after_both_transitions() -> Result<()> {
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let stream = tokio::net::TcpStream::connect(listener.local_addr()?).await?;
        let (mut peer, _) = listener.accept().await?;
        let mut writer = Writer::test_writer(stream);
        let mut controls = Controls::new();
        let mut cipher = super::super::crypto::Control::pair(&[3; 16], &[5; 36])?.1;
        for code in [0x21, 0x01004e2d, 0x0101f511, 0xff0d] {
            let request = uuid::Uuid::new_v4().to_string();
            let response = controls.credential_key(&json!({"key":code,"requestID":request}), &mut writer).await?;
            assert_eq!(response, json!({"kind":"credentialKeySent","requestID":request}));
            for down in [true, false] {
                let length = peer.read_u16().await?;
                let mut encrypted = vec![0; usize::from(length)];
                peer.read_exact(&mut encrypted).await?;
                let plain = cipher.decrypt(&encrypted)?.expect("authenticated control record");
                assert_eq!(plain, key(code, down));
            }
            assert!(controls.keys.is_empty());
        }
        assert!(controls.credential_key(&json!({"key":10,"requestID":uuid::Uuid::new_v4().to_string()}), &mut writer).await.is_err());
        assert!(tokio::time::timeout(std::time::Duration::from_millis(40), peer.read_u8()).await.is_err());
        Ok(())
    }
    #[test]
    fn rich_clipboard_unicode_and_empty() {
        for value in ["", "中文\r\n📋", &"x".repeat(524288)] {
            let wire = clipboard_send(value).unwrap();
            assert_eq!(clipboard_text(&wire).unwrap().as_deref(), Some(value));
        }
    }
    #[test]
    fn inflated_size_is_bounded() {
        let mut wire = clipboard_send("abc").unwrap();
        wire[8..12].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(clipboard_text(&wire).is_err());
    }
}
