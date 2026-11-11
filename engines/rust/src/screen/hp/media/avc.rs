//! Bounded RFC 6184 AVC assembly. Apple bank 123 uses avcC and a single picture,
//! without HEVC DONL or LTR feedback. Decode only complete ordered access units.
use super::*;
const WINDOW: Duration = Duration::from_millis(25);
type Parameters = BTreeMap<(u8, u32), Vec<u8>>;
fn parameters(p: &[u8]) -> Result<Parameters> {
    ensure!(
        p.len() <= 65536 && p.first() == Some(&0x92),
        "Invalid AVC configuration"
    );
    let avc = p
        .windows(4)
        .position(|b| b == b"avc1")
        .context("Missing avc1")?;
    let at = p[avc..]
        .windows(4)
        .position(|b| b == b"avcC")
        .context("Missing avcC")?
        + avc
        + 4;
    ensure!(at + 6 <= p.len() && p[at] == 1, "Truncated avcC");
    let mut n = (p[at + 5] & 31) as usize;
    let mut at = at + 6;
    let mut params = BTreeMap::new();
    for kind in [7, 8] {
        ensure!(n > 0 && n <= 32, "AVC parameter count");
        for index in 0..n {
            ensure!(at + 2 <= p.len(), "Truncated AVC parameter");
            let size = u16::from_be_bytes(p[at..at + 2].try_into()?) as usize;
            at += 2;
            ensure!(
                size >= 2 && at + size <= p.len() && p[at] & 31 == kind,
                "Invalid AVC parameter"
            );
            params.insert((kind, index as u32), p[at..at + size].to_vec());
            at += size;
        }
        if kind == 7 {
            n = *p.get(at).context("Missing AVC PPS")? as usize;
            at += 1;
        }
    }
    Ok(params)
}
fn assemble(packets: &[&Packet]) -> Result<Vec<Vec<u8>>> {
    ensure!(!packets.is_empty(), "Empty AVC unit");
    for pair in packets.windows(2) {
        ensure!(
            pair[0].sequence.wrapping_add(1) == pair[1].sequence,
            "Missing AVC fragment"
        );
    }
    let mut result = Vec::new();
    let mut fragment = Vec::new();
    let mut header = None;
    for packet in packets {
        let p = &packet.payload;
        ensure!(!p.is_empty() && p[0] & 128 == 0, "Invalid AVC NAL");
        match p[0] & 31 {
            28 | 29 => {
                let offset = if p[0] & 31 == 28 { 2 } else { 4 };
                ensure!(p.len() > offset && p[1] & 32 == 0, "Truncated AVC FU");
                let nal = (p[0] & 0xe0) | (p[1] & 31);
                ensure!(
                    (1..=23).contains(&(nal & 31)) && p[1] & 0xc0 != 0xc0,
                    "Invalid AVC FU header"
                );
                if p[1] & 128 != 0 {
                    ensure!(fragment.is_empty(), "Interrupted AVC FU");
                    fragment.push(nal);
                    header = Some(nal);
                }
                ensure!(
                    !fragment.is_empty() && header == Some(nal),
                    "Missing AVC FU start"
                );
                fragment.extend(&p[offset..]);
                ensure!(fragment.len() <= 16 * 1024 * 1024, "AVC unit limit");
                if p[1] & 64 != 0 {
                    result.push(std::mem::take(&mut fragment));
                    header = None;
                }
            }
            24 | 25 => {
                ensure!(fragment.is_empty(), "Interrupted AVC FU");
                let mut at = if p[0] & 31 == 24 { 1 } else { 3 };
                ensure!(at < p.len(), "Empty AVC STAP");
                while at < p.len() {
                    ensure!(at + 2 <= p.len(), "Truncated AVC STAP");
                    let n = u16::from_be_bytes(p[at..at + 2].try_into()?) as usize;
                    at += 2;
                    ensure!(
                        n > 0 && at + n <= p.len() && (1..=23).contains(&(p[at] & 31)),
                        "Invalid AVC STAP"
                    );
                    result.push(p[at..at + n].to_vec());
                    at += n;
                    ensure!(result.len() <= 256, "AVC NAL count limit");
                }
            }
            1..=23 => {
                ensure!(fragment.is_empty(), "Interrupted AVC FU");
                result.push(p.to_vec());
            }
            _ => anyhow::bail!("Unsupported AVC packet"),
        }
        ensure!(result.len() <= 256, "AVC NAL count limit");
    }
    ensure!(fragment.is_empty(), "Missing AVC FU end");
    Ok(result)
}
struct Pipeline<D: Sink> {
    sink: D,
    feedback: mpsc::Sender<Feedback>,
    stats: Arc<Stats>,
    source: Option<u32>,
    params: Parameters,
    groups: HashMap<u32, Group>,
    bytes: usize,
    last_timestamp: Option<u32>,
    next_sequence: Option<u16>,
    config_sequences: VecDeque<u16>,
    tag: u16,
    last_fir: Instant,
}
impl<D: Sink> Pipeline<D> {
    fn new(sink: D, feedback: mpsc::Sender<Feedback>, stats: Arc<Stats>) -> Self {
        Self {
            sink,
            feedback,
            stats,
            source: None,
            params: BTreeMap::new(),
            groups: HashMap::new(),
            bytes: 0,
            last_timestamp: None,
            next_sequence: None,
            config_sequences: VecDeque::new(),
            tag: 0,
            last_fir: Instant::now() - Duration::from_secs(1),
        }
    }
    fn recover(&mut self) {
        self.sink.recover();
        if self.last_fir.elapsed() >= Duration::from_millis(500) {
            self.last_fir = Instant::now();
            let _ = self.feedback.try_send(Feedback::Refresh);
        }
    }
    fn packet(&mut self, p: Packet) -> Result<()> {
        if p.payload.first() == Some(&0x92) {
            let params = parameters(&p.payload)?;
            self.config_sequences.push_back(p.sequence);
            if self.config_sequences.len() > 32 {
                self.config_sequences.pop_front();
            }
            if self.source != Some(p.ssrc) || self.params != params {
                self.source = Some(p.ssrc);
                self.params = params;
                self.groups.clear();
                self.bytes = 0;
                self.last_timestamp = None;
                self.next_sequence = None;
                self.sink.configure(&self.params)?;
                self.stats
                    .parameters
                    .store(self.params.len() as u64, Ordering::Relaxed);
                let _ = self.feedback.try_send(Feedback::Sources(vec![p.ssrc]));
                self.recover();
            }
            return Ok(());
        }
        if self.source != Some(p.ssrc)
            || self
                .last_timestamp
                .is_some_and(|last| p.timestamp.wrapping_sub(last) as i32 <= 0)
        {
            return Ok(());
        }
        if p.payload.is_empty() || p.payload.len() > 65536 {
            return Ok(());
        }
        if self.bytes + p.payload.len() > 32 * 1024 * 1024 || self.groups.len() >= 64 {
            self.groups.clear();
            self.bytes = 0;
            self.next_sequence = None;
            self.recover();
        }
        let group = self.groups.entry(p.timestamp).or_insert_with(|| Group {
            marker_seen: false,
            packets: BTreeMap::new(),
            at: Instant::now(),
            size: 0,
        });
        if group.packets.contains_key(&p.sequence) {
            return Ok(());
        }
        group.marker_seen |= p.marker;
        group.size += p.payload.len();
        self.bytes += p.payload.len();
        group.packets.insert(p.sequence, p);
        self.drain()
    }
    fn drain(&mut self) -> Result<()> {
        loop {
            let Some((&timestamp, group)) = self
                .groups
                .iter()
                .min_by(|(a, _), (b, _)| ((**a).wrapping_sub(**b) as i32).cmp(&0))
            else {
                return Ok(());
            };
            let expired = group.at.elapsed()
                >= if group.marker_seen {
                    WINDOW
                } else {
                    Duration::from_millis(150)
                };
            if !group.marker_seen && !expired {
                return Ok(());
            }
            let ordered = ordered(group);
            let mut expected = self.next_sequence;
            for _ in 0..32 {
                if expected.is_some_and(|seq| self.config_sequences.contains(&seq)) {
                    expected = expected.map(|s| s.wrapping_add(1));
                } else {
                    break;
                }
            }
            let missing =
                expected.is_some_and(|s| ordered.first().is_some_and(|p| p.sequence != s));
            let assembled = if group.marker_seen {
                assemble(&ordered).ok()
            } else {
                None
            };
            if (missing || assembled.is_none()) && !expired {
                return Ok(());
            }
            let next = ordered.last().map(|p| p.sequence.wrapping_add(1));
            let size = group.size;
            self.groups.remove(&timestamp);
            self.bytes -= size;
            self.next_sequence = next;
            self.last_timestamp = Some(timestamp);
            if missing || assembled.is_none() {
                self.stats.assembly_drops.fetch_add(1, Ordering::Relaxed);
                self.recover();
            }
            if let Some(nals) = assembled {
                if nals.iter().any(|n| (1..=5).contains(&(n[0] & 31))) {
                    self.tag = self.tag.wrapping_add(1);
                    self.stats.units.fetch_add(1, Ordering::Relaxed);
                    for n in &nals {
                        self.stats
                            .nal_types
                            .fetch_or(1u64 << (n[0] & 31), Ordering::Relaxed);
                    }
                    self.sink.video(
                        Unit {
                            codec: VideoCodec::H264,
                            ssrc: self.source.unwrap(),
                            donl: self.tag,
                            size,
                            nals,
                        },
                        0,
                    )?;
                }
            }
        }
    }
}
pub(super) fn run(
    input: &mut mpsc::Receiver<Input>,
    sink: Queue,
    feedback: mpsc::Sender<Feedback>,
    stats: Arc<Stats>,
) -> Result<()> {
    let mut p = Pipeline::new(sink.clone(), feedback.clone(), stats.clone());
    while let Some(input) = input.blocking_recv() {
        p.sink.health()?;
        match input {
            Input::Video(packet) => p.packet(packet)?,
            Input::Audio(data) => p.sink.audio(data),
            Input::Refresh => p.recover(),
            Input::Restart(ready) => {
                p.sink.restart();
                p = Pipeline::new(sink.clone(), feedback.clone(), stats.clone());
                sink.barrier(ready);
            }
            Input::Tick => p.drain()?,
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn packet(seq: u16, data: &[u8]) -> Packet {
        Packet {
            sequence: seq,
            timestamp: 90,
            ssrc: 1,
            marker: true,
            payload: data.to_vec(),
        }
    }
    #[test]
    fn fu_a_wrap_and_missing_fragment() {
        let a = packet(65535, &[0x7c, 0x85, 1, 2]);
        let b = packet(0, &[0x7c, 5, 3]);
        let c = packet(1, &[0x7c, 0x45, 4]);
        assert_eq!(
            assemble(&[&a, &b, &c]).unwrap(),
            vec![vec![0x65, 1, 2, 3, 4]]
        );
        assert!(assemble(&[&a, &c]).is_err());
        assert!(assemble(&[&b, &c]).is_err());
        assert!(assemble(&[&a, &b]).is_err());
    }
    #[test]
    fn avcc_bounds_and_parameter_types() {
        let mut p = vec![0x92];
        p.extend(b"avc1avcC");
        p.extend([1, 100, 0, 42, 255, 225, 0, 2, 0x67, 1, 1, 0, 2, 0x68, 2]);
        assert_eq!(parameters(&p).unwrap().len(), 2);
        for n in 0..p.len() {
            assert!(parameters(&p[..n]).is_err());
        }
    }
}
