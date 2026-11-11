//! Media negotiation: bounded protobuf/binary-plist framing, no AVConference
//! private-framework dependency. Ported from the bundled AGPL iShareScreen.
use anyhow::{ensure, Context, Result};
use flate2::{read::ZlibDecoder, write::ZlibEncoder, Compression};
use rand::{rngs::OsRng, RngCore};
use std::io::{Read, Write};
use zeroize::Zeroizing;

fn varint(mut n: u64, out: &mut Vec<u8>) {
    while n > 127 {
        out.push(n as u8 | 128);
        n >>= 7;
    }
    out.push(n as u8);
}
fn integer(out: &mut Vec<u8>, field: u64, value: u64) {
    varint(field << 3, out);
    varint(value, out);
}
fn bytes(out: &mut Vec<u8>, field: u64, value: &[u8]) {
    varint(field << 3 | 2, out);
    varint(value.len() as u64, out);
    out.extend(value);
}
fn fields(pairs: &[(u64, u64)]) -> Vec<u8> {
    let mut out = Vec::new();
    for &(f, v) in pairs {
        integer(&mut out, f, v);
    }
    out
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum VideoCodec {
    #[default]
    H264,
    H265,
}
impl VideoCodec {
    pub fn from_config(config: &serde_json::Value) -> Self {
        if config["videoCodec"] == "h265" {
            Self::H265
        } else {
            Self::H264
        }
    }
    pub fn name(self) -> &'static str {
        if self == Self::H264 {
            "H.264"
        } else {
            "H.265"
        }
    }
}
fn media_blob(video: bool, ssrc: u32, codec: VideoCodec) -> Vec<u8> {
    let mut blob = fields(&[(1, 1), (2, 1)]);
    if video {
        let res = fields(&[(1, 1), (2, 1), (3, 50115), (4, 0)]);
        let alt = fields(&[(1, 1), (2, 2), (3, 50115), (4, 0)]);
        let mut bank = fields(&[(1, if codec == VideoCodec::H264 { 123 } else { 100 })]);
        bytes(&mut bank, 2, &res);
        bytes(&mut bank, 2, &alt);
        if codec == VideoCodec::H264 {
            bytes(&mut bank, 2, &res);
            bytes(&mut bank, 2, &alt);
        }
        // Apple bank 100 yields HEVC (despite carrying AVC-labelled params).
        bytes(
            &mut bank,
            3,
            if codec == VideoCodec::H264 {
                b"FLS;MS:-1;LF:-1;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;"
            } else {
                b"FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;AR:16/9,5/8;XR:16/9,5/8;"
            },
        );
        integer(&mut bank, 4, if codec == VideoCodec::H264 { 1 } else { 14 });
        let mut desc = fields(&[(1, ssrc as u64), (2, u64::from(codec == VideoCodec::H265))]);
        bytes(&mut desc, 3, &bank);
        desc.extend(fields(&[
            (6, if codec == VideoCodec::H264 { 1 } else { 4 }),
            (7, u64::from(codec == VideoCodec::H265)),
            (8, 63),
            (9, 1),
            (12, 1),
        ]));
        bytes(&mut blob, 5, &desc);
    } else {
        bytes(
            &mut blob,
            3,
            &fields(&[(1, ssrc as u64), (2, 0), (3, 0), (4, 24191), (5, 0), (6, 0)]),
        );
    }
    bytes(
        &mut blob,
        6,
        concat!("TermPilot ", env!("CARGO_PKG_VERSION")).as_bytes(),
    );
    integer(&mut blob, 8, 0);
    for (kind, rate, buffer) in [
        (0, 40_000_000, Some(12288)),
        (0, 6_000_000, Some(131072)),
        (4074, 0, Some(16384)),
        (16, 4100, None),
        (0, 75_000_000, Some(524288)),
        (0, 20_000_000, Some(98304)),
        (4, 6500, None),
        (0, 60_000_000, Some(262144)),
        (1, 299, None),
        (0, 100_000_000, Some(1048576)),
    ] {
        let mut entry = fields(&[(1, kind), (2, rate)]);
        if let Some(buffer) = buffer {
            integer(&mut entry, 3, buffer);
        }
        bytes(&mut blob, 9, &entry);
    }
    integer(
        &mut blob,
        13,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64,
    );
    blob.extend(fields(&[(14, 2), (16, 0), (18, 1)]));
    blob
}
fn offer(video: bool, ssrc: u32, codec: VideoCodec) -> Result<Vec<u8>> {
    let mut compressed = ZlibEncoder::new(Vec::new(), Compression::default());
    compressed.write_all(&media_blob(video, ssrc, codec))?;
    let mut endpoint = fields(&[(1, 0), (2, 1)]);
    bytes(&mut endpoint, 3, b"Generic");
    bytes(&mut endpoint, 4, b"1.0.0");
    bytes(&mut endpoint, 5, b"0");
    let mut dict = plist::Dictionary::new();
    dict.insert(
        "avcMediaStreamOptionRemoteEndpointInfo".into(),
        plist::Value::Data(endpoint),
    );
    dict.insert(
        "avcMediaStreamNegotiatorMode".into(),
        plist::Value::Integer((if video { 7u64 } else { 8u64 }).into()),
    );
    dict.insert(
        "avcMediaStreamNegotiatorMediaBlob".into(),
        plist::Value::Data(compressed.finish()?),
    );
    dict.insert(
        "avcMediaStreamOptionCallID".into(),
        plist::Value::String(uuid::Uuid::new_v4().to_string().to_uppercase()),
    );
    let mut out = Vec::new();
    plist::Value::Dictionary(dict).to_writer_binary(&mut out)?;
    Ok(out)
}
pub struct Keys {
    pub audio_viewer: Zeroizing<[u8; 46]>,
    pub audio_server: Zeroizing<[u8; 46]>,
    pub video_viewer: Zeroizing<[u8; 46]>,
    pub video_server: Zeroizing<[u8; 46]>,
    pub audio_ssrc: u32,
    pub video_ssrc: u32,
}
impl Default for Keys {
    fn default() -> Self {
        Self::new()
    }
}

