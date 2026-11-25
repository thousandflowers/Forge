import Foundation

/// A wind chime in the light: metal tubes of no scale anybody tuned, knocked
/// together unevenly, and the sparks that come off them.
struct WelcomeChimes {
  let left: UnsafeMutablePointer<Float>
  let right: UnsafeMutablePointer<Float>
  let count: Int
  let rate: Double
  /// What happens is decided by this, and is never quite what happened before.
  var chance: WelcomeSamples.Chance

  /// Hertz, from the longest. Cut by eye.
  static let tubes: [Double] = [631, 718, 846, 937, 1093, 1239, 1466, 1642, 1931, 2204]

  /// How a bar that is free at both ends rings: not at all like a string.
  private static let modes: [(ratio: Double, loud: Double, fade: Double)] = [
    (1, 0.55, 1), (2.756, 0.85, 1.5), (5.404, 0.5, 2.6), (8.933, 0.26, 4.6), (13.34, 0.12, 8),
  ]
  private static let highest = 17_000.0
  /// What is this soft is not heard, and not worked out.
  private static let silence = 6.5

  private mutating func between(_ low: Double, _ high: Double) -> Double { low + (high - low) * chance.next() }

  /// Several of them, one after another and none twice running.
  mutating func stir(_ hits: Int, among range: ClosedRange<Int>, from start: Double, over seconds: Double, loud: Double, fade: Double = 2.4) {
    var last = -1, when = start
    for hit in 0..<hits {
      var tube = range.lowerBound + Int(chance.next() * Double(range.count)) % range.count
      if tube == last { tube = tube == range.upperBound ? range.lowerBound : tube + 1 }
      last = tube
      knock(tube, at: when, loud: loud * between(0.55, 1) * (1 - 0.35 * Double(hit) / Double(hits)), fade: fade)
      when += seconds / Double(hits) * between(0.35, 1.65)
    }
  }

  private mutating func knock(_ tube: Int, at start: Double, loud: Double, fade: Double) {
    // The air, the sun, where it was caught.
    let hertz = Self.tubes[tube] * between(0.986, 1.014)
    let pan = min(0.9, max(0.1, 0.12 + 0.76 * Double(tube) / Double(Self.tubes.count - 1) + between(-0.1, 0.1)))
    ring(hertz, at: start, loud: loud, fade: fade, pan: pan)
    // What hit it comes back for a second, softer, go.
    if chance.next() < 0.45 { ring(hertz, at: start + between(0.035, 0.1), loud: loud * 0.35, fade: fade * 1.2, pan: pan) }
  }

  private mutating func ring(_ hertz: Double, at start: Double, loud: Double, fade: Double, pan: Double) {
    for mode in Self.modes where hertz * mode.ratio < Self.highest {
      let much = loud * mode.loud * between(0.6, 1.25), goes = fade * mode.fade * between(0.85, 1.2)
      tone(hertz * mode.ratio, at: start, loud: much, fade: goes, pan: pan)
      // Not perfectly round, and so never quite at one pitch: it wavers.
      tone(hertz * mode.ratio * (1 + between(0.0007, 0.0026)), at: start, loud: much * 0.55, fade: goes, pan: 1 - pan)
    }
    touch(at: start, loud: loud, pan: pan)
  }

  /// One thing against another, before either of them rings.
  private mutating func touch(at start: Double, loud: Double, pan: Double) {
    let first = Int(start * rate), knock = between(2_300, 4_200) * 2 * .pi
    var before = 0.0
    for frame in first..<max(first, min(count, first + Int(0.02 * rate))) {
      let time = Double(frame - first) / rate
      let noise = chance.next() * 2 - 1
      let value = ((noise - before) * exp(-time * 620) * 0.7 + sin(knock * time) * exp(-time * 320) * 0.5) * loud
      before = noise
      left[frame] += Float(value * (1 - pan) * 2)
      right[frame] += Float(value * pan * 2)
    }
  }

  /// Sparks: tiny, very high, at no note at all, and fewer as it goes on. Some
  /// of them only crackle.
  mutating func dust(_ grains: Int, from start: Double, over seconds: Double, loud: Double) {
    for _ in 0..<grains {
      let when = pow(chance.next(), 1.6), at = start + when * seconds, level = loud * between(0.25, 1) * (1 - 0.7 * when), pan = between(0.08, 0.92)
      if chance.next() < 0.3 {
        touch(at: at, loud: level * 0.8, pan: pan)
      } else {
        let hertz = 4_200 * pow(3, chance.next())
        tone(hertz, at: at, loud: level, fade: between(18, 55), pan: pan)
        tone(hertz * between(1.2, 1.5), at: at, loud: level * 0.4, fade: between(40, 80), pan: pan)
      }
    }
  }

  private func tone(_ hertz: Double, at start: Double, loud: Double, fade: Double, pan: Double) {
    guard hertz < Self.highest else { return }
    let first = Int(start * rate), last = min(count, first + Int(Self.silence / fade * rate)), turn = 2 * Double.pi * hertz
    for frame in first..<max(first, last) {
      let time = Double(frame - first) / rate
      let value = sin(turn * time) * exp(-time * fade) * min(1, time / 0.0008) * loud
      left[frame] += Float(value * (1 - pan) * 2)
      right[frame] += Float(value * pan * 2)
    }
  }
}
