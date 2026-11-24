import Foundation
import UniformTypeIdentifiers

/// Something done to a file that is not a change of format.
///
/// A tool is the word for it. `speed2x` is what it is called in a file's name,
/// in a saved preset and after `forge convert --do`, and reading the word is
/// the one way any of them has of making one.
enum Tool: Hashable, Sendable {
  case mute
  /// Every file as loud as the next.
  case normalize
  case reverse
  case speed(Double)
  case loop(Int)
  /// A part of it. Fast keeps the film as it was encoded; otherwise the part
  /// starts and ends on the very frame.
  case trim(Span, fast: Bool = false)
  case divide(Division)
  case turn(Turn)
  case crop(Crop)
  case removeBackground
  /// These pages, in this order.
  case pages(PageList)
  case dropPages(PageList)
  /// A picture of the film every so many seconds.
  case frames(every: Double)

  enum Division: Hashable, Sendable {
    case every(Double)
    case parts(Int)
    case chapters
    case pages(Int)
  }

  enum Turn: String, CaseIterable, Sendable {
    case right = "rotate90", half = "rotate180", left = "rotate270", mirror, flip
  }

  enum Crop: Hashable, Sendable {
    /// As much as there is in that shape, round what the picture is of.
    case shape(Int, Int)
    /// This much of it, from the top left, as it is seen.
    case box(x: Int, y: Int, width: Int, height: Int)
  }
}

/// A stretch of time, in seconds.
struct Span: Hashable, Sendable {
  var from: Double?
  var to: Double?

  /// The stretch there really is in something this long.
  func clamped(to length: Double) -> ClosedRange<Double>? {
    let start = min(max(from ?? 0, 0), length), end = min(to ?? length, length)
    return end > start ? start...end : nil
  }
}

/// Pages as people write them: `2-5`, `1,3,7-`.
struct PageList: Hashable, Sendable {
  /// As it was written.
  let text: String
  private let runs: [(from: Int?, to: Int?)]

  init?(_ text: String) {
    var runs: [(Int?, Int?)] = []
    for piece in text.split(separator: ",", omittingEmptySubsequences: false) {
      guard let match = piece.wholeMatch(of: #/(\d{0,5})(-?)(\d{0,5})/#) else { return nil }
      let from = Int(match.1), to = Int(match.3)
      guard from != nil || to != nil, from != 0, to != 0 else { return nil }
      if match.2.isEmpty {
        guard let from else { return nil }
        runs.append((from, from))
      } else {
        runs.append((from, to))
      }
    }
    guard !runs.isEmpty else { return nil }
    self.text = text
    self.runs = runs
  }

  /// Counted from zero, in the order they were written, without the ones that
  /// are not there.
  func indices(of count: Int) -> [Int] {
    runs.flatMap { run -> [Int] in
      let from = run.from ?? 1, to = run.to ?? count
      // Page ninety-nine thousand of five is nothing to count up to.
      let inside = { (page: Int) in min(max(page, 0), count + 1) }
      let pages = from <= to ? Array(inside(from)...max(inside(from), inside(to))) : Array((inside(to)...inside(from)).reversed())
      return pages.filter { (1...max(count, 1)).contains($0) && $0 <= count }.map { $0 - 1 }
    }
  }

  static func == (a: PageList, b: PageList) -> Bool { a.text == b.text }
  func hash(into hasher: inout Hasher) { hasher.combine(text) }
}

// MARK: - Words

extension Tool {
  private static let speeds = 0.1...16.0
  private static let loops = 2...100
  private static let parts = 2...500