impl Keys {
    pub fn new() -> Self {
        let key = || {
            let mut data = [0; 46];
            OsRng.fill_bytes(&mut data);
            Zeroizing::new(data)
        };
        Self {
            audio_viewer: key(),
            audio_server: key(),
            video_viewer: key(),
            video_server: key(),
            audio_ssrc: OsRng.next_u32(),
            video_ssrc: OsRng.next_u32(),
        }
    }
    pub fn message(&self) -> Result<Vec<u8>> {
        self.message_for_codec(VideoCodec::H265)
    }
    pub fn message_for_codec(&self, codec: VideoCodec) -> Result<Vec<u8>> {
        let audio = offer(false, self.audio_ssrc, codec)?;
        let video = offer(true, self.video_ssrc, codec)?;
        let size = audio.len() + video.len() + 0xd8;
        ensure!(size < 65000, "Media offer limit");
        let mut out = vec![0; size + 4];
        out[0] = 0x1c;
        out[2..4].copy_from_slice(&(size as u16).to_be_bytes());
        out[4..6].copy_from_slice(&3u16.to_be_bytes());
        out[6..10].copy_from_slice(&7u32.to_be_bytes());
        out[10..12].copy_from_slice(&(audio.len() as u16).to_be_bytes());
        out[12..14].copy_from_slice(&(video.len() as u16).to_be_bytes());
        out[0x14..0x24].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
        out[0x24..0x52].copy_from_slice(&*self.audio_viewer);
        out[0x52..0x80].copy_from_slice(&*self.audio_server);
        out[0x80..0x80 + audio.len()].copy_from_slice(&audio);
        let offset = 0x80 + audio.len();
        out[offset..offset + 46].copy_from_slice(&*self.video_viewer);
        out[offset + 46..offset + 92].copy_from_slice(&*self.video_server);
        out[offset + 92..].copy_from_slice(&video);
        Ok(out)
    }
}
pub fn encodings() -> Vec<u8> {
    let values: [i32; 13] = [
        1010, 1011, 1002, 6, 16, 1104, 1100, -223, 1101, 1105, 1107, 1109, 1110,
    ];
    let mut out = vec![2, 0];
    out.extend((values.len() as u16).to_be_bytes());
    for n in values {
        out.extend(n.to_be_bytes());
    }
    out
}
pub fn viewer_info() -> Vec<u8> {
    let mut out = vec![0x21, 0];
    out.extend(0x3eu16.to_be_bytes());
    out.extend(1u16.to_be_bytes());
    for n in [2u32, 6, 1, 0, 15, 3, 0] {
        out.extend(n.to_be_bytes());
    }
    let mut mask = [0; 32];
    mask[0] = 0xb0;
    mask[2] = 0x0c;
    mask[3] = 3;
    mask[4] = 0x90;
    mask[10] = 0x40;
    out.extend(mask);
    out.extend([0x12, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1]);
    out
}
/// Logical desktop size; codec padding must never become pointer coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DisplayMode {
    pub width: u16,
    pub height: u16,
}
impl Default for DisplayMode {
    fn default() -> Self { Self { width: 1920, height: 1080 } }
}
impl DisplayMode {
    pub const PRESETS: [(u16, u16); 4] = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)];

    pub fn from_config(config: &serde_json::Value) -> Result<Self> {
        if config["width"].is_null() && config["height"].is_null() { return Ok(Self::default()); }
        let width = config["width"].as_u64().context("displayMode")?;
        let height = config["height"].as_u64().context("displayMode")?;
        ensure!(Self::PRESETS.iter().any(|&(w, h)| u64::from(w) == width && u64::from(h) == height), "displayMode");
        Ok(Self { width: width as u16, height: height as u16 })
    }

    pub fn accepts_encoded(self, width: u16, height: u16, tiles: u16) -> bool {
        (1..=4).contains(&tiles) && width == self.width && height >= self.height
            && height <= self.height.div_ceil(tiles * 16) * tiles * 16
    }
}

