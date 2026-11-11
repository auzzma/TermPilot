import AVFAudio
import Foundation

/// At most 160 ms of decoded audio. Old samples never queue across a reconnect.
final class RemoteAudio {
  private let queue = DispatchQueue(label: "TermPilot.audio")
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
  private var queued = 0
  private var stopped = false
  init() {
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
  }
  func append(_ bytes: Data) {
    guard !bytes.isEmpty, bytes.count <= 32768, bytes.count % 8 == 0 else { return }
    queue.async { [self] in
      let frames = bytes.count / 8
      guard !stopped, queued + frames <= 7680,
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
        let channels = buffer.floatChannelData
      else { return }
      do {
        if !engine.isRunning {
          try AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: [.mixWithOthers])
          try AVAudioSession.sharedInstance().setActive(true)
          try engine.start()
          player.play()
        }
        bytes.withUnsafeBytes { raw in
          for i in 0..<frames {
            channels[0][i] = Float(
              bitPattern: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self).littleEndian)
            channels[1][i] = Float(
              bitPattern: raw.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self).littleEndian
            )
          }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        queued += frames
        player.scheduleBuffer(buffer) { [weak self] in
          guard let self else { return }
          self.queue.async { self.queued = max(0, self.queued - frames) }
        }
      } catch { engine.stop() }
    }
  }
  func stop() {
    queue.async { [self] in
      stopped = true
      player.stop()
      engine.stop()
      queued = 0
    }
  }
}
