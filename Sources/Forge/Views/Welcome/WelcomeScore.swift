import AVFoundation

/// What the welcome sounds like: short and soft, one for every thing that
/// happens. Each is worked out here; nothing recorded is in the app.
@MainActor
final class WelcomeScore {
  enum Sound: CaseIterable { case hello, pop, latch, shimmer, thud }

  nonisolated static let rate = 44_100.0
  private let engine = AVAudioEngine()
  private let effects = [AVAudioPlayerNode(), AVAudioPlayerNode(), AVAudioPlayerNode()]
  private let sample = AVAudioPlayerNode()
  private let room = AVAudioUnitReverb()
  private var sounds: [Sound: AVAudioPCMBuffer] = [:]
  private var turn = 0
  private var isRunning = false

  var isOn = true { didSet { engine.mainMixerNode.outputVolume = isOn ? 1 : 0 } }

  /// A Mac with nothing to play on has a quiet welcome.
  func begin() async {
    guard !isRunning else { return }
    let made = await Task.detached(priority: .userInitiated) { Made(Sound.allCases.map { ($0, Self.make($0)) }) }.value
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2), !isRunning else { return }
    for (sound, buffer) in made.sounds { sounds[sound] = buffer }
    for node in effects + [sample] { engine.attach(node) }
    engine.attach(room)
    room.loadFactoryPreset(.mediumHall)
    room.wetDryMix = 26
    let mix = AVAudioMixerNode()
    engine.attach(mix)
    for node in effects { engine.connect(node, to: mix, format: format) }
    engine.connect(mix, to: room, format: format)
    engine.connect(room, to: engine.mainMixerNode, format: format)
    engine.connect(sample, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = isOn ? 1 : 0
    do { try engine.start() } catch { return }
    isRunning = true
    for node in effects + [sample] { node.play() }
  }

  func play(_ sound: Sound) {
    guard isRunning, let buffer = sounds[sound] else { return }
    effects[turn % effects.count].scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    turn += 1
  }

  func play(_ url: URL) {
    guard isRunning, let buffer = Self.read(url, as: sample.outputFormat(forBus: 0)) else { return }
    sample.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
  }

  func hush() {
    guard isRunning else { return }
    sample.stop()
    sample.play()
  }

  func end() {
    guard isRunning else { return }
    engine.stop()
    isRunning = false
  }

  // MARK: - Making them

  private struct Made: @unchecked Sendable {
    let sounds: [(Sound, AVAudioPCMBuffer?)]
    init(_ sounds: [(Sound, AVAudioPCMBuffer?)]) { self.sounds = sounds }
  }

  nonisolated static func buffer(seconds: Double, _ fill: (Int, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void) -> AVAudioPCMBuffer? {
    let count = Int(seconds * rate)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
          let channels = buffer.floatChannelData else { return nil }
    buffer.frameLength = AVAudioFrameCount(count)
    for channel in 0..<2 { channels[channel].update(repeating: 0, count: count) }
    fill(count, channels[0], channels[1])
    return buffer
  }

  nonisolated static func make(_ sound: Sound) -> AVAudioPCMBuffer? {
    switch sound {
    // A chord that opens, and is gone.
    case .hello: return notes([(0, 57), (0.09, 64), (0.18, 69), (0.3, 73), (0.44, 76)], seconds: 3.2, level: 0.075, decay: 1.5)
    case .shimmer: return notes([(0, 81), (0.05, 85), (0.10, 88), (0.16, 93)], seconds: 1.6, level: 0.05, decay: 3)
    case .pop:
      return buffer(seconds: 0.22) { count, left, right in
        var phase = 0.0
        for frame in 0..<count {
          let time = Double(frame) / rate
          phase += 2 * .pi * (260 + 420 * (1 - exp(-time * 38))) / rate
          let value = Float(sin(phase) * exp(-time * 26) * min(1, time / 0.002) * 0.34)
          left[frame] = value
          right[frame] = value
        }
      }
    case .latch, .thud:
      let isSoft = sound == .thud
      return buffer(seconds: 0.3) { count, left, right in
        var seed: UInt64 = 88_172_645_463_325_252, low = 0.0
        for frame in 0..<count {
          let time = Double(frame) / rate
          seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
          low += ((Double(seed & 0xFFFF) / 32_768 - 1) - low) * (isSoft ? 0.08 : 0.35)
          let click = low * exp(-time * (isSoft ? 60 : 150)) * 0.3
          let body = sin(2 * .pi * (isSoft ? 92 : 420) * time) * exp(-time * (isSoft ? 24 : 55)) * (isSoft ? 0.34 : 0.16)
          let value = Float((click + body) * min(1, time / 0.001))
          left[frame] = value
          right[frame] = value
        }
      }
    }
  }

  private nonisolated static func notes(_ notes: [(at: Double, note: Double)], seconds: Double, level: Double, decay: Double) -> AVAudioPCMBuffer? {
    buffer(seconds: seconds) { count, left, right in
      for (index, one) in notes.enumerated() {
        let hertz = 440 * pow(2, (one.note - 69) / 12), start = Int(one.at * rate), pan = 0.3 + 0.4 * Double(index % 2)
        for frame in start..<count {
          let time = Double(frame - start) / rate
          let tone = sin(2 * .pi * hertz * time) + 0.22 * sin(4 * .pi * hertz * time) + 0.06 * sin(6 * .pi * hertz * time)
          let value = tone * exp(-time * decay) * min(1, time / 0.012) * min(1, Double(count - frame) / 4_000) * level
          left[frame] += Float(value * (1 - pan) * 2)
          right[frame] += Float(value * pan * 2)
        }
      }
    }
  }

  nonisolated static func read(_ url: URL, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let file = try? AVAudioFile(forReading: url), file.length > 0,
          let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: raw)) != nil else { return nil }
    guard raw.format != format, let converter = AVAudioConverter(from: raw.format, to: format) else { return raw }
    let room = AVAudioFrameCount(Double(raw.frameLength) * format.sampleRate / raw.format.sampleRate) + 4096
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: room) else { return nil }
    var isGiven = false
    converter.convert(to: out, error: nil) { _, status in
      status.pointee = isGiven ? .endOfStream : .haveData
      isGiven = true
      return raw
    }
    return out.frameLength > 0 ? out : nil
  }
}