pub fn virtual_display(mode: DisplayMode) -> Vec<u8> {
    // Mode zero is both current and preferred. Put the requested size first;
    // the remaining presets stay available to the remote virtual display.
    let modes = std::iter::once((mode.width, mode.height))
        .chain(DisplayMode::PRESETS.into_iter().filter(|&(w, h)| (w, h) != (mode.width, mode.height)))
        .collect::<Vec<_>>();
    let size = 0x9c + 28 * modes.len();
    let mut d = vec![0; size];
    d[..2].copy_from_slice(&(size as u16).to_be_bytes());
    let name = b"TermPilot Virtual Display";
    d[2..2 + name.len()].copy_from_slice(name);
    for (offset, value) in [
        (0x7a, 1u32),
        (0x7e, 4),
        (0x8a, 3840),
        (0x8e, 2160),
        (0x96, 7),
    ] {
        d[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
    }
    d[0x82..0x86].copy_from_slice(&369.45456f32.to_be_bytes());
    d[0x86..0x8a].copy_from_slice(&207.81818f32.to_be_bytes());
    d[0x9a..0x9c].copy_from_slice(&(modes.len() as u16).to_be_bytes());
    for (i, (w, h)) in modes.into_iter().enumerate() {
        let p = 0x9c + i * 28;
        for (j, n) in [u32::from(w), u32::from(h), u32::from(w), u32::from(h)].into_iter().enumerate() {
            d[p + j * 4..p + j * 4 + 4].copy_from_slice(&n.to_be_bytes());
        }
        d[p + 16..p + 24].copy_from_slice(&60f64.to_be_bytes());
    }
    let mut out = vec![0x1d, 0];
    out.extend(((size + 8) as u16).to_be_bytes());
    out.extend([0, 1, 0, 1, 0, 0, 0, 0]);
    out.extend(d);
    out
}
pub fn framebuffer(incremental: bool, full: bool) -> Vec<u8> {
    let mut out = vec![3, incremental as u8, 0, 0, 0, 0];
    let size = if full { u16::MAX } else { 1 };
    out.extend(size.to_be_bytes());
    out.extend(size.to_be_bytes());
    out
}

fn read_varint(data: &mut &[u8]) -> Result<u64> {
    let mut out = 0;
    for shift in (0..70).step_by(7) {
        let (&b, tail) = data.split_first().context("Truncated protobuf")?;
        *data = tail;
        ensure!(shift < 63 || b <= 1, "Protobuf integer overflow");
        out |= (b as u64 & 127) << shift;
        if b & 128 == 0 {
            return Ok(out);
        }
    }
    anyhow::bail!("Protobuf integer overflow")
}
fn take<'a>(data: &mut &'a [u8], n: usize) -> Result<&'a [u8]> {
    ensure!(n <= data.len(), "Truncated media answer");
    let (a, b) = data.split_at(n);
    *data = b;
    Ok(a)
}
fn proto(data: &[u8], wanted: u64) -> Result<(Option<u64>, Option<&[u8]>)> {
    let mut rest = data;
    while !rest.is_empty() {
        let tag = read_varint(&mut rest)?;
        ensure!(tag >> 3 != 0, "Invalid protobuf tag");
        match tag & 7 {
            0 => {
                let n = read_varint(&mut rest)?;
                if tag >> 3 == wanted {
                    return Ok((Some(n), None));
                }
            }
            2 => {
                let n = read_varint(&mut rest)?;
                ensure!(n <= rest.len() as u64, "Protobuf size");
                let b = take(&mut rest, n as usize)?;
                if tag >> 3 == wanted {
                    return Ok((None, Some(b)));
                }
            }
            1 => {
                take(&mut rest, 8)?;
            }
            5 => {
                take(&mut rest, 4)?;
            }
            _ => anyhow::bail!("Unsupported protobuf wire type"),
        }
    }
    Ok((None, None))
}
fn be(data: &[u8]) -> Option<usize> {
    if data.is_empty() || data.len() > 8 {
        return None;
    }
    let n = data.iter().fold(0u64, |n, b| (n << 8) | *b as u64);
    usize::try_from(n).ok()
}
// Decode only the dictionary/string/data objects needed here. No recursive
// object traversal, attacker-controlled allocations, or cyclic plist graphs.
fn media_data(plist: &[u8]) -> Option<&[u8]> {
    if plist.len() < 40 || !plist.starts_with(b"bplist00") {
        return None;
    }
    let trailer = &plist[plist.len() - 32..];
    let os = trailer[6] as usize;
    let rs = trailer[7] as usize;
    let count = be(&trailer[8..16])?;
    let root = be(&trailer[16..24])?;
    let table = be(&trailer[24..32])?;
    if ![1, 2, 4, 8].contains(&os)
        || ![1, 2, 4, 8].contains(&rs)
        || count == 0
        || count > 2048
        || root >= count
        || table < 8
        || table.checked_add(count.checked_mul(os)?)? != plist.len() - 32
    {
        return None;
    }
    let object = |index: usize| -> Option<(u8, &[u8])> {
        if index >= count {
            return None;
        }
        let p = table + index * os;
        let offset = be(plist.get(p..p + os)?)?;
        if offset < 8 || offset >= table {
            return None;
        }
        let marker = plist[offset];
        let mut start = offset + 1;
        let mut n = (marker & 15) as usize;
        if n == 15 {
            let integer = *plist.get(start)?;
            start += 1;
            if integer >> 4 != 1 || integer & 15 > 3 {
                return None;
            }
            let width = 1usize << (integer & 15);
            n = be(plist.get(start..start + width)?)?;
            start += width;
        }
        let bytes = match marker >> 4 {
            4 | 5 => n,
            6 => n.checked_mul(2)?,
            13 => n.checked_mul(2)?.checked_mul(rs)?,
            _ => return None,
        };
        if start.checked_add(bytes)? > table {
            return None;
        }
        Some((marker >> 4, plist.get(start..start + bytes)?))
    };
    let (kind, dict) = object(root)?;
    if kind != 13 || dict.len() / rs / 2 > 64 {
        return None;
    }
    let n = dict.len() / rs / 2;
    for i in 0..n {
        let key = be(&dict[i * rs..(i + 1) * rs])?;
        let (kind, text) = object(key)?;
        if kind == 5 && text == b"avcMediaStreamNegotiatorMediaBlob" {
            let index = be(&dict[(i + n) * rs..(i + n + 1) * rs])?;
            let (kind, data) = object(index)?;
            return (kind == 4).then_some(data);
        }
    }
    None
}
pub fn dimensions(message: &[u8]) -> Result<Option<(u16, u16, u16)>> {
    dimensions_for_codec(message, VideoCodec::H265)
}
pub fn dimensions_for_codec(message: &[u8], codec: VideoCodec) -> Result<Option<(u16, u16, u16)>> {
    ensure!(message.len() <= 65536, "Media answer limit");
    if message.first() != Some(&0) {
        return Ok(None);
    }
    for (start, _) in message
        .windows(8)
        .enumerate()
        .filter(|(_, b)| *b == b"bplist00")
    {
        for end in start + 40..=message.len() {
            let Some(compressed) = media_data(&message[start..end]) else {
                continue;
            };
            let mut decoded = Vec::new();
            ZlibDecoder::new(compressed)
                .take(1024 * 1024 + 1)
                .read_to_end(&mut decoded)?;
            ensure!(decoded.len() <= 1024 * 1024, "Media protobuf limit");
            if let Some(desc) = proto(&decoded, 5)?.1 {
                let w = proto(desc, 4)?.0.unwrap_or(0);
                let h = proto(desc, 5)?.0.unwrap_or(0);
                let tiles = proto(desc, 6)?.0.unwrap_or(0);
                // The AVC single-picture answer can omit the tile count.
                let tiles = if tiles == 0 && codec == VideoCodec::H264 {
                    1
                } else {
                    tiles
                };
                ensure!(
                    codec != VideoCodec::H264 || tiles == 1,
                    "Expected single-picture H.264"
                );
                if w != 0 && h != 0 {
                    ensure!(
                        w <= 8192 && h <= 8192 && w * h <= 16_777_216 && (1..=4).contains(&tiles),
                        "Unsupported media dimensions"
                    );
                    return Ok(Some((w as u16, h as u16, tiles as u16)));
                }
            }
        }
    }
    Ok(None)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selected_resolution_is_the_current_and_preferred_wire_mode() {
        for (width, height) in DisplayMode::PRESETS {
            let mode = DisplayMode::from_config(&serde_json::json!({"width":width,"height":height})).unwrap();
            let wire = virtual_display(mode);
            assert_eq!(usize::from(u16::from_be_bytes(wire[2..4].try_into().unwrap())), wire.len()-4);
            let descriptor = &wire[12..];
            assert_eq!(usize::from(u16::from_be_bytes(descriptor[..2].try_into().unwrap())), descriptor.len());
            assert_eq!(&descriptor[0x92..0x96], &[0; 4]);
            assert_eq!(u16::from_be_bytes(descriptor[0x9a..0x9c].try_into().unwrap()), 4);
            let modes = descriptor[0x9c..].chunks_exact(28).map(|entry| {
                assert_eq!(&entry[..8], &entry[8..16]);
                assert_eq!(f64::from_be_bytes(entry[16..24].try_into().unwrap()), 60.0);
                (u32::from_be_bytes(entry[..4].try_into().unwrap()), u32::from_be_bytes(entry[4..8].try_into().unwrap()))
            }).collect::<Vec<_>>();
            assert_eq!(modes[0], (u32::from(width), u32::from(height)));
            for (w,h) in DisplayMode::PRESETS { assert!(modes.contains(&(u32::from(w),u32::from(h)))); }
            assert!(mode.accepts_encoded(width, height, 1));
            assert!(mode.accepts_encoded(width, height.div_ceil(64)*64, 4));
            assert!(!mode.accepts_encoded(width, height + 64, 4));
            assert!(!mode.accepts_encoded(width / 2, height / 2, 4));
            assert!(!mode.accepts_encoded(width, height, 0));
        }
        assert_eq!(DisplayMode::from_config(&serde_json::json!({})).unwrap(), DisplayMode::default());
        for invalid in [serde_json::json!({"width":3840}), serde_json::json!({"width":2560,"height":1080}),
            serde_json::json!({"width":-1,"height":720}), serde_json::json!({"width":7680,"height":4320})] {
            assert!(DisplayMode::from_config(&invalid).is_err());
        }
    }
    #[test]
    fn codec_default_and_bank_are_explicit() {
        assert_eq!(
            VideoCodec::from_config(&serde_json::json!({})),
            VideoCodec::H264
        );
        assert_eq!(
            VideoCodec::from_config(&serde_json::json!({"videoCodec":"invalid"})),
            VideoCodec::H264
        );
        for (codec, bank, tiles, ltr) in
            [(VideoCodec::H264, 123, 1, 0), (VideoCodec::H265, 100, 4, 1)]
        {
            let blob = media_blob(true, 42, codec);
            let desc = proto(&blob, 5).unwrap().1.unwrap();
            assert_eq!(
                proto(proto(desc, 3).unwrap().1.unwrap(), 1).unwrap().0,
                Some(bank)
            );
            assert_eq!(proto(desc, 6).unwrap().0, Some(tiles));
            assert_eq!(proto(desc, 7).unwrap().0, Some(ltr));
        }
    }
    #[test]
    fn bounded_plist_parser() {
        let data = offer(true, 123, VideoCodec::H265).unwrap();
        let compressed = media_data(&data).unwrap();
        let mut decoded = Vec::new();
        ZlibDecoder::new(compressed)
            .read_to_end(&mut decoded)
            .unwrap();
        assert_eq!(
            proto(proto(&decoded, 5).unwrap().1.unwrap(), 1).unwrap().0,
            Some(123)
        );
        for end in 0..data.len() {
            assert!(media_data(&data[..end]).is_none());
        }
    }
    #[test]
    fn oversize_proto_rejected() {
        assert!(proto(&[10, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255], 1).is_err());
    }
}
