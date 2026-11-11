//! Apple enc1103 and SRTP/SRTCP. Wire format derived from the independent
//! AGPL-3.0-or-later iShareScreen copy in this repository.
use aes::{Aes128, Aes256};
use anyhow::{ensure, Result};
use cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use hmac::{Hmac, Mac};
use sha1::{Digest, Sha1};
use std::collections::HashMap;
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

pub struct Control {
    pub key: Zeroizing<[u8; 16]>,
    iv: [u8; 16],
    counter: u32,
}
impl Control {
    pub fn pair(ecb_key: &[u8; 16], blob: &[u8]) -> Result<(Self, Self)> {
        ensure!(blob.len() == 36, "Invalid encryption key envelope");
        let cipher = Aes128::new(ecb_key.into());
        let mut key = [0; 16];
        key.copy_from_slice(&blob[4..20]);
        let mut iv = [0; 16];
        iv.copy_from_slice(&blob[20..36]);
        cipher.decrypt_block((&mut key).into());
        cipher.decrypt_block((&mut iv).into());
        let make = || Self {
            key: Zeroizing::new(key),
            iv,
            counter: 0,
        };
        let pair = (make(), make());
        key.zeroize();
        Ok(pair)
    }
    pub fn encrypt(&mut self, payload: &[u8]) -> Result<Vec<u8>> {
        ensure!(payload.len() <= 65000, "Control record limit");
        let pad = (16 - (2 + payload.len() + 20) % 16) % 16;
        let mut plain = Zeroizing::new((payload.len() as u16).to_be_bytes().to_vec());
        plain.extend(payload);
        let padded = plain.len() + pad;
        plain.resize(padded, 0);
        let mut hash = Sha1::new();
        hash.update(self.counter.to_be_bytes());
        hash.update(&*plain);
        plain.extend(hash.finalize());
        self.counter = self.counter.wrapping_add(1);
        let cipher = Aes128::new((&*self.key).into());
        for chunk in plain.chunks_exact_mut(16) {
            for (x, iv) in chunk.iter_mut().zip(self.iv) {
                *x ^= iv;
            }
            cipher.encrypt_block(chunk.into());
            self.iv.copy_from_slice(chunk);
        }
        let mut wire = (plain.len() as u16).to_be_bytes().to_vec();
        wire.extend(&*plain);
        Ok(wire)
    }
    pub fn decrypt(&mut self, ciphertext: &[u8]) -> Result<Option<Vec<u8>>> {
        ensure!(
            (32..=65520).contains(&ciphertext.len()) && ciphertext.len().is_multiple_of(16),
            "Invalid encrypted record length"
        );
        let cipher = Aes128::new((&*self.key).into());
        let mut plain = Zeroizing::new(ciphertext.to_vec());
        for chunk in plain.chunks_exact_mut(16) {
            let mut next = [0; 16];
            next.copy_from_slice(chunk);
            cipher.decrypt_block(chunk.into());
            for (x, iv) in chunk.iter_mut().zip(self.iv) {
                *x ^= iv;
            }
            self.iv = next;
        }
        let signed = plain.len() - 20;
        // The daemon occasionally skips a counter while changing user sessions.
        // Authenticate every candidate before trusting any plaintext field.
        let candidates = std::iter::once(self.counter.wrapping_sub(1))
            .chain((0..=5).map(|offset| self.counter.wrapping_add(offset)));
        let mut matched = None;
        for counter in candidates {
            let mut hash = Sha1::new();
            hash.update(counter.to_be_bytes());
            hash.update(&plain[..signed]);
            if bool::from(hash.finalize().ct_eq(&plain[signed..])) {
                matched = Some(counter);
            }
        }
        let Some(counter) = matched else {
            self.counter = self.counter.wrapping_add(1);
            return Ok(None);
        };
        self.counter = counter.wrapping_add(1);
        let size = u16::from_be_bytes(plain[..2].try_into()?) as usize;
        ensure!(
            size + 2 <= signed && signed - size - 2 < 16,
            "Invalid authenticated control payload"
        );
        // The server leaves arbitrary bytes in its padding on file-transfer
        // records. They are covered by the verified MAC; only length matters.
        Ok(Some(plain[2..2 + size].to_vec()))
    }
}

