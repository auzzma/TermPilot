//! Keep packet assembly responsive while the software decoder is busy.
//! Overload discards complete access units and resumes at an IRAP, never random
//! fragments or an arbitrary predicted picture with missing references.
use super::{Feedback, Native, Stats, Unit, VideoCodec};
use anyhow::{ensure, Result};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{atomic::Ordering, Arc, Condvar, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::mpsc;

type Parameters = BTreeMap<(u8, u32), Vec<u8>>;
// Allow the initial 300ms assembly burst when decoding can catch up quickly.
// The age and byte limits, rather than a tiny sample count, bound real latency.
const MAX_UNITS: usize = 128;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_AGE: Duration = Duration::from_millis(120);

pub(super) trait Sink {
    fn configure(&mut self, params: &Parameters) -> Result<()>;
    fn video(&mut self, unit: Unit, tile: usize) -> Result<()>;
    fn audio(&mut self, bytes: Vec<u8>);
    fn recover(&mut self);
    fn poll(&mut self) -> Result<()> {
        Ok(())
    }
    fn health(&mut self) -> Result<()> {
        Ok(())
    }
}
fn is_keyframe(unit: &Unit) -> bool {
    unit.nals.iter().any(|nal| {
        nal.len() >= 2
            && if unit.codec == VideoCodec::H264 {
                nal[0] & 31 == 5
            } else {
                (16..=23).contains(&(nal[0] >> 1 & 63))
            }
    })
}

pub(super) struct Decoder {
    native: Native,
    stats: Arc<Stats>,
    feedback: mpsc::Sender<Feedback>,
    params: Parameters,
    waiting: bool,
    reset: bool,
}
impl Decoder {
    pub fn new(native: Native, stats: Arc<Stats>, feedback: mpsc::Sender<Feedback>) -> Self {
        Self {
            native,
            stats,
            feedback,
            params: BTreeMap::new(),
            waiting: false,
            reset: false,
        }
    }
}
impl Sink for Decoder {
    fn poll(&mut self) -> Result<()> {
        #[cfg(all(target_os = "android", not(feature = "portable-media-validation")))]
        if !self.waiting {
            let status = self.native.poll();
            if status < 0 {
                self.stats.errors.fetch_add(1, Ordering::Relaxed);
                self.stats.last_video_error.store(status, Ordering::Relaxed);
                self.recover();
                let _ = self.feedback.try_send(Feedback::Refresh);
            }
        }
        Ok(())
    }
    fn configure(&mut self, params: &Parameters) -> Result<()> {
        self.params = params.clone();
        self.native.configure(params)?;
        self.waiting = false;
        self.reset = false;
        Ok(())
    }
    fn recover(&mut self) {
        self.waiting = true;
        self.reset = true;
    }
    fn video(&mut self, unit: Unit, tile: usize) -> Result<()> {
        if self.waiting {
            if !is_keyframe(&unit) {
                self.stats.recovery_skips.fetch_add(1, Ordering::Relaxed);
                return Ok(());
            }
            if self.reset {
                self.native.configure(&self.params)?;
                self.stats.decoder_resets.fetch_add(1, Ordering::Relaxed);
            }
            self.waiting = false;
            self.reset = false;
        }
        let start = Instant::now();
        let mut good = false;
        let mut failed = false;
        let samples = if unit.codec == VideoCodec::H264 {
            // One access unit, including all slices, in AVCC length-prefixed format.
            vec![unit
                .nals
                .iter()
                .filter(|n| !n.is_empty() && (1..=5).contains(&(n[0] & 31)))
                .flat_map(|n| {
                    (n.len() as u32)
                        .to_be_bytes()
                        .into_iter()
                        .chain(n.iter().copied())
                })
                .collect::<Vec<_>>()]
        } else {
            unit.nals.clone()
        };
        for nal in &samples {
            if nal.len() < 2 || (unit.codec == VideoCodec::H265 && nal[0] >> 1 & 63 >= 32) {
                continue;
            }
            let status = self.native.decode(nal, tile, unit.donl);
            good |= status > 0;
            failed |= status < 0;
            if status < 0 {
                self.stats.last_video_error.store(status, Ordering::Relaxed);
            }
        }
        let micros = start.elapsed().as_micros() as u64;
        self.stats
            .decode_micros
            .fetch_add(micros, Ordering::Relaxed);
        self.stats.decode_calls.fetch_add(1, Ordering::Relaxed);
        self.stats
            .max_decode_micros
            .fetch_max(micros, Ordering::Relaxed);
        if failed {
            self.stats.errors.fetch_add(1, Ordering::Relaxed);
            self.recover();
            let _ = self.feedback.try_send(Feedback::Refresh);
        } else if good && tile == 0 && unit.codec == VideoCodec::H265 {
            let _ = self.feedback.try_send(Feedback::Ack(unit.donl));
        }
        Ok(())
    }
    fn audio(&mut self, bytes: Vec<u8>) {
        self.native.audio(&bytes);
    }
    fn health(&mut self) -> Result<()> {
        #[cfg(any(windows, feature = "portable-media-validation"))]
        self.native.health()?;
        Ok(())
    }
}

enum Job {
    Configure(Parameters),
    Video(Unit, usize, Instant),
    Audio(Vec<u8>),
    Recover,
    #[cfg(any(target_os = "android", test))]
    Poll,
}
#[derive(Default)]
struct State {
    jobs: VecDeque<Job>,
    video_bytes: usize,
    videos: usize,
    audio: usize,
    waiting: bool,
    closed: bool,
    failure: Option<String>,
    last_fir: Option<Instant>,
    #[cfg(any(target_os = "android", test))]
    poll_output: bool,
}
struct Shared {
    state: Mutex<State>,
    ready: Condvar,
    stats: Arc<Stats>,
    feedback: mpsc::Sender<Feedback>,
}
#[derive(Clone)]
pub(super) struct Queue(Arc<Shared>);
impl Queue {
    pub fn new(stats: Arc<Stats>, feedback: mpsc::Sender<Feedback>) -> Self {
        Self(Arc::new(Shared {
            state: Mutex::new(State::default()),
            ready: Condvar::new(),
            stats,
            feedback,
        }))
    }
    fn clear_video(&self, s: &mut State) {
        self.0
            .stats
            .codec_queue_drops
            .fetch_add(s.videos as u64, Ordering::Relaxed);
        s.jobs
            .retain(|job| !matches!(job, Job::Video(..) | Job::Recover));
        s.videos = 0;
        s.video_bytes = 0;
    }
    fn recover_locked(&self, s: &mut State) {
        self.clear_video(s);
        s.waiting = true;
        s.jobs.push_back(Job::Recover);
        let now = Instant::now();
        if s.last_fir
            .is_none_or(|at| now.duration_since(at) >= Duration::from_millis(500))
        {
            s.last_fir = Some(now);
            let _ = self.0.feedback.try_send(Feedback::Refresh);
        }
    }
    fn stale(s: &State, now: Instant) -> bool {
        s.jobs
            .iter()
            .find_map(|job| match job {
                Job::Video(_, _, at) => Some(now.duration_since(*at) >= MAX_AGE),
                _ => None,
            })
            .unwrap_or(false)
    }
    #[cfg(test)]
    pub fn close(&self) {
        let mut s = self.0.state.lock().unwrap();
        s.closed = true;
        self.0.ready.notify_all();
    }
    pub fn abort(&self) {
        let mut s = self.0.state.lock().unwrap();
        s.closed = true;
        s.jobs.clear();
        s.videos = 0;
        s.video_bytes = 0;
        s.audio = 0;
        self.0.ready.notify_all();
    }
    fn next(&self) -> Option<Job> {
        let mut s = self.0.state.lock().unwrap();
        loop {
            if Self::stale(&s, Instant::now()) {
                self.0
                    .stats
                    .overload_recoveries
                    .fetch_add(1, Ordering::Relaxed);
                self.recover_locked(&mut s);
            }
            if let Some(job) = s.jobs.pop_front() {
                match &job {
                    Job::Video(unit, _, at) => {
                        s.videos -= 1;
                        s.video_bytes -= unit.size;
                        self.0
                            .stats
                            .max_queue_micros
                            .fetch_max(at.elapsed().as_micros() as u64, Ordering::Relaxed);
                    }
                    Job::Audio(_) => s.audio -= 1,
                    _ => {}
                }
                return Some(job);
            }
            if s.closed {
                return None;
            }
            #[cfg(any(target_os = "android", test))]
            {
                if s.poll_output {
                    let (next, timeout) = self
                        .0
                        .ready
                        .wait_timeout(s, Duration::from_millis(4))
                        .unwrap();
                    s = next;
                    if timeout.timed_out() && !s.closed && s.jobs.is_empty() {
                        return Some(Job::Poll);
                    }
                } else {
                    s = self.0.ready.wait(s).unwrap();
                }
            }
            #[cfg(not(any(target_os = "android", test)))]
            {
                s = self.0.ready.wait(s).unwrap();
            }
        }
    }
    pub fn run(&self, decoder: &mut impl Sink) -> Result<()> {
        let result = (|| {
            while let Some(job) = self.next() {
                decoder.health()?;
                decoder.poll()?;
                match job {
                    Job::Configure(params) => decoder.configure(&params)?,
                    Job::Video(unit, tile, _) => decoder.video(unit, tile)?,
                    Job::Audio(bytes) => decoder.audio(bytes),
                    Job::Recover => decoder.recover(),
                    #[cfg(any(target_os = "android", test))]
                    Job::Poll => {}
                }
            }
            Ok(())
        })();
        if let Err(error) = &result {
            let mut s = self.0.state.lock().unwrap();
            s.failure = Some(format!("{error}"));
            s.closed = true;
        }
        result
    }
}
impl Sink for Queue {
    fn health(&mut self) -> Result<()> {
        let s = self.0.state.lock().unwrap();
        ensure!(
            !s.closed,
            "{}",
            s.failure.as_deref().unwrap_or("Video decoder closed")
        );
        Ok(())
    }
    fn configure(&mut self, params: &Parameters) -> Result<()> {
        self.health()?;
        let mut s = self.0.state.lock().unwrap();
        self.clear_video(&mut s);
        s.jobs.retain(|job| !matches!(job, Job::Configure(_)));
        s.jobs.push_back(Job::Configure(params.clone()));
        // Only AVC MediaCodec has asynchronous output to drain. Keep the
        // synchronous HEVC decoder's existing idle/sleep behavior unchanged.
        #[cfg(any(target_os = "android", test))]
        {
            s.poll_output = params.keys().any(|(kind, _)| *kind == 7);
        }
        s.waiting = false;
        self.0.ready.notify_one();
        Ok(())
    }
    fn video(&mut self, unit: Unit, tile: usize) -> Result<()> {
        self.health()?;
        let mut s = self.0.state.lock().unwrap();
        if s.videos >= MAX_UNITS
            || s.video_bytes + unit.size > MAX_BYTES
            || Self::stale(&s, Instant::now())
        {
            self.0
                .stats
                .overload_recoveries
                .fetch_add(1, Ordering::Relaxed);
            self.recover_locked(&mut s);
        }
        if unit.size > MAX_BYTES {
            self.0
                .stats
                .codec_queue_drops
                .fetch_add(1, Ordering::Relaxed);
            return Ok(());
        }
        if s.waiting {
            if !is_keyframe(&unit) {
                self.0.stats.recovery_skips.fetch_add(1, Ordering::Relaxed);
                return Ok(());
            }
            s.waiting = false;
        }
        s.video_bytes += unit.size;
        s.videos += 1;
        self.0
            .stats
            .max_codec_queue_bytes
            .fetch_max(s.video_bytes as u64, Ordering::Relaxed);
        s.jobs.push_back(Job::Video(unit, tile, Instant::now()));
        self.0.ready.notify_one();
        Ok(())
    }
    fn audio(&mut self, bytes: Vec<u8>) {
        let mut s = self.0.state.lock().unwrap();
        if s.closed || s.audio >= 32 || bytes.len() > 65536 {
            return;
        }
        s.audio += 1;
        s.jobs.push_back(Job::Audio(bytes));
        self.0.ready.notify_one();
    }
    fn recover(&mut self) {
        let mut s = self.0.state.lock().unwrap();
        self.recover_locked(&mut s);
        self.0.ready.notify_one();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn unit(tag: u16, key: bool) -> Unit {
        Unit {
            codec: VideoCodec::H265,
            ssrc: 100,
            donl: tag,
            size: 4,
            nals: vec![vec![if key { 38 } else { 2 }, 1, 0, 0]],
        }
    }
    fn queue() -> (Queue, Arc<Stats>) {
        let stats = Arc::new(Stats::default());
        let (tx, _) = mpsc::channel(256);
        (Queue::new(stats.clone(), tx), stats)
    }
    #[test]
    fn overload_discards_complete_units_then_resumes_at_keyframe() {
        let (mut q, stats) = queue();
        q.configure(&Parameters::new()).unwrap();
        for tag in 0..(MAX_UNITS as u16 + 32) {
            q.video(unit(tag, tag == 0), 0).unwrap();
        }
        assert_eq!(
            stats.codec_queue_drops.load(Ordering::Relaxed),
            MAX_UNITS as u64
        );
        assert_eq!(stats.overload_recoveries.load(Ordering::Relaxed), 1);
        assert_eq!(stats.recovery_skips.load(Ordering::Relaxed), 32);
        q.video(unit(200, true), 0).unwrap();
        q.video(unit(201, false), 0).unwrap();
        q.close();
        assert!(matches!(q.next(), Some(Job::Configure(_))));
        assert!(matches!(q.next(), Some(Job::Recover)));
        assert!(matches!(
            q.next(),
            Some(Job::Video(Unit { donl: 200, .. }, _, _))
        ));
        assert!(matches!(
            q.next(),
            Some(Job::Video(Unit { donl: 201, .. }, _, _))
        ));
        assert!(q.next().is_none());
    }
    #[test]
    fn expiry_keeps_audio_and_requests_reference_reset() {
        let (mut q, stats) = queue();
        q.video(unit(0, true), 0).unwrap();
        q.audio(vec![1, 2, 3]);
        if let Some(Job::Video(_, _, at)) = q.0.state.lock().unwrap().jobs.front_mut() {
            *at -= MAX_AGE;
        }
        q.close();
        assert!(matches!(q.next(), Some(Job::Audio(_))));
        assert!(matches!(q.next(), Some(Job::Recover)));
        assert!(q.next().is_none());
        assert_eq!(stats.overload_recoveries.load(Ordering::Relaxed), 1);
    }
    #[test]
    fn byte_bound_and_abort_do_not_leave_queued_work() {
        let (mut q, stats) = queue();
        let mut huge = unit(0, true);
        huge.size = MAX_BYTES + 1;
        q.video(huge, 0).unwrap();
        assert!(q.0.state.lock().unwrap().waiting);
        q.video(unit(1, false), 0).unwrap();
        assert_eq!(stats.recovery_skips.load(Ordering::Relaxed), 1);
        q.video(unit(2, true), 0).unwrap();
        q.abort();
        assert!(q.next().is_none());
        assert!(q.health().is_err());
        assert!(q.video(unit(3, true), 0).is_err());
    }

    #[test]
    fn idle_worker_drains_delayed_output_without_another_video_packet() {
        struct DelayedSink {
            output: std::sync::mpsc::Sender<()>,
            pending: bool,
        }
        impl Sink for DelayedSink {
            fn configure(&mut self, _: &Parameters) -> Result<()> {
                Ok(())
            }
            fn video(&mut self, _: Unit, _: usize) -> Result<()> {
                self.pending = true;
                Ok(())
            }
            fn audio(&mut self, _: Vec<u8>) {}
            fn recover(&mut self) {}
            fn poll(&mut self) -> Result<()> {
                if self.pending {
                    self.pending = false;
                    self.output.send(()).unwrap();
                }
                Ok(())
            }
        }
        let (mut q, _) = queue();
        q.configure(&Parameters::from([((7, 0), vec![0x67])]))
            .unwrap();
        let worker_queue = q.clone();
        let (output, received) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            worker_queue.run(&mut DelayedSink {
                output,
                pending: false,
            })
        });
        q.video(unit(0, true), 0).unwrap();
        let drained = received.recv_timeout(Duration::from_secs(2));
        q.abort();
        worker.join().unwrap().unwrap();
        assert!(
            drained.is_ok(),
            "The final decoded frame must arrive while input is idle"
        );
    }
}
