#[cfg(not(any(windows, feature = "portable-media-validation")))]
use std::ffi::c_void;
#[cfg(any(windows, feature = "portable-media-validation"))]
#[path = "media_codec.rs"]
mod codec;
use super::{crypto::Packet, offers::VideoCodec};
mod avc;
#[path = "decode_order.rs"]
mod decode_order;
#[path = "decode_worker.rs"]
mod decode_worker;
use crate::screen::Output;
use anyhow::{ensure, Context, Result};
#[cfg(any(windows, feature = "portable-media-validation"))]
use codec::Native;
use decode_order::{DecodeOrder, REPAIR_WINDOW};
use decode_worker::{Decoder, Queue, Sink};
#[cfg(not(any(windows, feature = "portable-media-validation")))]
use serde_json::json;
use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
    sync::{
        atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tokio::sync::mpsc;

pub enum Input {
    Video(Packet),
    Audio(Vec<u8>),
    Refresh,
    Tick,
}
#[derive(Debug)]
pub enum Feedback {
    Sources(Vec<u32>),
    Refresh,
    Fir(Vec<u32>),
    Nack(u32, Vec<u16>),
    Ack(u16),
}
#[derive(Default)]
pub struct Stats {
    pub native_decoder: std::sync::Mutex<String>,
    pub native_submitted: AtomicU64,
    pub native_outputs: AtomicU64,
    pub native_color: AtomicU64,
    pub frames: AtomicU64,
    pub errors: AtomicU64,
    pub audio_errors: AtomicU64,
    pub last_video_error: AtomicI32,
    pub audio_frames: AtomicU64,
    pub dropped: AtomicU64,
    pub receive_queue_drops: AtomicU64,
    pub decode_queue_drops: AtomicU64,
    pub oversized_packets: AtomicU64,
    pub assembly_drops: AtomicU64,
    pub late_units: AtomicU64,
    pub missing_units: AtomicU64,
    pub codec_queue_drops: AtomicU64,
    pub recovery_skips: AtomicU64,
    pub overload_recoveries: AtomicU64,
    pub decoder_resets: AtomicU64,
    pub decode_micros: AtomicU64,
    pub decode_calls: AtomicU64,
    pub max_decode_micros: AtomicU64,
    pub max_queue_micros: AtomicU64,
    pub max_codec_queue_bytes: AtomicU64,
    pub parameters: AtomicU64,
    pub units: AtomicU64,
    pub nal_types: AtomicU64,
}
impl Stats {
    pub fn native_decoder_name(&self) -> String {
        self.native_decoder
            .lock()
            .map(|name| name.clone())
            .unwrap_or_default()
    }
}
struct Callback {
    output: Output,
    audio_enabled: Arc<AtomicBool>,
    stats: Arc<Stats>,
}
#[cfg(not(any(windows, feature = "portable-media-validation")))]
type CallbackFn = unsafe extern "C" fn(*mut c_void, u32, *const u64, *const u8, usize);
#[cfg(not(any(windows, feature = "portable-media-validation")))]
type Create = unsafe extern "C" fn(CallbackFn, *mut c_void) -> *mut c_void;
#[cfg(not(any(windows, feature = "portable-media-validation")))]
type Destroy = unsafe extern "C" fn(*mut c_void);
#[cfg(not(any(windows, feature = "portable-media-validation")))]
type Configure = unsafe extern "C" fn(*mut c_void, *const u8, usize) -> i32;
#[cfg(not(any(windows, feature = "portable-media-validation")))]
type Decode = unsafe extern "C" fn(*mut c_void, *const u8, usize, u32, u32) -> i32;
#[cfg(not(any(windows, feature = "portable-media-validation")))]
type Audio = unsafe extern "C" fn(*mut c_void, *const u8, usize) -> i32;
#[cfg(all(
    any(target_os = "macos", target_os = "ios", target_os = "android"),
    not(feature = "portable-media-validation")
))]
unsafe extern "C" {
    fn tp_media_create(callback: CallbackFn, context: *mut c_void) -> *mut c_void;
    fn tp_media_destroy(handle: *mut c_void);
    fn tp_video_configure(handle: *mut c_void, data: *const u8, length: usize) -> i32;
    fn tp_video_decode(
        handle: *mut c_void,
        data: *const u8,
        length: usize,
        tile: u32,
        donl: u32,
    ) -> i32;
    fn tp_audio_decode(handle: *mut c_void, data: *const u8, length: usize) -> i32;
    #[cfg(target_os = "android")]
    fn tp_video_poll(handle: *mut c_void) -> i32;
}
#[cfg(not(any(windows, feature = "portable-media-validation")))]
struct Native {
    handle: *mut c_void,
    callback: Box<Callback>,
    destroy: Destroy,
    configure: Configure,
    decode: Decode,
    audio: Audio,
}
#[cfg(not(any(windows, feature = "portable-media-validation")))]
unsafe extern "C" fn output_callback(
    context: *mut c_void,
    kind: u32,
    metadata: *const u64,
    data: *const u8,
    length: usize,
) {
    // The adapter owns these pointers for this call. Copy before returning.
    if context.is_null() || metadata.is_null() || data.is_null() || length > 64 * 1024 * 1024 {
        return;
    }
    let callback = unsafe { &*(context as *const Callback) };
    if kind == 3 && length <= 256 {
        let m = unsafe { std::slice::from_raw_parts(metadata, 10) };
        let name = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(data, length) });
        if let Ok(mut current) = callback.stats.native_decoder.lock() {
            if *current != name {
                *current = name.into_owned();
            }
        }
        callback
            .stats
            .native_submitted
            .store(m[0], Ordering::Relaxed);
        callback.stats.native_outputs.store(m[1], Ordering::Relaxed);
        callback.stats.native_color.store(m[2], Ordering::Relaxed);
        return;
    }
    if kind == 2 {
        if length <= 4096 * 8 && length.is_multiple_of(8) {
            callback
                .stats
                .audio_frames
                .fetch_add((length / 8) as u64, Ordering::Relaxed);
            if callback.audio_enabled.load(Ordering::Relaxed) {
                callback
                    .output
                    .audio(unsafe { std::slice::from_raw_parts(data, length) }.to_vec());
            }
        }
        return;
    }
    if kind != 1 {
        return;
    }
    let m = unsafe { std::slice::from_raw_parts(metadata, 10) };
    if m[0] >= 16
        || m[2] == 0
        || m[3] == 0
        || m[2] > 8192
        || m[3] > 8192
        || m[4] > 65536
        || m[5] > 131072
        || !((m[6] == m[2] && m[7] == m[3])
            || (m[6] == m[2].div_ceil(2) && m[7] == m[3].div_ceil(2)))
        || m[4] < m[2]
        || m[5] < m[6] * 2
        || m[8] != m[4] * m[3]
        || m[9] != m[5] * m[7]
        || m[8] + m[9] != length as u64
    {
        return;
    }
    callback.stats.frames.fetch_add(1, Ordering::Relaxed);
    callback.output.frame(json!({"kind":"frame","tile":m[0],"width":m[2],"height":m[3],"yStride":m[4],"uvStride":m[5],"chromaWidth":m[6],"chromaHeight":m[7],"biplanar":true,"yLength":m[8],"uLength":m[9],"vLength":0}),unsafe{std::slice::from_raw_parts(data,length)}.to_vec());
}
#[cfg(not(any(windows, feature = "portable-media-validation")))]
impl Native {
    fn new(output: Output, audio_enabled: Arc<AtomicBool>, stats: Arc<Stats>) -> Result<Self> {
        #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android")))]
        {
            let _ = (output, audio_enabled, stats);
            anyhow::bail!("runtimeDependency");
        }
        #[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
        {
            let mut callback = Box::new(Callback {
                output,
                audio_enabled,
                stats,
            });
            unsafe {
                let create: Create = tp_media_create;
                let destroy: Destroy = tp_media_destroy;
                let configure: Configure = tp_video_configure;
                let decode: Decode = tp_video_decode;
                let audio: Audio = tp_audio_decode;
                let handle = create(output_callback, (&mut *callback as *mut Callback).cast());
                ensure!(!handle.is_null(), "Media adapter creation failed");
                Ok(Self {
                    handle,
                    callback,
                    destroy,
                    configure,
                    decode,
                    audio,
                })
            }
        }
    }
    fn configure(&mut self, params: &BTreeMap<(u8, u32), Vec<u8>>) -> Result<()> {
        let mut bytes = Vec::new();
        for data in params.values() {
            bytes.extend((data.len() as u32).to_be_bytes());
            bytes.extend(data);
        }
        ensure!(bytes.len() <= 65536, "HEVC parameter limit");
        let status = unsafe { (self.configure)(self.handle, bytes.as_ptr(), bytes.len()) };
        ensure!(status == 0, "Video decoder configuration failed ({status})");
        Ok(())
    }
    fn decode(&mut self, nal: &[u8], tile: usize, donl: u16) -> i32 {
        unsafe {
            (self.decode)(
                self.handle,
                nal.as_ptr(),
                nal.len(),
                tile as u32,
                donl as u32,
            )
        }
    }
    fn audio(&mut self, payload: &[u8]) {
        let status = unsafe { (self.audio)(self.handle, payload.as_ptr(), payload.len()) };
        if status < 0 {
            self.callback.stats.errors.fetch_add(1, Ordering::Relaxed);
            self.callback
                .stats
                .audio_errors
                .fetch_add(1, Ordering::Relaxed);
        }
    }
    #[cfg(target_os = "android")]
    fn poll(&mut self) -> i32 {
        unsafe { tp_video_poll(self.handle) }
    }
}
#[cfg(not(any(windows, feature = "portable-media-validation")))]
impl Drop for Native {
    fn drop(&mut self) {
        unsafe { (self.destroy)(self.handle) }
    }
}