fn ctr(key: &[u8], iv: u128, data: &[u8]) -> Result<Vec<u8>> {
    let cipher = Aes256::new_from_slice(key)?;
    let mut output = data.to_vec();
    for (offset, chunk) in output.chunks_mut(16).enumerate() {
        let mut block = iv.wrapping_add(offset as u128).to_be_bytes().into();
        cipher.encrypt_block(&mut block);
        for (x, mask) in chunk.iter_mut().zip(block) {
            *x ^= mask;
        }
    }
    Ok(output)
}
fn derive(blob: &[u8], label: u8, size: usize) -> Result<Vec<u8>> {
    ensure!(blob.len() == 46, "Invalid SRTP key");
    let mut iv = [0; 16];
    iv[..14].copy_from_slice(&blob[32..]);
    iv[7] ^= label;
    ctr(&blob[..32], u128::from_be_bytes(iv), &vec![0; size])
}
struct Keys {
    key: Zeroizing<Vec<u8>>,
    auth: Zeroizing<Vec<u8>>,
    salt: u128,
}
impl Keys {
    fn new(blob: &[u8], label: u8) -> Result<Self> {
        let salt = derive(blob, label + 2, 14)?;
        let mut padded = [0; 16];
        padded[..14].copy_from_slice(&salt);
        Ok(Self {
            key: Zeroizing::new(derive(blob, label, 32)?),
            auth: Zeroizing::new(derive(blob, label + 1, 20)?),
            salt: u128::from_be_bytes(padded),
        })
    }
    fn tag(&self, data: &[u8], extra: &[u8]) -> [u8; 10] {
        let mut mac =
            <Hmac<Sha1> as Mac>::new_from_slice(&self.auth).expect("HMAC accepts every key size");
        mac.update(data);
        mac.update(extra);
        mac.finalize().into_bytes()[..10].try_into().unwrap()
    }
}
// A 4096-packet window allows retransmissions under load while rejecting replay.
struct Replay {
    newest: Option<u64>,
    bits: [u64; 64],
}
impl Default for Replay {
    fn default() -> Self {
        Self {
            newest: None,
            bits: [0; 64],
        }
    }
}
impl Replay {
    fn accept(&mut self, index: u64) -> bool {
        if let Some(last) = self.newest {
            if index <= last {
                let age = (last - index) as usize;
                if age >= 4096 || self.bits[age / 64] & (1 << (age % 64)) != 0 {
                    return false;
                }
                self.bits[age / 64] |= 1 << (age % 64);
                return true;
            }
            let delta = (index - last).min(4096) as usize;
            let old = self.bits;
            self.bits.fill(0);
            let words = delta / 64;
            let shift = delta % 64;
            for (src, value) in old.iter().enumerate().take(64 - words) {
                self.bits[src + words] |= value << shift;
                if shift != 0 && src + words + 1 < 64 {
                    self.bits[src + words + 1] |= value >> (64 - shift);
                }
            }
        }
        self.newest = Some(index);
        self.bits[0] |= 1;
        true
    }
}
pub struct Rtp {
    keys: Keys,
    replay: HashMap<u32, Replay>,
}
pub struct Packet {
    pub ssrc: u32,
    pub sequence: u16,
    pub timestamp: u32,
    pub marker: bool,
    pub payload: Vec<u8>,
}
impl Rtp {
    pub fn new(blob: &[u8]) -> Result<Self> {
        Ok(Self {
            keys: Keys::new(blob, 0)?,
            replay: HashMap::new(),
        })
    }
    pub fn decrypt(&mut self, packet: &[u8]) -> Result<Option<Packet>> {
        if packet.len() < 22 || packet[0] >> 6 != 2 {
            return Ok(None);
        }
        let end = packet.len() - 10;
        let mut header = 12 + 4 * (packet[0] & 15) as usize;
        if header > end {
            return Ok(None);
        }
        if packet[0] & 16 != 0 {
            if header + 4 > end {
                return Ok(None);
            }
            header +=
                4 + 4 * u16::from_be_bytes(packet[header + 2..header + 4].try_into()?) as usize;
        }
        if header > end {
            return Ok(None);
        }
        let sequence = u16::from_be_bytes(packet[2..4].try_into()?);
        let ssrc = u32::from_be_bytes(packet[8..12].try_into()?);
        let newest = self
            .replay
            .get(&ssrc)
            .and_then(|r| r.newest)
            .unwrap_or(sequence as u64);
        let current = (newest >> 16) as u32;
        let diff = sequence as i32 - (newest & 65535) as i32;
        let guess = if diff > 32767 {
            current.saturating_sub(1)
        } else if diff < -32767 {
            current.saturating_add(1)
        } else {
            current
        };
        let mut matched = None;
        for roc in [
            guess,
            current,
            guess.saturating_add(1),
            guess.saturating_sub(1),
        ] {
            if bool::from(
                self.keys
                    .tag(&packet[..end], &roc.to_be_bytes())
                    .ct_eq(&packet[end..]),
            ) {
                matched = Some(roc);
                break;
            }
        }
        let Some(roc) = matched else { return Ok(None) };
        if !self.replay.contains_key(&ssrc) && self.replay.len() >= 4096 {
            return Ok(None);
        }
        let index = ((roc as u64) << 16) | sequence as u64;
        if !self.replay.entry(ssrc).or_default().accept(index) {
            return Ok(None);
        }
        let iv = self.keys.salt ^ ((ssrc as u128) << 64) ^ ((index as u128) << 16);
        let mut payload = ctr(&self.keys.key, iv, &packet[header..end])?;
        if packet[0] & 32 != 0 {
            let pad = payload.last().copied().unwrap_or(0) as usize;
            if pad == 0 || pad > payload.len() {
                return Ok(None);
            }
            payload.truncate(payload.len() - pad);
        }
        Ok(Some(Packet {
            ssrc,
            sequence,
            timestamp: u32::from_be_bytes(packet[4..8].try_into()?),
            marker: packet[1] & 128 != 0,
            payload,
        }))
    }
    pub fn encrypt(
        &self,
        ssrc: u32,
        index: u64,
        timestamp: u32,
        payload: &[u8],
    ) -> Result<Vec<u8>> {
        let mut packet = vec![0x80, 101];
        packet.extend((index as u16).to_be_bytes());
        packet.extend(timestamp.to_be_bytes());
        packet.extend(ssrc.to_be_bytes());
        let iv = self.keys.salt ^ ((ssrc as u128) << 64) ^ ((index as u128) << 16);
        packet.extend(ctr(&self.keys.key, iv, payload)?);
        packet.extend(
            self.keys
                .tag(&packet, &((index >> 16) as u32).to_be_bytes()),
        );
        Ok(packet)
    }
    pub fn sequences(&self) -> Vec<(u32, u32)> {
        self.replay
            .iter()
            .filter_map(|(s, r)| r.newest.map(|n| (*s, n as u32)))
            .collect()
    }
}
pub struct Rtcp {
    keys: Keys,
    index: u32,
    replay: HashMap<u32, Replay>,
}
impl Rtcp {
    pub fn new(blob: &[u8]) -> Result<Self> {
        Ok(Self {
            keys: Keys::new(blob, 3)?,
            index: 0,
            replay: HashMap::new(),
        })
    }
    pub fn encrypt(&mut self, plain: &[u8]) -> Result<Vec<u8>> {
        ensure!(
            plain.len() >= 8 && plain.len() <= 65500 && self.index < 0x7fffffff,
            "Invalid RTCP packet/index"
        );
        let ssrc = u32::from_be_bytes(plain[4..8].try_into()?);
        let iv = self.keys.salt ^ ((ssrc as u128) << 64) ^ ((self.index as u128) << 16);
        let mut packet = plain[..8].to_vec();
        packet.extend(ctr(&self.keys.key, iv, &plain[8..])?);
        packet.extend((self.index | 0x80000000).to_be_bytes());
        self.index += 1;
        packet.extend(self.keys.tag(&packet, &[]));
        Ok(packet)
    }
    pub fn decrypt(&mut self, packet: &[u8]) -> Result<Option<Vec<u8>>> {
        if packet.len() < 22 || packet[0] >> 6 != 2 {
            return Ok(None);
        }
        let end = packet.len() - 10;
        if !bool::from(self.keys.tag(&packet[..end], &[]).ct_eq(&packet[end..])) {
            return Ok(None);
        }
        let raw = u32::from_be_bytes(packet[end - 4..end].try_into()?);
        let index = raw & 0x7fffffff;
        let ssrc = u32::from_be_bytes(packet[4..8].try_into()?);
        if !self.replay.contains_key(&ssrc) && self.replay.len() >= 4096 {
            return Ok(None);
        }
        if !self.replay.entry(ssrc).or_default().accept(index as u64) {
            return Ok(None);
        }
        if raw & 0x80000000 == 0 {
            return Ok(Some(packet[..end - 4].to_vec()));
        }
        let iv = self.keys.salt ^ ((ssrc as u128) << 64) ^ ((index as u128) << 16);
        let mut plain = packet[..8].to_vec();
        plain.extend(ctr(&self.keys.key, iv, &packet[8..end - 4])?);
        Ok(Some(plain))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn records_authenticate_and_stream() {
        let (mut tx, mut rx) = Control::pair(&[3; 16], &[5; 36]).unwrap();
        for text in [b"hello".as_slice(), &[9; 65000], b""] {
            let wire = tx.encrypt(text).unwrap();
            assert_eq!(rx.decrypt(&wire[2..]).unwrap().unwrap(), text);
        }
        let mut wire = tx.encrypt(b"forged").unwrap();
        wire[6] ^= 1;
        assert!(rx.decrypt(&wire[2..]).unwrap().is_none());
    }
    #[test]
    fn rtp_wrap_reorder_and_replay() {
        let mut rx = Rtp::new(&[7; 46]).unwrap();
        let tx = Rtp::new(&[7; 46]).unwrap();
        for index in [65534, 65536, 65535, 65537] {
            let p = tx.encrypt(42, index, 1, b"payload").unwrap();
            assert_eq!(rx.decrypt(&p).unwrap().unwrap().payload, b"payload");
            assert!(rx.decrypt(&p).unwrap().is_none());
        }
        let mut p = tx.encrypt(42, 65538, 1, b"forged").unwrap();
        p[12] ^= 1;
        assert!(rx.decrypt(&p).unwrap().is_none());
    }
    #[test]
    fn authenticated_server_padding_need_not_be_zero() {
        let (tx, mut rx) = Control::pair(&[3; 16], &[5; 36]).unwrap();
        let mut body = vec![0, 1, b'x'];
        body.extend([0xaa; 9]);
        let mut hash = Sha1::new();
        hash.update(0u32.to_be_bytes());
        hash.update(&body);
        body.extend(hash.finalize());
        let cipher = Aes128::new((&*tx.key).into());
        let mut iv = tx.iv;
        for block in body.chunks_exact_mut(16) {
            for (x, y) in block.iter_mut().zip(iv) {
                *x ^= y;
            }
            cipher.encrypt_block(block.into());
            iv.copy_from_slice(block);
        }
        assert_eq!(rx.decrypt(&body).unwrap().unwrap(), b"x");
    }
    #[test]
    fn rtcp_authentication_and_replay() {
        let mut tx = Rtcp::new(&[8; 46]).unwrap();
        let mut rx = Rtcp::new(&[8; 46]).unwrap();
        let p = [0x80, 201, 0, 3, 0, 0, 0, 2, 1, 2, 3, 4, 5, 6, 7, 8];
        let wire = tx.encrypt(&p).unwrap();
        assert_eq!(rx.decrypt(&wire).unwrap().unwrap(), p);
        assert!(rx.decrypt(&wire).unwrap().is_none());
    }
}
