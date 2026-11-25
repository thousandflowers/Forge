import AppKit
import Combine
import SwiftUI

/// That something is being converted, and then what came of it: for whatever
/// shows it.
@MainActor
final class WorkSigns: ObservableObject {
  struct Word: Equatable {
    enum Kind { case done, failed, leftAlone }
    let kind: Kind
    let title: String
    let detail: String
  }

  enum State: Equatable {
    case resting
    case working(Double)
    case said(Word)
  }

  /// What the icon in the menu bar is.
  enum Hammer: Equatable {
    case still
    case striking(Int)
    case said(Word.Kind)
  }

  @Published private(set) var state = State.resting { didSet { if state != oldValue { strike() } } }
  @Published private(set) var hammer = Hammer.still
  var place = AppSettings.WorkSign.nowhere {
    didSet {
      guard place != oldValue else { return }
      if place == .nowhere { forget() }
      strike()
    }
  }

  private var jobs: [UUID: (file: URL, fraction: Double)] = [:]
  private var ended: [(file: URL, outcome: Running.Outcome)] = []
  private var began = Date()
  private var settling: Task<Void, Never>?
  private var striking: Task<Void, Never>?
  private let hasNotch: @MainActor () -> Bool
  private let isStill: @MainActor () -> Bool
  private let times: Times

  struct Times {
    /// One blow, or nobody sees it.
    var least = 0.75
    /// Between one file of many and the next.
    var between = 0.35
    var done = 2.2
    /// Longer: there is something to read.
    var failed = 4.5
  }

  init(
    times: Times = Times(), hasNotch: @escaping @MainActor () -> Bool = { NotchZone.cutout() != nil },
    isStill: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  ) {
    self.times = times
    self.hasNotch = hasNotch
    self.isStill = isStill
  }

  func hear(_ event: Running.Event) {
    guard place != .nowhere else { return }
    switch event {
    case .began(let id, let file):
      settling?.cancel()
      if case .working = state {} else { began = Date(); ended = [] }
      jobs[id] = (file, 0)
      state = .working(fraction)
    case .reached(let id, let share):
      guard let job = jobs[id] else { return }
      jobs[id] = (job.file, max(job.fraction, min(share, 1)))
      if case .working = state { state = .working(fraction) }
    case .ended(let id, let outcome):
      guard let job = jobs.removeValue(forKey: id) else { return }
      ended.append((job.file, outcome))
      state = .working(fraction)
      if jobs.isEmpty { settle() }
    }
  }

  /// What is going on goes on unseen, and would never be heard to end.
  private func forget() {
    settling?.cancel()
    jobs = [:]
    ended = []
    state = .resting
  }

  /// In hundredths: a film says where it is many times a second.
  private var fraction: Double {
    let all = Double(jobs.count + ended.count)
    guard all > 0 else { return 0 }
    return ((jobs.values.reduce(0) { $0 + $1.fraction } + Double(ended.count)) / all * 100).rounded() / 100
  }

  private func settle() {
    let wait = max(times.between, times.least - Date().timeIntervalSince(began))
    settling = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      guard let word = Self.word(for: self.ended) else { return self.state = .resting }
      self.state = .said(word)
      try? await Task.sleep(nanoseconds: UInt64((word.kind == .done ? self.times.done : self.times.failed) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self.state = .resting
    }
  }

  static func word(for ended: [(file: URL, outcome: Running.Outcome)]) -> Word? {
    let said = ended.filter { $0.outcome != .quiet }
    let failed = said.compactMap { one -> (URL, String)? in if case .failed(let why) = one.outcome { return (one.file, why) } else { return nil } }
    if let (file, why) = failed.first {
      return Word(kind: .failed, title: said.count == 1 ? "Not converted" : "\(failed.count) of \(said.count) not converted", detail: failed.count == 1 ? why : file.lastPathComponent)
    }
    let done = said.compactMap { one -> (URL, String)? in if case .done(let what) = one.outcome { return (one.file, what) } else { return nil } }
    if let (file, what) = done.first {
      let same = done.allSatisfy { $0.1 == what }
      return Word(kind: .done, title: same ? what : "Converted", detail: done.count == 1 ? file.lastPathComponent : "\(done.count) files")
    }
    guard case .leftAlone(let why)? = said.first?.outcome, let first = said.first else { return nil }
    return Word(kind: .leftAlone, title: "Left as it is", detail: said.count == 1 ? why : first.file.lastPathComponent)
  }

  /// The whole of it, with nothing converted: to see what was chosen.
  func rehearse() {
    let id = UUID()
    hear(.began(id, URL(fileURLWithPath: "/photo_gray.jpg")))
    Task { [weak self] in
      for step in 1...20 {
        try? await Task.sleep(nanoseconds: 90_000_000)
        self?.hear(.reached(id, Double(step) / 20))
      }
      self?.hear(.ended(id, .done(Tool.gray.title)))
    }
  }

  // MARK: - The hammer

  private func strike() {
    guard place.showsHammer(hasNotch: hasNotch()) else { return rest(.still) }
    switch state {
    case .resting: rest(.still)
    case .said(let word): rest(.said(word.kind))
    case .working:
      guard striking == nil else { return }
      guard !isStill() else { hammer = .striking(0); return }
      let start = Date()
      striking = Task { [weak self] in
        while !Task.isCancelled {
          let frame = HammerFrames.frame(after: Date().timeIntervalSince(start))
          if self?.hammer != .striking(frame) { self?.hammer = .striking(frame) }
          try? await Task.sleep(nanoseconds: HammerFrames.step)
        }
      }
    }
  }

  private func rest(_ as: Hammer) {
    striking?.cancel()
    striking = nil
    if hammer != `as` { hammer = `as` }
  }
}

/// One blow of a hammer: lifted slowly, let fall, and the little it springs back.
enum Blow {
  static let seconds = 0.9