struct Group {
    marker_seen: bool,
    packets: BTreeMap<u16, Packet>,
    at: Instant,
    size: usize,
}
pub struct Unit {
    pub codec: VideoCodec,
    pub ssrc: u32,
    pub donl: u16,
    pub nals: Vec<Vec<u8>>,
    size: usize,
}
fn ordered(group: &Group) -> Vec<&Packet> {
    let mut packets = group.packets.values().collect::<Vec<_>>();
    let n = packets.len();
    if n <= 1 {
        return packets;
    }
    let start = (0..n)
        .max_by_key(|i| {
            packets[(i + 1) % n]
                .sequence
                .wrapping_sub(packets[*i].sequence)
        })
        .map(|i| (i + 1) % n)
        .unwrap();
    packets.rotate_left(start);
    packets
}
fn donl(packet: &[u8]) -> Option<u16> {
    if packet.len() < 4 {
        return None;
    }
    let start = if packet[0] >> 1 & 63 == 49 { 3 } else { 2 };
    Some(u16::from_be_bytes(
        packet.get(start..start + 2)?.try_into().ok()?,
    ))
}
pub fn reassemble(payloads: &[&[u8]]) -> Result<Vec<Vec<u8>>> {
    let mut out = Vec::new();
    let mut fragment = Vec::new();
    let mut fragment_type = None;
    for p in payloads {
        ensure!(p.len() >= 4, "Truncated HEVC packet");
        let kind = p[0] >> 1 & 63;
        match kind {
            48 => {
                ensure!(fragment.is_empty(), "Interrupted HEVC fragment");
                let mut offset = 4;
                while offset < p.len() {
                    ensure!(offset + 2 <= p.len(), "Truncated HEVC aggregation");
                    let n = u16::from_be_bytes(p[offset..offset + 2].try_into()?) as usize;
                    offset += 2;
                    ensure!(n >= 2 && offset + n <= p.len(), "Invalid HEVC aggregation");
                    out.push(p[offset..offset + n].to_vec());
                    offset += n;
                }
            }
            49 => {
                ensure!(p.len() >= 6, "Truncated HEVC fragment");
                let inner = p[2] & 63;
                if p[2] & 128 != 0 {
                    ensure!(fragment.is_empty(), "Unfinished HEVC fragment");
                    fragment.extend([(p[0] & 129) | (inner << 1), p[1]]);
                    fragment_type = Some(inner);
                } else {
                    ensure!(
                        !fragment.is_empty() && fragment_type == Some(inner),
                        "Missing HEVC fragment start"
                    );
                }
                fragment.extend(&p[5..]);
                ensure!(fragment.len() <= 16 * 1024 * 1024, "HEVC access unit limit");
                if p[2] & 64 != 0 {
                    out.push(std::mem::take(&mut fragment));
                    fragment_type = None;
                }
            }
            0..=47 => {
                ensure!(fragment.is_empty(), "Interrupted HEVC fragment");
                let mut nal = p[..2].to_vec();
                nal.extend(&p[4..]);
                out.push(nal);
            }
            _ => anyhow::bail!("Unsupported HEVC packet"),
        }
        ensure!(out.len() <= 256, "HEVC NAL count limit");
    }
    ensure!(fragment.is_empty(), "Missing HEVC fragment end");
    Ok(out)
}
fn pps_id(nal: &[u8]) -> Result<u32> {
    let mut rbsp = Vec::new();
    let mut zeros = 0;
    for &b in &nal[2..] {
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        rbsp.push(b);
        zeros = if b == 0 { zeros + 1 } else { 0 };
    }
    let mut bit = 0;
    let get =
        |i: usize| -> Option<u32> { rbsp.get(i / 8).map(|b| ((b >> (7 - i % 8)) & 1) as u32) };
    while get(bit) == Some(0) {
        bit += 1;
        ensure!(bit < 16, "HEVC PPS identifier limit");
    }
    ensure!(get(bit) == Some(1), "Truncated HEVC PPS");
    let leading = bit;
    bit += 1;
    let mut id = 1;
    for _ in 0..leading {
        id = (id << 1) | get(bit).context("Truncated HEVC PPS")?;
        bit += 1;
    }
    ensure!(id <= 64, "HEVC PPS identifier limit");
    Ok(id - 1)
}
struct Pipeline<D: Sink> {
    native: D,
    feedback: mpsc::Sender<Feedback>,
    stats: Arc<Stats>,
    tiles: usize,
    groups: HashMap<(u32, u32), Group>,
    group_bytes: usize,
    recent: VecDeque<(u32, u32)>,
    counts: BTreeMap<u32, (u64, Instant)>,
    highest: HashMap<u32, u16>,
    sources: Vec<u32>,
    blacklist: HashSet<u32>,
    pending: VecDeque<Unit>,
    pending_bytes: usize,
    params: BTreeMap<(u8, u32), Vec<u8>>,
    configured: bool,
    started: Instant,
    last_frame: Instant,
    last_select: Instant,
    last_fir: Instant,
    observed_frames: u64,
    decode_order: DecodeOrder,
}
impl<D: Sink> Pipeline<D> {
    fn new(native: D, feedback: mpsc::Sender<Feedback>, stats: Arc<Stats>, tiles: usize) -> Self {
        let now = Instant::now();
        Self {
            native,
            feedback,
            stats,
            tiles,
            groups: HashMap::new(),
            group_bytes: 0,
            recent: VecDeque::new(),
            counts: BTreeMap::new(),
            highest: HashMap::new(),
            sources: Vec::new(),
            blacklist: HashSet::new(),
            pending: VecDeque::new(),
            pending_bytes: 0,
            params: BTreeMap::new(),
            configured: false,
            started: now,
            last_frame: now,
            last_select: now,
            last_fir: now - Duration::from_secs(2),
            observed_frames: 0,
            decode_order: DecodeOrder::default(),
        }
    }
    fn fir(&mut self) {
        if self.last_fir.elapsed() >= Duration::from_millis(500) && !self.sources.is_empty() {
            let _ = self.feedback.try_send(Feedback::Fir(self.sources.clone()));
            self.last_fir = Instant::now();
        }
    }
    fn select(&mut self) {
        let frames = self.stats.frames.load(Ordering::Relaxed);
        if frames != self.observed_frames {
            self.observed_frames = frames;
            self.last_frame = Instant::now();
        }
        if !self.sources.is_empty()
            && (self.last_frame.elapsed() < Duration::from_secs(2)
                || self.last_select.elapsed() < Duration::from_secs(3))
        {
            return;
        }
        if self.started.elapsed() < Duration::from_millis(150) {
            return;
        }
        let threshold = if self.sources.is_empty() { 1 } else { 8 };
        let mut best = None;
        let mut previous = None;
        let mut run_offset = 0;
        for &base in self.counts.keys() {
            if previous.map(|p: u32| p.wrapping_add(1)) == Some(base) {
                run_offset += 1;
            } else {
                run_offset = 0;
            }
            previous = Some(base);
            if run_offset % self.tiles != 0 {
                continue;
            }
            let mut score = 0;
            let mut valid = true;
            for tile in 0..self.tiles {
                let s = base.wrapping_add(tile as u32);
                match self.counts.get(&s) {
                    Some((n, at))
                        if *n >= threshold
                            && at.elapsed() < Duration::from_secs(2)
                            && !self.blacklist.contains(&s)
                            && !self.sources.contains(&s) =>
                    {
                        score += n
                    }
                    _ => {
                        valid = false;
                        break;
                    }
                }
            }
            if valid && best.map(|(_, n)| score > n).unwrap_or(true) {
                best = Some((base, score));
            }
        }
        if let Some((base, _)) = best {
            let replacing = !self.sources.is_empty();
            self.blacklist.extend(&self.sources);
            self.sources = (0..self.tiles)
                .map(|t| base.wrapping_add(t as u32))
                .collect();
            self.last_select = Instant::now();
            self.configured = false;
            self.params.clear();
            self.observed_frames = self.stats.frames.load(Ordering::Relaxed);
            self.decode_order = DecodeOrder::default();
            let _ = self
                .feedback
                .try_send(Feedback::Sources(self.sources.clone()));
            if replacing {
                self.fir();
            }
        }
    }
    fn packet(&mut self, packet: Packet) -> Result<()> {
        self.counts.retain(|s, (_, at)| {
            self.sources.contains(s) || at.elapsed() < Duration::from_secs(10)
        });
        self.highest.retain(|s, _| self.counts.contains_key(s));
        self.blacklist.retain(|s| self.counts.contains_key(s));
        if self.counts.len() >= 64 && !self.counts.contains_key(&packet.ssrc) {
            return Ok(());
        }
        let entry = self
            .counts
            .entry(packet.ssrc)
            .or_insert((0, Instant::now()));
        entry.0 += 1;
        entry.1 = Instant::now();
        if let Some(old) = self.highest.get_mut(&packet.ssrc) {
            let distance = packet.sequence.wrapping_sub(*old);
            if distance > 0 && distance < 32768 {
                if distance > 1 && distance <= 512 {
                    let missing = (1..distance).map(|d| old.wrapping_add(d)).collect();
                    let _ = self.feedback.try_send(Feedback::Nack(packet.ssrc, missing));
                }
                *old = packet.sequence;
            }
        } else {
            self.highest.insert(packet.ssrc, packet.sequence);
        }
        self.select();
        let key = (packet.ssrc, packet.timestamp);
        if self.recent.contains(&key) {
            return Ok(());
        }
        if self.groups.len() >= 128 || self.group_bytes + packet.payload.len() > 32 * 1024 * 1024 {
            self.evict(true);
        }
        let group = self.groups.entry(key).or_insert_with(|| Group {
            marker_seen: false,
            packets: BTreeMap::new(),
            at: Instant::now(),
            size: 0,
        });
        group.marker_seen |= packet.marker;
        if !group.packets.contains_key(&packet.sequence) {
            group.size += packet.payload.len();
            self.group_bytes += packet.payload.len();
            group.packets.insert(packet.sequence, packet);
        }
        // Most fragments are not the end of an access unit. Avoid sorting the
        // growing packet map and scanning pending pictures for every fragment.
        if !group.marker_seen {
            return Ok(());
        }
        let ordered = ordered(group);
        let complete = ordered.last().is_some_and(|p| p.marker)
            && ordered
                .windows(2)
                .all(|p| p[1].sequence == p[0].sequence.wrapping_add(1));
        if complete {
            let payloads = ordered
                .iter()
                .map(|p| p.payload.as_slice())
                .collect::<Vec<_>>();
            let unit = reassemble(&payloads).ok().and_then(|nals| {
                Some(Unit {
                    codec: VideoCodec::H265,
                    ssrc: key.0,
                    donl: donl(payloads.first()?)?,
                    size: group.size,
                    nals,
                })
            });
            // A marker can arrive before the first FU fragment; retain it for
            // the short repair window instead of feeding a truncated sample.
            if let Some(unit) = unit {
                let removed = self.groups.remove(&key).unwrap();
                self.group_bytes -= removed.size;
                self.recent.push_back(key);
                if self.recent.len() > 512 {
                    self.recent.pop_front();
                }
                self.queue(unit)?;
            }
        }
        self.evict(false);
        self.drain()?;
        Ok(())
    }
    fn evict(&mut self, force: bool) {
        let old = self
            .groups
            .iter()
            .filter(|(_, g)| force || g.at.elapsed() > REPAIR_WINDOW)
            .map(|(k, _)| *k)
            .collect::<Vec<_>>();
        let mut affected = false;
        for key in old {
            if let Some(g) = self.groups.remove(&key) {
                self.group_bytes -= g.size;
                affected |= self.sources.contains(&key.0);
                self.stats.dropped.fetch_add(1, Ordering::Relaxed);
                self.stats.assembly_drops.fetch_add(1, Ordering::Relaxed);
                // Late fragments for an expired unit must not keep creating
                // new incomplete groups and repeated refresh requests.
                self.recent.push_back(key);
                if self.recent.len() > 512 {
                    self.recent.pop_front();
                }
            }
        }
        if affected {
            self.fir();
        }
    }
    fn queue(&mut self, unit: Unit) -> Result<()> {
        self.stats.units.fetch_add(1, Ordering::Relaxed);
        for nal in &unit.nals {
            if nal.len() >= 2 {
                self.stats
                    .nal_types
                    .fetch_or(1u64 << (nal[0] >> 1 & 63), Ordering::Relaxed);
            }
        }
        while self.pending.len() >= 512 || self.pending_bytes + unit.size > 32 * 1024 * 1024 {
            if let Some(old) = self.pending.pop_front() {
                self.pending_bytes -= old.size;
            } else {
                break;
            }
            self.fir();
        }
        self.pending_bytes += unit.size;
        self.pending.push_back(unit);
        Ok(())
    }
    fn drain(&mut self) -> Result<()> {
        if self.sources.is_empty() {
            return Ok(());
        }
        let mut kept = VecDeque::new();
        while let Some(unit) = self.pending.pop_front() {
            if self.sources.contains(&unit.ssrc) {
                kept.push_back(unit);
            } else {
                self.pending_bytes -= unit.size;
            }
        }
        self.pending = kept;
        let mut changed = false;
        for unit in &self.pending {
            for nal in &unit.nals {
                if nal.len() < 2 {
                    continue;
                }
                let kind = nal[0] >> 1 & 63;
                if (32..=34).contains(&kind) {
                    ensure!(nal.len() <= 16384, "HEVC parameter limit");
                    let id = if kind == 34 { pps_id(nal)? } else { 0 };
                    if self.params.get(&(kind, id)) != Some(nal) {
                        self.params.insert((kind, id), nal.clone());
                        changed = true;
                    }
                }
            }
        }
        self.stats
            .parameters
            .store(self.params.len() as u64, Ordering::Relaxed);
        if changed && self.configured {
            self.configured = false;
            self.fir();
        }
        if !self.configured {
            if self.started.elapsed() < Duration::from_millis(300)
                || self
                    .sources
                    .iter()
                    .any(|s| !self.pending.iter().any(|u| u.ssrc == *s))
            {
                return Ok(());
            }
            if !self.params.contains_key(&(32, 0))
                || !self.params.contains_key(&(33, 0))
                || !self.params.keys().any(|(k, _)| *k == 34)
            {
                return Ok(());
            }
            self.native.configure(&self.params)?;
            self.configured = true;
            self.decode_order = DecodeOrder::default();
            // Start-up bursts arrive across several SSRCs. Decode one picture
            // per tile in DONL order through the single shared reference buffer.
            let mut units = self.pending.drain(..).collect::<Vec<_>>();
            let mut numbers = units.iter().map(|u| u.donl).collect::<Vec<_>>();
            numbers.sort_unstable();
            numbers.dedup();
            if !numbers.is_empty() {
                let n = numbers.len();
                let gap = (0..n)
                    .max_by_key(|i| numbers[(i + 1) % n].wrapping_sub(numbers[*i]))
                    .unwrap();
                let anchor = numbers[(gap + 1) % n];
                units.sort_by_key(|u| {
                    (
                        u.donl.wrapping_sub(anchor),
                        self.sources.iter().position(|s| *s == u.ssrc).unwrap_or(16),
                    )
                });
            }
            self.pending = units.into();
        }
        loop {
            let mut index = 0;
            while index < self.pending.len() {
                if self.decode_order.is_late(self.pending[index].donl) {
                    let unit = self.pending.remove(index).unwrap();
                    self.pending_bytes -= unit.size;
                    self.stats.late_units.fetch_add(1, Ordering::Relaxed);
                } else {
                    index += 1;
                }
            }
            let Some((index, skipped)) = self
                .decode_order
                .take(self.pending.iter().map(|u| u.donl), Instant::now())
            else {
                break;
            };
            if skipped != 0 {
                self.stats
                    .missing_units
                    .fetch_add(skipped as u64, Ordering::Relaxed);
                self.native.recover();
                self.fir();
            }
            let unit = self.pending.remove(index).unwrap();
            self.pending_bytes -= unit.size;
            let tile = self.sources.iter().position(|s| *s == unit.ssrc).unwrap();
            self.native.video(unit, tile)?;
        }
        Ok(())
    }
}
pub fn run(
    mut input: mpsc::Receiver<Input>,
    feedback: mpsc::Sender<Feedback>,
    output: Output,
    audio_enabled: Arc<AtomicBool>,
    stats: Arc<Stats>,
    tiles: usize,
    codec: VideoCodec,
) -> Result<()> {
    let queue = Queue::new(stats.clone(), feedback.clone());
    std::thread::scope(|scope| {
        let worker_queue = queue.clone();
        let worker_stats = stats.clone();
        let worker_feedback = feedback.clone();
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
        let worker = scope.spawn(move || -> Result<()> {
            let native = match Native::new(output, audio_enabled, worker_stats.clone()) {
                Ok(native) => {
                    let _ = ready_tx.send(Ok(()));
                    native
                }
                Err(error) => {
                    let _ = ready_tx.send(Err(error.to_string()));
                    return Err(error);
                }
            };
            let mut decoder = Decoder::new(native, worker_stats, worker_feedback);
            worker_queue.run(&mut decoder)
        });
        ready_rx
            .recv()
            .context("Video decoder startup failed")?
            .map_err(anyhow::Error::msg)?;
        if codec == VideoCodec::H264 {
            let result = avc::run(&mut input, queue.clone(), feedback, stats);
            queue.abort();
            let decoded = worker
                .join()
                .map_err(|_| anyhow::anyhow!("Video decoder panicked"))?;
            return result.and(decoded);
        }
        let mut pipeline = Pipeline::new(queue.clone(), feedback, stats, tiles);
        let result = (|| {
            while let Some(input) = input.blocking_recv() {
                pipeline.native.health()?;
                match input {
                    Input::Video(packet) => pipeline.packet(packet)?,
                    Input::Audio(payload) => pipeline.native.audio(payload),
                    Input::Refresh => pipeline.fir(),
                    Input::Tick => {
                        pipeline.select();
                        pipeline.evict(false);
                        pipeline.drain()?;
                    }
                }
            }
            Ok(())
        })();
        // Disconnect does not wait for stale pictures to finish decoding.
        queue.abort();
        let decoded = worker
            .join()
            .map_err(|_| anyhow::anyhow!("Video decoder panicked"))?;
        result.and(decoded)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(all(target_os = "macos", not(feature = "portable-media-validation")))]
    #[test]
    fn native_avc_access_units_produce_full_420_frames() {
        let (events, _events) = mpsc::channel(16);
        let (audio, _audio) = mpsc::channel(16);
        let output = Output {
            events,
            audio,
            video: Arc::default(),
        };
        let stats = Arc::new(Stats::default());
        let native = Native::new(
            output.clone(),
            Arc::new(AtomicBool::new(false)),
            stats.clone(),
        )
        .unwrap();
        let (feedback, _feedback) = mpsc::channel(256);
        let mut decoder = Decoder::new(native, stats.clone(), feedback);
        let mut bytes = &include_bytes!("../../../../../tests/media-codec/h264.fixture")[..];
        fn take(bytes: &mut &[u8]) -> Vec<u8> {
            let n = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
            let out = bytes[4..4 + n].to_vec();
            *bytes = &bytes[4 + n..];
            out
        }
        let config = take(&mut bytes);
        let mut config = config.as_slice();
        let mut params = BTreeMap::new();
        while !config.is_empty() {
            let nal = take(&mut config);
            params.insert((nal[0] & 31, 0), nal);
        }
        decoder.configure(&params).unwrap();
        let mut tag = 0;
        while !bytes.is_empty() {
            let frame = take(&mut bytes);
            let mut frame = frame.as_slice();
            let mut nals = Vec::new();
            while !frame.is_empty() {
                nals.push(take(&mut frame));
            }
            decoder
                .video(
                    Unit {
                        codec: VideoCodec::H264,
                        ssrc: 1,
                        donl: tag,
                        size: nals.iter().map(Vec::len).sum(),
                        nals,
                    },
                    0,
                )
                .unwrap();
            tag += 1;
        }
        assert_eq!(stats.frames.load(Ordering::Relaxed), 30);
        assert_eq!(stats.errors.load(Ordering::Relaxed), 0);
        let frames = output.video.lock().unwrap();
        let frame = frames.get(&0).unwrap();
        let header = &frame.header;
        let pixels = &frame.payload;
        assert_eq!(header["width"], 96);
        assert_eq!(header["chromaWidth"], 48);
        assert_eq!(header["chromaHeight"], 32);
        assert_eq!(
            header["yLength"].as_u64().unwrap() + header["uLength"].as_u64().unwrap(),
            pixels.len() as u64
        );
    }

    #[cfg(feature = "portable-media-validation")]
    #[test]
    #[ignore = "Requires termpilot-media beside the test executable"]
    fn known_loss_recovers_before_corrupting_reference_buffer() {
        let (events, _) = mpsc::channel(16);
        let (audio, _) = mpsc::channel(16);
        let output = Output {
            events,
            audio,
            video: Arc::default(),
        };
        let stats = Arc::new(Stats::default());
        let native = Native::new(output, Arc::new(AtomicBool::new(false)), stats.clone()).unwrap();
        let (feedback, _) = mpsc::channel(256);
        let mut decoder = Decoder::new(native, stats.clone(), feedback);
        let mut params = BTreeMap::new();
        let mut frames = Vec::new();
        let mut bytes =
            &include_bytes!("../../../../../tests/media-codec/hevc-recovery.fixture")[..];
        while !bytes.is_empty() {
            let size = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
            let nal = bytes[4..size + 4].to_vec();
            bytes = &bytes[size + 4..];
            let kind = nal[0] >> 1 & 63;
            if kind < 32 {
                frames.push(nal);
            } else if (32..=34).contains(&kind) {
                params.insert(
                    (kind, if kind == 34 { pps_id(&nal).unwrap() } else { 0 }),
                    nal,
                );
            }
        }
        decoder.configure(&params).unwrap();
        for (i, nal) in frames.into_iter().enumerate() {
            if i == 8 || i == 98 {
                decoder.recover();
                continue;
            }
            decoder
                .video(
                    Unit {
                        codec: VideoCodec::H265,
                        ssrc: 100 + (i % 4) as u32,
                        donl: i as u16,
                        size: nal.len(),
                        nals: vec![nal],
                    },
                    i % 4,
                )
                .unwrap();
        }
        assert_eq!(stats.frames.load(Ordering::Relaxed), 36);
        assert_eq!(stats.errors.load(Ordering::Relaxed), 0);
        assert_eq!(stats.decoder_resets.load(Ordering::Relaxed), 2);
        assert_eq!(stats.recovery_skips.load(Ordering::Relaxed), 162);
    }
    #[cfg(feature = "portable-media-validation")]
    #[test]
    #[ignore = "Requires termpilot-media beside the test executable"]
    fn reordered_tiles_decode_without_reference_damage() {
        use std::sync::Mutex;
        let (events, _events_rx) = mpsc::channel(16);
        let (audio, _audio_rx) = mpsc::channel(16);
        let output = Output {
            events,
            audio,
            video: Arc::new(Mutex::new(BTreeMap::new())),
        };
        let stats = Arc::new(Stats::default());
        let native = Native::new(output, Arc::new(AtomicBool::new(false)), stats.clone()).unwrap();
        let (feedback, _feedback_rx) = mpsc::channel(256);
        let native = Decoder::new(native, stats.clone(), feedback.clone());
        let mut pipeline = Pipeline::new(native, feedback, stats.clone(), 4);
        pipeline.sources = vec![100, 101, 102, 103];
        pipeline.started -= Duration::from_secs(1);
        let mut data =
            &include_bytes!("../../../../../tests/media-codec/hevc-recovery.fixture")[..];
        let mut params = Vec::new();
        let mut frames = Vec::new();
        while !data.is_empty() {
            let n = u32::from_be_bytes(data[..4].try_into().unwrap()) as usize;
            let nal = data[4..4 + n].to_vec();
            data = &data[4 + n..];
            if nal[0] >> 1 & 63 < 32 {
                frames.push(nal);
            } else if frames.is_empty() {
                params.push(nal);
            }
        }
        let mut arrival = (0..8).collect::<Vec<_>>();
        for base in (8..frames.len()).step_by(4) {
            arrival.extend([base, base + 2, base + 3, base + 1]);
        }
        for i in arrival {
            let mut nals = if i == 0 { params.clone() } else { Vec::new() };
            nals.push(frames[i].clone());
            pipeline
                .queue(Unit {
                    codec: VideoCodec::H265,
                    ssrc: 100 + (i % 4) as u32,
                    donl: i as u16,
                    size: nals.iter().map(Vec::len).sum(),
                    nals,
                })
                .unwrap();
            pipeline.drain().unwrap();
        }
        assert_eq!(stats.frames.load(Ordering::Relaxed), 200);
        assert_eq!(stats.errors.load(Ordering::Relaxed), 0);
        assert_eq!(stats.missing_units.load(Ordering::Relaxed), 0);
        assert!(pipeline.pending.is_empty());
    }
    #[test]
    fn slow_decoder_does_not_block_fragment_assembly() {
        // Block decoding until the producer finishes: the old combined worker
        // cannot assemble any packet here. Complete-unit overload remains bounded.
        struct Blocked {
            started: std::sync::mpsc::Sender<()>,
            release: std::sync::mpsc::Receiver<()>,
        }
        impl Sink for Blocked {
            fn configure(&mut self, _: &BTreeMap<(u8, u32), Vec<u8>>) -> Result<()> {
                Ok(())
            }
            fn video(&mut self, _: Unit, _: usize) -> Result<()> {
                let _ = self.started.send(());
                let _ = self.release.recv();
                Ok(())
            }
            fn audio(&mut self, _: Vec<u8>) {}
            fn recover(&mut self) {}
        }
        let stats = Arc::new(Stats::default());
        let (feedback, _) = mpsc::channel(256);
        let queue = Queue::new(stats.clone(), feedback.clone());
        let mut pipeline = Pipeline::new(queue.clone(), feedback, stats.clone(), 4);
        pipeline.sources = vec![100, 101, 102, 103];
        pipeline.configured = true;
        let (started, started_rx) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let q = queue.clone();
            let worker = scope.spawn(move || {
                q.run(&mut Blocked {
                    started,
                    release: release_rx,
                })
            });
            for tag in 0..200u16 {
                // Every picture is ten RTP fragments. Decode stalls on the first
                // one; all 2,000 packets still assemble with no expired groups.
                for fragment in 0..10u16 {
                    let flag = if fragment == 0 {
                        128
                    } else if fragment == 9 {
                        64
                    } else {
                        0
                    };
                    pipeline
                        .packet(Packet {
                            ssrc: 100 + (tag % 4) as u32,
                            sequence: (tag / 4) * 10 + fragment,
                            timestamp: tag as u32,
                            marker: fragment == 9,
                            payload: vec![
                                98,
                                1,
                                flag | if tag == 0 { 19 } else { 1 },
                                (tag >> 8) as u8,
                                tag as u8,
                                42,
                            ],
                        })
                        .unwrap();
                }
                if tag == 0 {
                    started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
                }
            }
            assert_eq!(stats.units.load(Ordering::Relaxed), 200);
            assert_eq!(stats.assembly_drops.load(Ordering::Relaxed), 0);
            assert!(stats.codec_queue_drops.load(Ordering::Relaxed) > 0);
            assert!(stats.max_codec_queue_bytes.load(Ordering::Relaxed) <= 16 * 1024 * 1024);
            assert!(pipeline.groups.is_empty());
            queue.abort();
            release.send(()).unwrap();
            worker.join().unwrap().unwrap();
        });
    }
    #[test]
    fn hevc_fragment_requires_both_ends() {
        let first = [98, 1, 0x81, 0, 7, 10, 11];
        let last = [98, 1, 0x41, 0, 7, 12, 13];
        assert_eq!(
            reassemble(&[&first, &last]).unwrap(),
            vec![vec![2, 1, 10, 11, 12, 13]]
        );
        assert!(reassemble(&[&first]).is_err());
        assert!(reassemble(&[&last]).is_err());
    }
    #[test]
    fn hevc_single_and_aggregation() {
        assert_eq!(
            reassemble(&[&[2, 1, 0, 5, 9]]).unwrap(),
            vec![vec![2, 1, 9]]
        );
        assert_eq!(
            reassemble(&[&[96, 1, 0, 5, 0, 3, 64, 1, 9]]).unwrap(),
            vec![vec![64, 1, 9]]
        );
    }
}