  /// Each takes the words it knows. In no particular order: no two take the
  /// same one.
  private static let readers: [@Sendable (String) -> Tool?] = [
    { ["mute": .mute, "normalize": .normalize, "reverse": .reverse, "nobg": .removeBackground, "splitchapters": .divide(.chapters), "splitpages": .divide(.pages(1))][$0] },
    { (Turn(rawValue: $0) ?? ["rotateright": .right, "rotateleft": .left][$0]).map(Tool.turn) },
    { $0.wholeMatch(of: #/speed(.+)x/#).flatMap { number($0.1) }.flatMap { speeds.contains($0) ? .speed($0) : nil } },
    { $0.wholeMatch(of: #/loop(\d{1,3})/#).flatMap { Int($0.1) }.flatMap { loops.contains($0) ? .loop($0) : nil } },
    { word in
      guard let match = word.wholeMatch(of: #/trim([^-]*)-(.*?)(fast)?/#) else { return nil }
      let from = seconds(match.1), to = seconds(match.2)
      guard from != nil || match.1.isEmpty, to != nil || match.2.isEmpty, from != nil || to != nil else { return nil }
      if let from, let to, to <= from { return nil }
      return .trim(Span(from: from, to: to), fast: match.3 != nil)
    },
    { $0.wholeMatch(of: #/split(\d{1,3})/#).flatMap { Int($0.1) }.flatMap { parts.contains($0) ? .divide(.parts($0)) : nil } },
    { $0.wholeMatch(of: #/split(\d{1,4})pages/#).flatMap { Int($0.1) }.flatMap { $0 > 0 ? .divide(.pages($0)) : nil } },
    // A unit, or it is a number of parts.
    { $0.wholeMatch(of: #/split(.*[hms])/#).flatMap { seconds($0.1) }.flatMap { $0 > 0 ? .divide(.every($0)) : nil } },
    { $0.wholeMatch(of: #/crop(\d{1,4})x(\d{1,4})/#).flatMap { match in
      guard let across = Int(match.1), let down = Int(match.2), across > 0, down > 0 else { return nil }
      return .crop(.shape(across, down))
    } },
    { $0.wholeMatch(of: #/crop(\d{1,5}),(\d{1,5}),(\d{1,5})x(\d{1,5})/#).flatMap { match in
      guard let x = Int(match.1), let y = Int(match.2), let width = Int(match.3), let height = Int(match.4), width > 0, height > 0 else { return nil }
      return .crop(.box(x: x, y: y, width: width, height: height))
    } },
    { word in
      guard let match = word.wholeMatch(of: #/(no)?page(s?)([\d,\-]+)/#) else { return nil }
      // One page in the singular is what a scanner calls it: `scan_page2.pdf`.
      guard !match.2.isEmpty || match.3.contains(#/[-,]/#), let list = PageList(String(match.3)) else { return nil }
      return match.1 == nil ? .pages(list) : .dropPages(list)
    },
    { $0.wholeMatch(of: #/frames(.*[hms])/#).flatMap { seconds($0.1) }.flatMap { $0 > 0 ? .frames(every: $0) : nil } },
  ]

  init?(word: String) {
    let word = word.lowercased()
    guard let tool = Self.readers.lazy.compactMap({ $0(word) }).first else { return nil }
    self = tool
  }

  var word: String {
    switch self {
    case .mute: return "mute"
    case .normalize: return "normalize"
    case .reverse: return "reverse"
    case .removeBackground: return "nobg"
    case .speed(let times): return "speed\(Self.text(times))x"
    case .loop(let times): return "loop\(times)"
    case .trim(let span, let fast):
      return "trim\(span.from.map(Self.text) ?? "")-\(span.to.map(Self.text) ?? "")\(fast ? "fast" : "")"
    case .divide(.every(let seconds)): return "split\(Self.text(seconds))s"
    case .divide(.parts(let count)): return "split\(count)"
    case .divide(.chapters): return "splitchapters"
    case .divide(.pages(let count)): return count == 1 ? "splitpages" : "split\(count)pages"
    case .turn(let turn): return turn.rawValue
    case .crop(.shape(let across, let down)): return "crop\(across)x\(down)"
    case .crop(.box(let x, let y, let width, let height)): return "crop\(x),\(y),\(width)x\(height)"
    case .pages(let list): return "pages\(list.text)"
    case .dropPages(let list): return "nopages\(list.text)"
    case .frames(let seconds): return "frames\(Self.text(seconds))s"
    }
  }

  /// To the thousandth, and no more zeros than it needs.
  static func text(_ value: Double) -> String {
    var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }

  static func number(_ text: some StringProtocol) -> Double? {
    let tidy = text.replacingOccurrences(of: ",", with: ".")
    guard tidy.wholeMatch(of: #/\d{1,7}(\.\d+)?/#) != nil else { return nil }
    return Double(tidy)
  }

  /// `45`, `1.5`, `90s`, `1m20`, `1h02m03s`, `1:20`.
  static func seconds(_ text: some StringProtocol) -> Double? {
    let text = String(text).lowercased()
    if text.contains(":") {
      let pieces = text.split(separator: ":", omittingEmptySubsequences: false).map { number($0) }
      guard (2...3).contains(pieces.count), !pieces.contains(where: { $0 == nil }) else { return nil }
      return pieces.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
    guard let match = text.wholeMatch(of: #/(?:(\d{1,3})h)?(?:(\d{1,4})m)?(?:([\d.,]+)s?)?/#), !text.isEmpty else { return nil }
    let last = match.3.map { number($0) }
    if let last, last == nil { return nil }
    return (match.1.flatMap { Double($0) } ?? 0) * 3600 + (match.2.flatMap { Double($0) } ?? 0) * 60 + ((last ?? 0) ?? 0)
  }
}

// MARK: - What they are for

extension Tool {
  /// The kinds of tool, for a library and for saying which step replaces which.
  enum Kind: String, CaseIterable, Sendable {
    case trim, divide, speed, loop, reverse, mute, normalize, frames
    case crop, turn, removeBackground
    case pages, dropPages

    var title: String {
      switch self {
      case .trim: return "Keep a part"
      case .divide: return "Divide"
      case .speed: return "Speed"
      case .loop: return "Repeat"
      case .reverse: return "Reverse"
      case .mute: return "Mute"
      case .normalize: return "Even volume"
      case .frames: return "A frame every"
      case .crop: return "Crop to a shape"
      case .turn: return "Turn or mirror"
      case .removeBackground: return "Remove background"
      case .pages: return "Keep pages"
      case .dropPages: return "Remove pages"
      }
    }

    var symbol: String {
      switch self {
      case .trim: return "scissors"
      case .divide: return "square.split.2x1"
      case .speed: return "gauge.with.needle"
      case .loop: return "repeat"
      case .reverse: return "backward"
      case .mute: return "speaker.slash"
      case .normalize: return "speaker.wave.2"
      case .frames: return "film.stack"
      case .crop: return "crop"
      case .turn: return "rotate.right"
      case .removeBackground: return "person.crop.rectangle"
      case .pages: return "doc.text.magnifyingglass"
      case .dropPages: return "doc.badge.minus"
      }
    }

    var summary: String {
      switch self {
      case .trim: return "From one second to another"
      case .divide: return "By time, in parts, by chapter or by page"
      case .speed: return "Faster or slower, at the same pitch"
      case .loop: return "The same thing again"
      case .reverse: return "From the end to the beginning"
      case .mute: return "The film without its sound"
      case .normalize: return "Every file as loud as the next"
      case .frames: return "Pictures of the film, so many seconds apart"
      case .crop: return "Square, 16 to 9, or a box of your own"
      case .turn: return "Rotate, mirror or flip"
      case .removeBackground: return "Keep what the picture is of"
      case .pages: return "These pages, in this order"
      case .dropPages: return "All the pages but these"
      }
    }

    /// What it starts as.
    var blank: Tool {
      switch self {
      case .trim: return .trim(Span(from: 0, to: 30))
      case .divide: return .divide(.parts(2))
      case .speed: return .speed(2)
      case .loop: return .loop(2)
      case .reverse: return .reverse
      case .mute: return .mute
      case .normalize: return .normalize
      case .frames: return .frames(every: 5)
      case .crop: return .crop(.shape(1, 1))
      case .turn: return .turn(.right)
      case .removeBackground: return .removeBackground
      case .pages: return .pages(PageList("1-2")!)
      case .dropPages: return .dropPages(PageList("1")!)
      }
    }

    /// What it can be done to. A PDF and no other document: the rest have no
    /// pages until something is made of them.
    var kinds: Set<ConvertKind> {
      switch self {
      case .trim, .divide, .speed, .loop, .reverse, .normalize: return [.audio, .video]
      case .mute, .frames: return [.video]
      case .crop, .turn: return [.image, .video, .document]
      case .removeBackground: return [.image]
      case .pages, .dropPages: return [.document]
      }
    }
  }

  var kind: Kind {
    switch self {
    case .mute: return .mute
    case .normalize: return .normalize
    case .reverse: return .reverse
    case .speed: return .speed
    case .loop: return .loop
    case .trim: return .trim
    case .divide: return .divide
    case .turn: return .turn
    case .crop: return .crop
    case .removeBackground: return .removeBackground
    case .pages: return .pages
    case .dropPages: return .dropPages
    case .frames: return .frames
    }
  }

  /// What another step of takes its place: a turn one way is instead of a turn
  /// another way, and not instead of a mirror.
  var slot: String {
    if case .turn(let turn) = self, turn == .mirror || turn == .flip { return turn.rawValue }
    return kind.rawValue
  }

  func suits(_ type: UTType) -> Bool {
    if case .divide(let division) = self {
      if case .pages = division { return type.conforms(to: .pdf) }
      return ConvertKind(fileType: type).map([.audio, .video].contains) ?? false
    }
    guard let kind = ConvertKind(fileType: type), self.kind.kinds.contains(kind) else { return false }
    // A PDF has a way to say it is turned, and none to say it is mirrored.
    return kind != .document || (type.conforms(to: .pdf) && self != .turn(.mirror) && self != .turn(.flip))
  }

  /// "Keep a part: 0:10 to 0:45", as a step is listed.
  var title: String {
    switch self {
    case .speed(let times): return "Speed \(Self.text(times))×"
    case .loop(let times): return "Repeat \(times) times"
    case .trim(let span, _): return "Keep \(span.from.map(Self.clock) ?? "the start") to \(span.to.map(Self.clock) ?? "the end")"
    case .divide(.every(let seconds)): return "Divide every \(Self.clock(seconds))"
    case .divide(.parts(let count)): return "Divide in \(count)"
    case .divide(.chapters): return "Divide by chapter"
    case .divide(.pages(let count)): return count == 1 ? "Divide page by page" : "Divide every \(count) pages"
    case .turn(let turn): return turn.title
    case .crop(.shape(let across, let down)): return "Crop \(across):\(down)"
    case .crop(.box(_, _, let width, let height)): return "Crop \(width) × \(height)"
    case .pages(let list): return "Pages \(list.text)"
    case .dropPages(let list): return "Without pages \(list.text)"
    case .frames(let seconds): return "A frame every \(Self.text(seconds)) s"
    case .mute, .normalize, .reverse, .removeBackground: return kind.title
    }
  }

  /// 80 as 1:20.
  static func clock(_ seconds: Double) -> String {
    let whole = Int(seconds), rest = seconds - Double(whole)
    let tail = rest > 0.0005 ? text(rest).dropFirst() : ""
    let minutes = whole / 60 % 60, left = whole % 60
    let clock = whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, minutes, left) : String(format: "%d:%02d", minutes, left)
    return clock + tail
  }
}

extension Tool.Turn {
  var title: String {
    switch self {
    case .right: return "Rotate right"
    case .half: return "Rotate upside down"
    case .left: return "Rotate left"
    case .mirror: return "Mirror"
    case .flip: return "Flip"
    }
  }
}

// MARK: - In a chain

extension [Operation] {
  var tools: [Tool] { compactMap { if case .tool(let tool) = $0 { return tool } else { return nil } } }

  /// The chain with a tool in it, instead of the one of its kind.
  func adding(_ tool: Tool) -> [Operation] {
    filter { if case .tool(let other) = $0 { return other.slot != tool.slot } else { return true } } + [.tool(tool)]
  }

  /// Some tools make something else of a file than what it was: a cut-out needs
  /// somewhere to be see-through, and a frame of a film is a picture.
  /// - Parameter overriding: whether a format already chosen gives way.
  func settlingFormat(overriding: Bool = false) -> [Operation] {
    let wanted: (type: UTType, takes: (UTType) -> Bool)
    if tools.contains(.removeBackground) {
      wanted = (.png, { !FormatCatalog.isSolid($0) })
    } else if tools.contains(where: { $0.kind == .frames }) {
      wanted = (.jpeg, FormatCatalog.isWritableImage)
    } else {
      return self
    }
    let formats = compactMap { if case .convertFormat(let to) = $0 { return to } else { return nil } }
    guard !formats.isEmpty else { return [.convertFormat(to: wanted.type)] + self }
    guard overriding else { return self }
    return map { operation in
      guard case .convertFormat(let to) = operation, !wanted.takes(to) else { return operation }
      return .convertFormat(to: wanted.type)
    }
  }
}

extension FormatCatalog {
  /// Pictures with no way to be see-through.
  static func isSolid(_ type: UTType) -> Bool {
    [UTType.jpeg, .bmp].contains { type.conforms(to: $0) }
  }
}
