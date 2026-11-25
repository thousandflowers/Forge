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
  /// As light as it goes without anybody noticing, and left alone if it is.
  case lighter
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
  /// Its sound this much later, or earlier, in thousandths of a second.
  case sync(Int)
  case adjust(Adjustment, Int)
  /// A frame round it, in pixels.
  case border(Int, isBlack: Bool = false)
  /// Words in the corner.
  case mark(String)
  case digest(Digest)
  /// A film of what the sound looks like.
  case wave

  // Pictures
  /// Better light and colour, as macOS sees fit.
  case enhance
  /// This many times as large.
  case upscale(Int)
  /// The sheet of paper in it, straightened and lit.
  case scan
  case gray
  case blurBackground
  /// Corners this round, in pixels.
  case round(Int)
  /// Cut up, so many across and so many down.
  case tile(Int, Int)
  /// What a Photoshop document is made of, one by one.
  case layers

  // Films
  /// This many times slower, with the frames in between made up.
  case slowMotion(Int)
  /// The picture at that second.
  case still(at: Double)
  /// Frames a second.
  case rate(Int)
  /// No more lines than this: 1080p.
  case lines(Int)

  // Sound
  /// What is said, without what is behind it.
  case voice
  case mono
  /// In and out, over this many seconds.
  case fade(Double)
  /// Higher or lower by this many semitones, and as long as before.
  case pitch(Int)
  case noSilence

  // PDFs
  /// With a password, which is asked for and never written down.
  case lock
  case unlock
  case numbers
  /// This many pages to a sheet.
  case sheet(Int)
  /// How finely a page is drawn when it becomes a picture.
  case dpi(Int)
  /// The pictures in it, as they were put there.
  case pictures
  /// The tables in it.
  case tables

  /// The same thing, written short or written out.
  case tidy(Tidying)

  enum Tidying: String, CaseIterable, Sendable { case min, pretty }

  enum Adjustment: String, CaseIterable, Sendable {
    case brightness, contrast, saturation, blur

    /// Percent either way, but for a blur, which is a radius.
    var range: ClosedRange<Int> { self == .blur ? 1...200 : -100...100 }
  }

  enum Digest: String, CaseIterable, Sendable { case sha256, base64 }

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
    /// One of so many across and so many down, counted from one.
    case cell(column: Int, row: Int, across: Int, down: Int)
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
      let from = run.from ?? 1
      let to = run.to ?? max(count, from)
      // From a page that is not there, on to the end, is no page.
      if run.to == nil, from > count { return [] }
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
  static let pitches = -24...24
  /// What divides a page into pages of its own shape, or of the same on its side.
  static let sheets = [2, 4, 6, 8, 9, 16]

  private static func count(_ word: String, _ shape: Regex<(Substring, Substring)>, in range: ClosedRange<Int>) -> Int? {
    word.wholeMatch(of: shape).flatMap { Int($0.1) }.flatMap { range.contains($0) ? $0 : nil }
  }

  /// Each takes the words it knows. In no particular order: no two take the
  /// same one.
  private static let readers: [@Sendable (String) -> Tool?] = [
    { ["mute": .mute, "normalize": .normalize, "reverse": .reverse, "lighter": .lighter, "wave": .wave, "nobg": .removeBackground, "splitchapters": .divide(.chapters), "splitpages": .divide(.pages(1))][$0] },
    { ["enhance": .enhance, "scan": .scan, "gray": .gray, "grey": .gray, "blurbg": .blurBackground, "layers": .layers][$0] },
    { ["voice": .voice, "mono": .mono, "nosilence": .noSilence, "4k": .lines(2160)][$0] },
    { ["askpassword": .lock, "unlock": .unlock, "numbers": .numbers, "images": .pictures, "tables": .tables][$0] },
    { Tidying(rawValue: $0).map(Tool.tidy) },
    { count($0, #/upscale(\d)x/#, in: 2...4).map(Tool.upscale) },
    { count($0, #/slowmo(\d)x/#, in: 2...8).map(Tool.slowMotion) },
    // Two digits: `image_round2` is a second go.
    { count($0, #/round(\d{2,4})/#, in: 10...9999).map(Tool.round) },
    { count($0, #/fps(\d{1,3})/#, in: 1...240).map(Tool.rate) },
    { count($0, #/(\d{3,4})p/#, in: 144...4320).map(Tool.lines) },
    { count($0, #/dpi(\d{2,4})/#, in: 36...1200).map(Tool.dpi) },
    { count($0, #/(\d{1,2})up/#, in: 2...16).flatMap { sheets.contains($0) ? .sheet($0) : nil } },
    { $0.wholeMatch(of: #/grid(\d{1,2})x(\d{1,2})/#).flatMap { match in
      guard let across = Int(match.1), let down = Int(match.2), across > 0, down > 0, across * down > 1 else { return nil }
      return .tile(across, down)
    } },
    { $0.wholeMatch(of: #/at(\d.*[hms]\d*)/#).flatMap { seconds($0.1) }.map { .still(at: $0) } },
    { $0.wholeMatch(of: #/fade(.+)s/#).flatMap { number($0.1) }.flatMap { $0 > 0 ? .fade($0) : nil } },
    { $0.wholeMatch(of: #/pitch([+-]\d{1,2})/#).flatMap { Int($0.1) }.flatMap { $0 != 0 && pitches.contains($0) ? .pitch($0) : nil } },
    { $0.wholeMatch(of: #/crop(\d{1,2}),(\d{1,2})of(\d{1,2})x(\d{1,2})/#).flatMap { match in
      guard let column = Int(match.1), let row = Int(match.2), let across = Int(match.3), let down = Int(match.4),
            (1...max(1, across)).contains(column), (1...max(1, down)).contains(row), across > 0, down > 0 else { return nil }
      return .crop(.cell(column: column, row: row, across: across, down: down))
    } },
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
    { $0.wholeMatch(of: #/sync([+-]?\d{1,5})ms/#).flatMap { Int($0.1) }.flatMap { $0 != 0 ? .sync($0) : nil } },
    { word in
      guard let match = word.wholeMatch(of: #/([a-z]+)([+-]?\d{1,3})/#), let what = Adjustment(rawValue: String(match.1)), let much = Int(match.2),
            // Signed, or it reads as one of several: `blur5` is a size and `contrast2` a second try.
            what == .blur || match.2.hasPrefix("+") || match.2.hasPrefix("-"), much != 0, what.range.contains(much) else { return nil }
      return .adjust(what, much)
    },
    { $0.wholeMatch(of: #/border(\d{1,4})(black)?/#).flatMap { match in
      Int(match.1).flatMap { $0 > 0 ? .border($0, isBlack: match.2 != nil) : nil }
    } },
    { Digest(rawValue: $0).map(Tool.digest) },
    { $0.wholeMatch(of: #/frames(.*[hms])/#).flatMap { seconds($0.1) }.flatMap { $0 > 0 ? .frames(every: $0) : nil } },
  ]

  init?(word: String) {
    // What is written on it is written as it was written.
    if let mark = word.wholeMatch(of: #/(?i)mark\((.{1,200})\)/#) {
      self = .mark(String(mark.1))
      return
    }
    let word = word.lowercased()
    guard let tool = Self.readers.lazy.compactMap({ $0(word) }).first else { return nil }
    self = tool
  }

  var word: String {
    switch self {
    case .mute: return "mute"
    case .normalize: return "normalize"
    case .reverse: return "reverse"
    case .lighter: return "lighter"
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
    case .crop(.cell(let column, let row, let across, let down)): return "crop\(column),\(row)of\(across)x\(down)"
    case .pages(let list): return "pages\(list.text)"
    case .dropPages(let list): return "nopages\(list.text)"
    case .frames(let seconds): return "frames\(Self.text(seconds))s"
    case .sync(let thousandths): return "sync\(thousandths)ms"
    case .adjust(let what, let much): return what.rawValue + (what == .blur || much < 0 ? "" : "+") + "\(much)"
    case .border(let width, let isBlack): return "border\(width)\(isBlack ? "black" : "")"
    case .mark(let text): return "mark(\(text))"
    case .digest(let digest): return digest.rawValue
    case .wave: return "wave"
    case .enhance: return "enhance"
    case .upscale(let times): return "upscale\(times)x"
    case .scan: return "scan"
    case .gray: return "gray"
    case .blurBackground: return "blurbg"
    case .round(let radius): return "round\(radius)"
    case .tile(let across, let down): return "grid\(across)x\(down)"
    case .layers: return "layers"
    case .slowMotion(let times): return "slowmo\(times)x"
    case .still(let second): return "at\(Self.text(second))s"
    case .rate(let frames): return "fps\(frames)"
    case .lines(let lines): return lines == 2160 ? "4k" : "\(lines)p"
    case .voice: return "voice"
    case .mono: return "mono"
    case .fade(let seconds): return "fade\(Self.text(seconds))s"
    case .pitch(let steps): return "pitch\(steps > 0 ? "+" : "")\(steps)"
    case .noSilence: return "nosilence"
    case .lock: return "askpassword"
    case .unlock: return "unlock"
    case .numbers: return "numbers"
    case .sheet(let count): return "\(count)up"
    case .dpi(let dots): return "dpi\(dots)"
    case .pictures: return "images"
    case .tables: return "tables"
    case .tidy(let tidying): return tidying.rawValue
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

// MARK: - In a chain

extension [Operation] {
  var tools: [Tool] { compactMap { if case .tool(let tool) = $0 { return tool } else { return nil } } }

  /// Those in its branches as well.
  var everyTool: [Tool] {
    flatMap { operation -> [Tool] in
      switch operation {
      case .tool(let tool): return [tool]
      case .when(_, let then, let otherwise): return then.everyTool + otherwise.everyTool
      case .split(let branches): return branches.flatMap { $0.actions.everyTool }
      default: return []
      }
    }
  }

  /// The chain with a tool in it, instead of the one of its kind.
  func adding(_ tool: Tool) -> [Operation] {
    filter { if case .tool(let other) = $0 { return other.slot != tool.slot } else { return true } } + [.tool(tool)]
  }

  /// Some tools make something else of a file than what it was: a cut-out needs
  /// somewhere to be see-through, and a frame of a film is a picture.
  /// - Parameter overriding: whether a format already chosen gives way.
  /// - Parameter source: what is being made something of, where that is known.
  func settlingFormat(overriding: Bool = false, of source: UTType? = nil) -> [Operation] {
    let wanted: (type: UTType, takes: (UTType) -> Bool)
    if tools.contains(.removeBackground), source.map({ ConvertKind(fileType: $0) == .video }) ?? false, !tools.contains(where: \.takesAFrame) {
      // The one container that has somewhere to put what shows through.
      wanted = (.quickTimeMovie, { $0 == .quickTimeMovie || FormatCatalog.isWritableImage($0) })
    } else if tools.contains(.removeBackground) || tools.contains(where: { $0.kind == .round }) {
      wanted = (.png, { !FormatCatalog.isSolid($0) })
    } else if tools.contains(where: \.takesAFrame) || tools.contains(where: { $0.kind == .dpi }) {
      wanted = (.jpeg, FormatCatalog.isWritableImage)
    } else if tools.contains(.layers) {
      wanted = (.png, FormatCatalog.isWritableImage)
    } else if tools.contains(.tables), let book = UTType(filenameExtension: "xlsx") {
      wanted = (book, { DataFormats.writes(Conversions.fileExtension(of: $0)) || ConvertKind(fileType: $0) == .data })
    } else if tools.contains(where: { $0.kind == .digest }) {
      wanted = (.plainText, { $0 == .plainText })
    } else if tools.contains(.wave) {
      wanted = (.mpeg4Movie, { $0 == .mpeg4Movie || $0 == .quickTimeMovie })
    } else {
      return self
    }
    let formats = compactMap { if case .convertFormat(let to) = $0 { return to } else { return nil } }
    guard !formats.isEmpty else { return [.convertFormat(to: wanted.type)] + self }
    // These two are never what was asked by another name: a film is not a
    // picture of itself, and a fingerprint is not a PDF.
    guard overriding || tools.contains(where: \.leavesTheOriginal) else { return self }
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
