import AVFoundation

/// What the welcome sounds like: short and soft, one for every thing that
/// happens. Each is worked out here; nothing recorded is in the app.
@MainActor
final class WelcomeScore {
  enum Sound: CaseIterable { case touch, pop, latch, shimmer, thud, finale }

  nonisolated static let rate = 44_100.0
  private let engine = AVAudioEngine()
  private let effects = [AVAudioPlayerNode(), AVAudioPlayerNode(), AVAudioPlayerNode()]
  private let sample = AVAudioPlayerNode()
  private var sounds: [Sound: [AVAudioPCMBuffer]] = [:]
  private var turn = 0
  private var said: [Sound: Int] = [:]
  private var isRunning = false
  private var ending: Task<Void, Never>?

  var isOn = true { didSet { engine.mainMixerNode.outputVolume = isOn ? 1 : 0 } }

  /// A Mac with nothing to play on has a quiet welcome.
  func begin() async {
    ending?.cancel()
    guard !isRunning else { return }
    let made = await Task.detached(priority: .userInitiated) { Made(Sound.allCases.map { sound in (sound, (0..<Self.ways(of: sound)).compactMap { Self.make(sound, $0) }) }) }.value
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2), !isRunning else { return }
    for (sound, buffers) in made.sounds { sounds[sound] = buffers }
    for node in effects + [sample] { engine.attach(node) }
    for node in effects { engine.connect(node, to: engine.mainMixerNode, format: format) }
    engine.connect(sample, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = isOn ? 1 : 0
    do { try engine.start() } catch { return }
    isRunning = true
    for node in effects + [sample] { node.play() }
  }

  /// The note of one tile, played a little differently every time.
  func touch(_ tile: Int) {
    let turn = said[.touch, default: 0] % Self.touches
    said[.touch] = turn * WelcomeCelesta.motif.count + tile
    play(.touch)
    said[.touch] = turn + 1
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
    hush()
    // The last of it is heard, and not cut short by whoever is done.
    ending = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.last * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      engine.stop()
      isRunning = false
    }
  }

  /// How many ways there are to play one note.
  private nonisolated static let touches = 3
  /// How long the finale is.
  private nonisolated static let last = 5.2

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

  /// How many of it there are: every touch is the next note of one tune.
  nonisolated static func ways(of sound: Sound) -> Int {
    switch sound {
    case .touch: return WelcomeCelesta.motif.count * touches
    case .pop: return WelcomeCelesta.tune.count
    case .latch, .shimmer: return 2
    case .thud, .finale: return 1
    }
  }

  nonisolated static func make(_ sound: Sound, _ way: Int = 0) -> AVAudioPCMBuffer? {
    typealias Note = WelcomeCelesta.Note
    switch sound {
    // Softer than a press, and by itself: across the three it is the motif.
    case .touch:
      return celesta(0.9, way) { $0.play([Note(0, WelcomeCelesta.motif[way % WelcomeCelesta.motif.count])], loud: 0.1) }
    case .pop:
      let degree = WelcomeCelesta.tune[way % WelcomeCelesta.tune.count]
      return celesta(0.8, way) { $0.play([Note(0, degree > 8 ? 5 : 3, 0.3), Note(0.055, degree)], loud: 0.17) }
    // Up a fourth, or a third: on to the next thing.
    case .latch:
      return celesta(1.1, way) { $0.play(way == 0 ? [Note(0, 5, 0.75), Note(0.13, 8)] : [Note(0, 8, 0.75), Note(0.13, 10)], loud: 0.16) }
    case .shimmer:
      let phrase = way == 0
        ? [Note(0, 5, 0.7), Note(0.09, 8, 0.8), Note(0.18, 10, 0.85), Note(0.3, 12), Note(0.36, 13, 0.45), Note(0.44, 15)]
        : [Note(0, 3, 0.7), Note(0.09, 5, 0.75), Note(0.18, 8, 0.85), Note(0.27, 10, 0.9), Note(0.4, 12, 0.6), Note(0.48, 15)]
      return celesta(2, way) { $0.play(phrase, loud: 0.14) }
    // Down, and not home: it did not come off.
    case .thud:
      return celesta(1, way) { $0.play([Note(0, 10, 0.7), Note(0.17, 9, 0.8)], loud: 0.12) }
    case .finale:
      return celesta(last, way) { $0.end() }
    }
  }

  private nonisolated static func celesta(_ seconds: Double, _ way: Int, _ play: (inout WelcomeCelesta) -> Void) -> AVAudioPCMBuffer? {
    buffer(seconds: seconds) { count, left, right in
      let seed = 88_172_645_463_325_252 &+ UInt64(way) &* 6_364_136_223_846_793_005 &+ UInt64(count)
      var celesta = WelcomeCelesta(left: left, right: right, count: count, rate: rate, chance: WelcomeSamples.Chance(state: seed))
      play(&celesta)
      celesta.settle(over: seconds / 8)
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
