import AVFoundation
import Foundation

/// How loud a recording is to somebody listening, by the measure broadcasters
/// agreed on (ITU-R BS.1770): weighed the way ears weigh, and without counting
/// the silences.
enum Loudness {
  /// What podcasts and phones are made for.
  static let target = -16.0
  /// As loud as a peak may get before it is heard as a crack.
  private static let ceiling = -1.0
  /// Louder than this is turning up the hiss.
  private static let most = 30.0

  /// How much to multiply every sample by.
  static func gain(for file: AVAudioFile) throws -> Float {
    let (loudness, peak) = try measure(file)
    guard loudness.isFinite, peak > 0 else { return 1 }
    let wanted = min(target - loudness, most)
    let room = ceiling - 20 * log10(Double(peak))
    return Float(pow(10, min(wanted, room) / 20))
  }

  static func measure(_ file: AVAudioFile) throws -> (loudness: Double, peak: Float) {
    let format = file.processingFormat
    let rate = format.sampleRate
    let channels = Int(format.channelCount)
    // Four hundred milliseconds, every hundred.
    let hop = AVAudioFrameCount(rate / 10)
    guard hop > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hop) else { return (-.infinity, 0) }
    var filters = (0..<channels).map { _ in (Biquad.shelf(rate), Biquad.highPass(rate)) }
    var hops: [Double] = []
    var peak: Float = 0
    file.framePosition = 0
    while file.framePosition < file.length {
      try Task.checkCancellation()
      try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(hop), file.length - file.framePosition)))
      guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
      var energy = 0.0
      for channel in 0..<channels {
        var sum = 0.0
        for index in 0..<Int(buffer.frameLength) {
          let sample = data[channel][index]
          peak = max(peak, abs(sample))
          let heard = filters[channel].1.run(filters[channel].0.run(Double(sample)))
          sum += heard * heard
        }
        energy += sum / Double(buffer.frameLength)
      }
      hops.append(energy)
    }
    file.framePosition = 0

    // Shorter than a block is all the block there is.
    let size = min(4, hops.count)
    guard size > 0 else { return (-.infinity, peak) }
    let blocks = (0...(hops.count - size)).map { hops[$0..<($0 + size)].reduce(0, +) / Double(size) }
    func level(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
    let audible = blocks.filter { level($0) > -70 }
    guard !audible.isEmpty else { return (-.infinity, peak) }
    let gate = level(audible.reduce(0, +) / Double(audible.count)) - 10
    let counted = audible.filter { level($0) > gate }
    return (level(counted.reduce(0, +) / Double(counted.count)), peak)
  }

  private struct Biquad {
    let b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0

    mutating func run(_ x: Double) -> Double {
      let y = b0 * x + z1
      z1 = b1 * x - a1 * y + z2
      z2 = b2 * x - a2 * y
      return y
    }

    /// The head: higher sounds are heard louder.
    static func shelf(_ rate: Double) -> Biquad {
      let k = tan(.pi * 1681.974450955533 / rate), q = 0.7071752369554196
      let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
      let a0 = 1 + k / q + k * k
      return Biquad(
        b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
        a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0
      )
    }

    /// And the rumble hardly at all.
    static func highPass(_ rate: Double) -> Biquad {
      let k = tan(.pi * 38.13547087602444 / rate), q = 0.5003270373238773
      let a0 = 1 + k / q + k * k
      return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
  }
}
