use crate::wire::Output;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use ironrdp_rdpsnd::{
    client::RdpsndClientHandler,
    pdu::{AudioFormat, AudioFormatFlags, PitchPdu, VolumePdu, WaveFormat},
};
use std::{
    borrow::Cow,
    collections::VecDeque,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

#[derive(Debug, Default)]
pub struct Statistics {
    pub received: AtomicU64,
    pub forwarded: AtomicU64,
    pub muted: AtomicU64,
}

/// Negotiate standard PCM, then convert its rate and samples to the output device's
/// native representation. CoreAudio/WASAPI commonly expose F32, while RDP uses I16.
/// Filtering wire formats by the device's sample *type* would leave Windows with
/// no compatible PCM format, even though the device can play those same samples.
#[derive(Debug)]
pub struct Playback {
    formats: Vec<AudioFormat>,
    enabled: Arc<AtomicBool>,
    volume: Arc<AtomicU32>,
    statistics: Arc<Statistics>,
    output: Output,
    sender: Option<mpsc::SyncSender<Vec<u8>>>,
    worker: Option<thread::JoinHandle<()>>,
    retry_after: Instant,
}
impl Playback {
    pub fn new(enabled: Arc<AtomicBool>, statistics: Arc<Statistics>, output: Output) -> Self {
        let formats = [44100, 48000, 22050]
            .into_iter()
            .flat_map(|rate| {
                [2, 1].map(move |channels| AudioFormat {
                    format: WaveFormat::PCM,
                    n_channels: channels,
                    n_samples_per_sec: rate,
                    n_avg_bytes_per_sec: rate * u32::from(channels) * 2,
                    n_block_align: channels * 2,
                    bits_per_sample: 16,
                    data: None,
                })
            })
            .collect();
        Self {
            formats,
            enabled,
            volume: Arc::new(AtomicU32::new(u32::MAX)),
            statistics,
            output,
            sender: None,
            worker: None,
            retry_after: Instant::now(),
        }
    }
    fn start(&mut self, format: &AudioFormat) {
        self.close();
        self.retry_after = Instant::now() + Duration::from_secs(2);
        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(16);
        let (enabled, volume, output, format) = (
            self.enabled.clone(),
            self.volume.clone(),
            self.output.clone(),
            format.clone(),
        );
        self.sender = Some(tx);
        self.worker = Some(thread::spawn(move || {
            if let Err(error) = play(rx, enabled, volume, format) {
                output.event(serde_json::json!({"kind":"audioError","message":format!("远程音频播放失败：{error}")}));
            }
        }));
    }
}
impl Drop for Playback {
    fn drop(&mut self) {
        self.close();
    }
}
impl RdpsndClientHandler for Playback {
    fn get_flags(&self) -> AudioFormatFlags {
        AudioFormatFlags::VOLUME
    }
    fn get_formats(&self) -> &[AudioFormat] {
        &self.formats
    }
    fn wave(&mut self, format: &AudioFormat, _ts: u32, data: Cow<'_, [u8]>) {
        self.statistics.received.fetch_add(1, Ordering::Relaxed);
        if !self.enabled.load(Ordering::Acquire) {
            self.statistics.muted.fetch_add(1, Ordering::Relaxed);
            return;
        }
        if self.sender.is_none() || self.worker.as_ref().is_some_and(|w| w.is_finished()) {
            if Instant::now() < self.retry_after {
                return;
            }
            self.start(format);
        }
        // Audio is bounded independently of the video and clipboard queues.
        if data.len() <= 1024 * 1024
            && self
                .sender
                .as_ref()
                .is_some_and(|tx| tx.try_send(data.into_owned()).is_ok())
        {
            self.statistics.forwarded.fetch_add(1, Ordering::Relaxed);
        }
    }
    fn set_volume(&mut self, v: VolumePdu) {
        self.volume.store(
            (u32::from(v.volume_left) << 16) | u32::from(v.volume_right),
            Ordering::Release,
        );
    }
    fn set_pitch(&mut self, _: PitchPdu) {}
    fn close(&mut self) {
        self.sender = None;
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn play(
    rx: mpsc::Receiver<Vec<u8>>,
    enabled: Arc<AtomicBool>,
    volume: Arc<AtomicU32>,
    format: AudioFormat,
) -> anyhow::Result<()> {
    use anyhow::{Context, ensure};
    ensure!(
        format.format == WaveFormat::PCM
            && format.bits_per_sample == 16
            && (1..=2).contains(&format.n_channels),
        "Unsupported PCM format"
    );
    let device = cpal::default_host()
        .default_output_device()
        .context("没有可用的音频输出设备")?;
    let supported = device.default_output_config()?;
    let config = supported.config();
    let queue = Arc::new(Mutex::new(VecDeque::<f32>::new()));
    let alive = Arc::new(AtomicBool::new(true));
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => stream::<f32>(
            &device,
            &config,
            queue.clone(),
            enabled.clone(),
            volume,
            alive.clone(),
        )?,
        cpal::SampleFormat::I16 => stream::<i16>(
            &device,
            &config,
            queue.clone(),
            enabled.clone(),
            volume,
            alive.clone(),
        )?,
        cpal::SampleFormat::U16 => stream::<u16>(
            &device,
            &config,
            queue.clone(),
            enabled.clone(),
            volume,
            alive.clone(),
        )?,
        cpal::SampleFormat::I32 => stream::<i32>(
            &device,
            &config,
            queue.clone(),
            enabled.clone(),
            volume,
            alive.clone(),
        )?,
        cpal::SampleFormat::F64 => stream::<f64>(
            &device,
            &config,
            queue.clone(),
            enabled.clone(),
            volume,
            alive.clone(),
        )?,
        other => anyhow::bail!("不支持的本机音频格式：{other:?}"),
    };
    stream.play()?;
    let capacity = (config.sample_rate as usize / 2) * (config.channels as usize);
    let mut resampler = Resampler::new(format.n_samples_per_sec, config.sample_rate);
    while alive.load(Ordering::Acquire) {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(bytes) => {
                let mut q = queue.lock().unwrap();
                if !enabled.load(Ordering::Acquire) {
                    q.clear();
                    continue;
                }
                for frame in bytes.chunks_exact(usize::from(format.n_channels) * 2) {
                    let left = i16::from_le_bytes([frame[0], frame[1]]) as f32 / 32768.0;
                    let right = if format.n_channels == 1 {
                        left
                    } else {
                        i16::from_le_bytes([frame[2], frame[3]]) as f32 / 32768.0
                    };
                    resampler.push([left, right], |samples| {
                        for channel in 0..usize::from(config.channels) {
                            let sample = if config.channels == 1 {
                                (samples[0] + samples[1]) * 0.5
                            } else {
                                samples.get(channel).copied().unwrap_or(0.0)
                            };
                            if q.len() >= capacity {
                                q.pop_front();
                            }
                            q.push_back(sample);
                        }
                    });
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    if !alive.load(Ordering::Acquire) {
        anyhow::bail!("音频输出设备已断开");
    }
    Ok(())
}
fn stream<T: cpal::SizedSample + cpal::FromSample<f32>>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    queue: Arc<Mutex<VecDeque<f32>>>,
    enabled: Arc<AtomicBool>,
    volume: Arc<AtomicU32>,
    alive: Arc<AtomicBool>,
) -> Result<cpal::Stream, cpal::BuildStreamError> {
    let channels = usize::from(config.channels);
    device.build_output_stream(
        config,
        move |data: &mut [T], _: &cpal::OutputCallbackInfo| {
            let mut q = queue.try_lock().ok();
            let active = enabled.load(Ordering::Acquire);
            let level = volume.load(Ordering::Acquire);
            if !active {
                if let Some(q) = q.as_mut() {
                    q.clear();
                }
            }
            for (i, value) in data.iter_mut().enumerate() {
                let gain = if i % channels == 1 {
                    level & 0xffff
                } else {
                    level >> 16
                };
                let sample = if active {
                    q.as_mut().and_then(|q| q.pop_front()).unwrap_or(0.0) * (gain as f32 / 65535.0)
                } else {
                    0.0
                };
                *value = T::from_sample(sample);
            }
        },
        move |_| {
            alive.store(false, Ordering::Release);
        },
        None,
    )
}

/// Streaming linear rate conversion retains its phase across RDP packet boundaries.
struct Resampler {
    previous: Option<[f32; 2]>,
    phase: f64,
    step: f64,
}
impl Resampler {
    fn new(source: u32, target: u32) -> Self {
        Self {
            previous: None,
            phase: 0.0,
            step: f64::from(source) / f64::from(target),
        }
    }
    fn push(&mut self, current: [f32; 2], mut output: impl FnMut([f32; 2])) {
        if let Some(previous) = self.previous {
            while self.phase < 1.0 {
                let t = self.phase as f32;
                output([
                    previous[0] + (current[0] - previous[0]) * t,
                    previous[1] + (current[1] - previous[1]) * t,
                ]);
                self.phase += self.step;
            }
            self.phase -= 1.0;
        }
        self.previous = Some(current);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rate_conversion_preserves_duration_and_stereo_levels() {
        for (source, target) in [(44100, 48000), (48000, 44100), (44100, 44100)] {
            let mut r = Resampler::new(source, target);
            let mut count = 0;
            for _ in 0..source {
                r.push([0.25, -0.5], |sample| {
                    assert_eq!(sample, [0.25, -0.5]);
                    count += 1;
                });
            }
            assert!((count - target as i32).abs() <= 2);
        }
    }
}
