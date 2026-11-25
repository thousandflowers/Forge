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
  private var sounds: [Sound: [AVAudioPCMBuffer]] = [:]
  private var turn = 0
  private var said: [Sound: Int] = [:]
  private var isRunning = false

  var isOn = true { didSet { engine.mainMixerNode.outputVolume = isOn ? 1 : 0 } }

  /// A Mac with nothing to play on has a quiet welcome.
  func begin() async {
    guard !isRunning else { return }
    let made = await Task.detached(priority: .userInitiated) { Made(Sound.allCases.map { sound in (sound, (0..<Self.ways(of: sound)).compactMap { Self.make(sound, $0) }) }) }.value
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2), !isRunning else { return }
    for (sound, buffers) in made.sounds { sounds[sound] = buffers }
    for node in effects + [sample] { engine.attach(node) }
    engine.attach(room)
    room.loadFactoryPreset(.mediumRoom)
    room.wetDryMix = 18
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
    guard isRunning, let buffers = sounds[sound], !buffers.isEmpty else { return }
    let buffer = buffers[said[sound, default: 0] % buffers.count]
    said[sound, default: 0] += 1
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
    let sounds: [(Sound, [AVAudioPCMBuffer])]
    init(_ sounds: [(Sound, [AVAudioPCMBuffer])]) { self.sounds = sounds }
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

  /// How many of it there are: nothing heard twice in a row is the same.
  nonisolated static func ways(of sound: Sound) -> Int {
    switch sound {
    case .pop: return 7
    case .latch, .thud: return 3
    case .shimmer: return 3
    case .hello: return 1
    }
  }

  nonisolated static func make(_ sound: Sound, _ way: Int = 0) -> AVAudioPCMBuffer? {
    switch sound {
    // Up once, up again from higher, and a burst at the top.
    case .hello:
      return chimes(2.6, way) { chimes in
        chimes.run(6, from: 0, at: 0, over: 0.36, loud: 0.05, fade: 4)
        chimes.run(8, from: 3, at: 0.4, over: 0.42, loud: 0.055, fade: 3.2)
        chimes.dust(50, from: 0.1, over: 0.8, loud: 0.022)
        chimes.dust(110, from: 0.8, over: 1.3, loud: 0.038)
      }
    // A fingertip, and a giggle.
    case .pop:
      return chimes(0.9, way) { chimes in
        chimes.run(3, from: 3 + way % 4, at: 0, over: 0.15, loud: 0.07, fade: 8)
        chimes.dust(22, from: 0.03, over: 0.4, loud: 0.034)
      }
    case .latch:
      return chimes(0.9, way) { chimes in
        chimes.run(2, from: 3 + way, at: 0, over: 0.16, loud: 0.06, fade: 7)
        chimes.dust(12, from: 0.05, over: 0.4, loud: 0.024)
      }
    // A wand.
    case .shimmer:
      return chimes(1.9, way) { chimes in
        chimes.run(8, from: 1 + way, at: 0, over: 0.4, loud: 0.06, fade: 4.6)
        chimes.dust(110, from: 0.04, over: 1.2, loud: 0.04)
      }
    // Down two, and held: it did not come off.
    case .thud:
      return chimes(0.6, way) { chimes in
        chimes.run(2, from: 4, by: -1, at: 0, over: 0.2, loud: 0.07, fade: 14)
      }
    }
  }

  private nonisolated static func chimes(_ seconds: Double, _ way: Int, _ ring: (inout WelcomeChimes) -> Void) -> AVAudioPCMBuffer? {
    buffer(seconds: seconds) { count, left, right in
      let seed = 88_172_645_463_325_252 &+ UInt64(way) &* 6_364_136_223_846_793_005 &+ UInt64(count)
      var chimes = WelcomeChimes(left: left, right: right, count: count, rate: rate, chance: WelcomeSamples.Chance(state: seed))
      ring(&chimes)
      // Let go of, rather than cut off.
      for frame in max(0, count - 4_000)..<count {
        left[frame] *= Float(count - frame) / 4_000
        right[frame] *= Float(count - frame) / 4_000
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
