import Foundation

/// A celesta: round, struck softly, with a halo that opens an octave above each
/// note once it has been heard. Five notes to a phrase, in D, and no noise at
/// all: what crackled was heard as broken glass.
struct WelcomeCelesta {
  let left: UnsafeMutablePointer<Float>
  let right: UnsafeMutablePointer<Float>
  let count: Int
  let rate: Double
  /// Nothing is played quite on time, or quite as hard as before.
  var chance: WelcomeSamples.Chance

  struct Note {
    let at: Double
    /// Of the scale, from one; eight is the first again, higher.
    let degree: Int
    let loud: Double
    init(_ at: Double, _ degree: Int, _ loud: Double = 1) { (self.at, self.degree, self.loud) = (at, degree, loud) }
  }

  /// What every touch is the next note of.
  static let tune = [5, 8, 10, 9, 6, 8, 12, 10]

  private static let major = [0, 2, 4, 5, 7, 9, 11]
  private static let root = 74
  private static let highest = 9_500.0
  /// What is this soft is not heard, and not worked out.
  private static let silence = 7.0
  /// Back from the walls, from the other side: how late, and how much of it.
  private static let walls: [(late: Double, much: Float)] = [(0.023, 0.14), (0.037, 0.11), (0.059, 0.08), (0.083, 0.05)]

  private static func hertz(_ degree: Int, octaves: Int = 0) -> Double {
    let step = degree - 1
    return 440 * pow(2, Double(root + major[step % major.count] + 12 * (step / major.count + octaves) - 69) / 12)
  }

  private mutating func between(_ low: Double, _ high: Double) -> Double { low + (high - low) * chance.next() }

  mutating func play(_ notes: [Note], loud: Double, from start: Double = 0) {
    for (index, note) in notes.enumerated() {
      let pan = 0.5 + 0.28 * sin(Double(index) * 2.1 + Double(note.degree))
      let when = max(0, start + note.at + between(-0.008, 0.008))
      strike(Self.hertz(note.degree), at: when, loud: loud * note.loud * between(0.88, 1.08), pan: pan)
    }
  }

  private mutating func strike(_ pitch: Double, at start: Double, loud: Double, pan: Double) {
    let hertz = pitch * pow(2, between(-4, 4) / 1_200)
    for part in [(1.0, 1.0, 3.0), (2.0, 0.1, 4.0), (4.0, 0.11, 9.0)] {
      tone(hertz * part.0, at: start, loud: loud * part.1 * between(0.85, 1.1), fade: part.2, pan: pan, rise: 0.004)
    }
    tone(hertz * 2, at: start + 0.03, loud: loud * 0.2, fade: 2.6, pan: 1 - pan, rise: 0.07)
    tone(hertz * 3, at: start + 0.06, loud: loud * 0.07, fade: 2.4, pan: pan, rise: 0.11)
    tone(hertz * 1.003, at: start, loud: loud * 0.22, fade: 2.8, pan: 1 - pan, rise: 0.02)
  }

  /// Felt more than heard, under the rest of it.
  private func bloom(_ degree: Int, at start: Double, loud: Double) {
    let hertz = Self.hertz(degree, octaves: -2)
    for part in [(1.0, 0.5, 0.9, 0.02), (2.0, 0.25, 1.1, 0.03), (3.0, 0.08, 1.4, 0.05)] {
      tone(hertz * part.0, at: start, loud: loud * part.1 * 2, fade: part.2, pan: 0.4, rise: part.3)
      tone(hertz * part.0 * 1.002, at: start, loud: loud * part.1 * 1.2, fade: part.2, pan: 0.6, rise: part.3)
    }
  }

  /// A run that hurries, a breath, and home: the low note, the whole chord, and
  /// four notes to sign it.
  /// So many at once that each is played at less than half.
  mutating func end() {
    let less = 0.46
    var when = 0.0
    for (index, degree) in [5, 7, 9, 11, 12, 14, 16, 18].enumerated() {
      play([Note(when, degree, 0.55 + 0.05 * Double(index))], loud: 0.12 * less)
      when += 0.125 * pow(0.88, Double(index))
    }
    bloom(5, at: 0, loud: 0.1 * less)
    let home = when + 0.17
    bloom(1, at: home, loud: 0.26 * less)
    bloom(5, at: home + 0.015, loud: 0.13 * less)
    play([Note(0, 1, 0.9), Note(0.022, 5, 0.8), Note(0.044, 8, 0.95), Note(0.066, 10, 0.9), Note(0.088, 12, 0.95), Note(0.115, 15)], loud: 0.15 * less, from: home)
    for (degree, loud) in [(8, 1.0), (10, 0.7), (12, 0.8), (16, 0.4)] {
      tone(Self.hertz(degree), at: home + 0.05, loud: 0.05 * loud * less, fade: 0.75, pan: 0.25 + 0.12 * Double(degree % 5), rise: 0.5)
    }
    play([Note(0.95, 12, 0.5), Note(1.1, 15, 0.6), Note(1.25, 17, 0.5), Note(1.55, 22, 0.42)], loud: 0.14 * less, from: home)
  }

  /// The room it is in, and then nothing: let go of, rather than cut off.
  func settle(over seconds: Double) {
    for wall in Self.walls {
      let late = Int(wall.late * rate)
      guard late < count else { continue }
      // From the far end: what comes back does not come back again.
      for frame in stride(from: count - 1, through: late, by: -1) {
        let was = left[frame - late]
        left[frame] += right[frame - late] * wall.much
        right[frame] += was * wall.much
      }
    }
    let fade = min(count, Int(seconds * rate))
    for frame in (count - fade)..<count {
      let level = Float(count - frame) / Float(fade)
      left[frame] *= level
      right[frame] *= level
    }
  }

  private func tone(_ hertz: Double, at start: Double, loud: Double, fade: Double, pan: Double, rise: Double) {
    guard hertz < Self.highest else { return }
    let first = Int(start * rate), last = min(count, first + Int(Self.silence / fade * rate)), turn = 2 * Double.pi * hertz
    let toLeft = cos(pan * .pi / 2) * 1.41 * loud, toRight = sin(pan * .pi / 2) * 1.41 * loud
    for frame in first..<max(first, last) {
      let time = Double(frame - first) / rate
      let value = sin(turn * time) * exp(-time * fade) * (1 - exp(-time / rise))
      left[frame] += Float(value * toLeft)
      right[frame] += Float(value * toRight)
    }
  }
}
