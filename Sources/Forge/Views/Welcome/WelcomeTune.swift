import Foundation

/// Four bars of a slow song: bells over an electric piano and a bass.
/// Everything here starts sharply and dies away, so that backwards it is heard.
enum WelcomeTune {
  static let seconds = 7.0
  /// Seconds to a beat, and where the second half of one falls: a little late.
  private static let beat = 0.68, swing = 0.08

  private struct Note {
    let at: Double
    let note: Double
    let beats: Double
    let loud: Double
  }

  /// Two beats to a chord: what the left hand plays, and the bass under it.
  private static let chords: [(bass: Double, notes: [Double])] = [
    (41, [57, 60, 64, 67]), (40, [55, 59, 62, 64]), (38, [53, 57, 60, 64]), (36, [52, 55, 59, 62]),
  ]

  /// Where, in beats, and what is sung over them.
  private static let song: [(at: Double, note: Double)] = [
    (0, 76), (0.5, 79), (1, 84), (2, 83), (2.5, 79), (3, 76),
    (4, 77), (4.5, 76), (5, 72), (5.5, 74), (6, 76), (6.5, 79), (7, 74),
  ]

  static func play(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int, rate: Double) {
    for note in hands { piano(note, left, right, count, rate) }
    for (index, chord) in chords.enumerated() {
      let start = Double(index) * 2
      bass(Note(at: start, note: chord.bass, beats: 1.4, loud: 0.2), left, right, count, rate)
      bass(Note(at: start + 1.5, note: chord.bass + (index % 2 == 0 ? 7 : 12), beats: 0.5, loud: 0.13), left, right, count, rate)
    }
    for note in song { bell(Note(at: note.at, note: note.note + 12, beats: 3, loud: 0.06), left, right, count, rate) }
    echo(left, right, count, rate)
    let fade = rate * 0.6
    for frame in 0..<count {
      let level = Float(min(1, Double(count - frame) / fade))
      left[frame] *= level
      right[frame] *= level
    }
  }

  private static var hands: [Note] {
    let last = chords.count - 1
    let chorded = chords.enumerated().flatMap { index, chord in
      chord.notes.enumerated().flatMap { finger, note -> [Note] in
        let start = Double(index) * 2, roll = Double(finger) * 0.025
        let held = Note(at: start + roll, note: note, beats: index == last ? 3.5 : 1.4, loud: 0.06)
        return index == last ? [held] : [held, Note(at: start + 1.5 + roll / 2, note: note, beats: 0.45, loud: 0.035)]
      }
    }
    return chorded
  }

  private static func frame(_ beats: Double, _ rate: Double) -> Int {
    let isLate = abs(beats.truncatingRemainder(dividingBy: 1) - 0.5) < 0.1
    return Int((beats + (isLate ? swing : 0)) * beat * rate)
  }

  private static func hertz(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }

  /// A tine: a tone that begins bright and is round a moment later.
  private static func piano(_ one: Note, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int, _ rate: Double) {
    let start = frame(one.at, rate), held = one.beats * beat, pitch = 2 * Double.pi * hertz(one.note)
    for frame in start..<max(start, min(count, start + Int((held + 0.5) * rate))) {
      let time = Double(frame - start) / rate
      let off = time > held ? exp(-(time - held) * 14) : 1
      let bright = sin(pitch * time) * 1.3 * exp(-time * 3.2)
      let bell = sin(pitch * 4 * time) * 0.16 * exp(-time * 11)
      let value = (sin(pitch * time + bright) + bell) * exp(-time * 1.15) * min(1, time / 0.003) * off * one.loud
      let sway = sin(2 * .pi * 2.4 * Double(frame) / rate) * 0.3
      left[frame] += Float(value * (1 + sway))
      right[frame] += Float(value * (1 - sway))
    }
  }

  private static let parts: [(ratio: Double, loud: Double, fade: Double)] = [(1, 1, 2.6), (2.004, 0.42, 3.9), (3.01, 0.2, 5.7), (4.17, 0.14, 7.8), (5.43, 0.1, 11)]

  private static func bell(_ one: Note, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int, _ rate: Double) {
    let start = frame(one.at, rate), pitch = 2 * Double.pi * hertz(one.note), pan = 0.5 + (one.note - 90) / 40
    for frame in start..<max(start, min(count, start + Int(one.beats * beat * rate))) {
      let time = Double(frame - start) / rate
      let value = parts.reduce(0) { $0 + sin(pitch * $1.ratio * time) * exp(-time * $1.fade) * $1.loud } * min(1, time / 0.0012) * one.loud
      left[frame] += Float(value * (1 - pan) * 2)
      right[frame] += Float(value * pan * 2)
    }
  }

  private static func bass(_ one: Note, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int, _ rate: Double) {
    let start = frame(one.at, rate), held = one.beats * beat, pitch = 2 * Double.pi * hertz(one.note)
    for frame in start..<max(start, min(count, start + Int((held + 0.2) * rate))) {
      let time = Double(frame - start) / rate
      let off = time > held ? exp(-(time - held) * 25) : 1
      let value = Float((sin(pitch * time) + 0.25 * sin(pitch * 2 * time) * exp(-time * 5)) * exp(-time * 1.3) * min(1, time / 0.006) * off * one.loud)
      left[frame] += value
      right[frame] += value
    }
  }

  /// Back from one side and then the other, softer every time.
  private static func echo(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int, _ rate: Double) {
    let late = Int(beat * 0.75 * rate)
    guard late < count else { return }
    for frame in late..<count {
      let wasLeft = left[frame - late]
      left[frame] += right[frame - late] * 0.22
      right[frame] += wasLeft * 0.22
    }
  }
}