  /// Degrees, up being more. Pivoting on the end of its handle.
  static func angle(at time: Double) -> Double {
    let t = (time / seconds).truncatingRemainder(dividingBy: 1)
    switch t {
    case ..<0.42: return 30 * ease(t / 0.42)
    case ..<0.54: let fall = (t - 0.42) / 0.12; return 30 - 46 * fall * fall
    case ..<0.70: return -16 + 16 * ease((t - 0.54) / 0.16)
    default: return 0
    }
  }

  /// How far the sparks have flown, and nil while there are none.
  static func sparks(at time: Double) -> Double? {
    let t = (time / seconds).truncatingRemainder(dividingBy: 1)
    return (0.53..<0.80).contains(t) ? (t - 0.53) / 0.27 : nil
  }

  private static func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}

/// The icon in the menu bar, drawn: what is there is a picture, and is moved by
/// changing it.
@MainActor
enum HammerFrames {
  private static let count = 18
  static let step = UInt64(Blow.seconds / Double(count) * 1_000_000_000)
  private static let size = NSSize(width: 24, height: 18)
  private static var made: [Int: NSImage] = [:]
  private static var symbols: [String: NSImage] = [:]

  static func frame(after time: Double) -> Int { Int((time / Blow.seconds * Double(count)).rounded(.down)) % count }

  static func image(for hammer: WorkSigns.Hammer) -> NSImage {
    switch hammer {
    case .still: return centred("hammer")
    case .said(let kind): return centred(NotchSignView.symbol(for: kind))
    case .striking(let frame):
      if let known = made[frame] { return known }
      let drawn = draw(frame)
      made[frame] = drawn
      return drawn
    }
  }

  private static func symbol(_ name: String) -> NSImage {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    let icon = image.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? image
    icon.isTemplate = true
    return icon
  }

  /// As wide as the rest, or whatever is beside it in the menu bar would jump.
  private static func centred(_ name: String) -> NSImage {
    if let known = symbols[name] { return known }
    let icon = symbol(name)
    let image = NSImage(size: size, flipped: false) { place in
      icon.draw(in: NSRect(x: place.midX - icon.size.width / 2, y: place.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
      return true
    }
    image.isTemplate = true
    symbols[name] = image
    return image
  }

  private static func draw(_ frame: Int) -> NSImage {
    let time = Double(frame) / Double(count) * Blow.seconds
    let hammer = symbol("hammer.fill")
    let image = NSImage(size: size, flipped: false) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      let side = 16.0, corner = CGPoint(x: 1, y: 2)
      context.saveGState()
      context.translateBy(x: corner.x + 2, y: corner.y + 1)
      context.rotate(by: Blow.angle(at: time) * .pi / 180)
      context.translateBy(x: -2, y: -1)
      hammer.draw(in: NSRect(x: 0, y: 0, width: side, height: side * hammer.size.height / max(1, hammer.size.width)))
      context.restoreGState()
      if let flown = Blow.sparks(at: time) {
        context.setStrokeColor(CGColor(gray: 0, alpha: 1 - flown))
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        for angle in [75.0, 35, -5] {
          let way = CGPoint(x: cos(angle * .pi / 180), y: sin(angle * .pi / 180))
          let from = 1.5 + flown * 2.5, to = from + 2 * (1 - flown) + 0.6
          context.move(to: CGPoint(x: 18.5 + way.x * from, y: 5 + way.y * from))
          context.addLine(to: CGPoint(x: 18.5 + way.x * to, y: 5 + way.y * to))
        }
        context.strokePath()
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
