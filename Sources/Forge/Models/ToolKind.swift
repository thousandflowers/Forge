import Foundation
import UniformTypeIdentifiers

// MARK: - What they are for

extension Tool {
  /// The kinds of tool, for a library and for saying which step replaces which.
  enum Kind: String, CaseIterable, Sendable {
    case trim, divide, speed, loop, reverse, mute, normalize, frames
    case crop, turn, removeBackground
    case pages, dropPages
    case lighter
    case sync, adjust, border, mark, digest, wave
    case enhance, upscale, scan, gray, blurBackground, round, tile, layers
    case slowMotion, still, rate, lines
    case voice, mono, fade, pitch, noSilence
    case lock, unlock, numbers, sheet, dpi, pictures, tables
    case tidy

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
      case .lighter: return "Make lighter"
      case .sync: return "Move the sound"
      case .adjust: return "Adjust"
      case .border: return "Border"
      case .mark: return "Watermark"
      case .digest: return "Fingerprint"
      case .wave: return "Draw the sound"
      case .enhance: return "Enhance"
      case .upscale: return "Enlarge"
      case .scan: return "Scan"
      case .gray: return "Black and white"
      case .blurBackground: return "Blur the background"
      case .round: return "Round the corners"
      case .tile: return "Cut into tiles"
      case .layers: return "Layers"
      case .slowMotion: return "Slow motion"
      case .still: return "One frame"
      case .rate: return "Frame rate"
      case .lines: return "Resolution"
      case .voice: return "Keep the voice"
      case .mono: return "Mono"
      case .fade: return "Fade in and out"
      case .pitch: return "Pitch"
      case .noSilence: return "Skip the silences"
      case .lock: return "Add a password"
      case .unlock: return "Remove the password"
      case .numbers: return "Number the pages"
      case .sheet: return "Pages per sheet"
      case .dpi: return "Resolution of the pages"
      case .pictures: return "Take out the pictures"
      case .tables: return "Take out the tables"
      case .tidy: return "Tidy the code"
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
      case .dropPages: return "minus.rectangle.portrait"
      case .lighter: return "leaf"
      case .sync: return "waveform.path"
      case .adjust: return "slider.horizontal.3"
      case .border: return "square.dashed"
      case .mark: return "signature"
      case .digest: return "number"
      case .wave: return "waveform"
      case .enhance: return "wand.and.stars"
      case .upscale: return "arrow.up.left.and.arrow.down.right"
      case .scan: return "doc.viewfinder"
      case .gray: return "circle.lefthalf.filled"
      case .blurBackground: return "person.and.background.dotted"
      case .round: return "app"
      case .tile: return "square.grid.3x3"
      case .layers: return "square.3.layers.3d"
      case .slowMotion: return "tortoise"
      case .still: return "photo"
      case .rate: return "film"
      case .lines: return "rectangle.arrowtriangle.2.inward"
      case .voice: return "person.wave.2"
      case .mono: return "speaker.wave.1"
      case .fade: return "waveform.path.ecg"
      case .pitch: return "tuningfork"
      case .noSilence: return "forward.end"
      case .lock: return "lock"
      case .unlock: return "lock.open"
      case .numbers: return "textformat.123"
      case .sheet: return "rectangle.split.2x2"
      case .dpi: return "circle.grid.3x3"
      case .pictures: return "photo.on.rectangle"
      case .tables: return "tablecells"
      case .tidy: return "curlybraces"
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
      case .lighter: return "Less weight, looking the same"
      case .sync: return "Later or earlier, to match the picture"
      case .adjust: return "Brightness, contrast, saturation or blur"
      case .border: return "A frame round it, in white or black"
      case .mark: return "Words in the corner"
      case .digest: return "SHA-256 or Base64, as text"
      case .wave: return "A film of its waveform, to post where only films go"
      case .enhance: return "Better light and colors, chosen by macOS"
      case .upscale: return "Two, three or four times as large"
      case .scan: return "The sheet in the photo, straightened and lit"
      case .gray: return "Without its colors"
      case .blurBackground: return "What the picture is of stays sharp"
      case .round: return "See-through at the corners"
      case .tile: return "So many across and so many down"
      case .layers: return "A picture for each layer of a Photoshop file"
      case .slowMotion: return "Slower, with the frames in between made up"
      case .still: return "The picture at that moment"
      case .rate: return "So many frames a second"
      case .lines: return "No larger than 1080p, 720p and so on"
      case .voice: return "Without the noise behind it"
      case .mono: return "One channel"
      case .fade: return "The sound comes up at the start and goes down at the end"
      case .pitch: return "Higher or lower, and as long as before"
      case .noSilence: return "The long ones are cut out"
      case .lock: return "Asked for every time, and never written down"
      case .unlock: return "Asked for every time, and never written down"
      case .numbers: return "At the foot of every page"
      case .sheet: return "Two, four or more on each sheet"
      case .dpi: return "How finely they are drawn as pictures"
      case .pictures: return "As they were put in the PDF"
      case .tables: return "Into a spreadsheet"
      case .tidy: return "JSON, XML, CSS and JavaScript, short or in order"
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
      case .lighter: return .lighter
      case .sync: return .sync(250)
      case .adjust: return .adjust(.brightness, 10)
      case .border: return .border(40)
      case .mark: return .mark("©")
      case .digest: return .digest(.sha256)
      case .wave: return .wave
      case .enhance: return .enhance
      case .upscale: return .upscale(2)
      case .scan: return .scan
      case .gray: return .gray
      case .blurBackground: return .blurBackground
      case .round: return .round(40)
      case .tile: return .tile(3, 3)
      case .layers: return .layers
      case .slowMotion: return .slowMotion(2)
      case .still: return .still(at: 10)
      case .rate: return .rate(30)
      case .lines: return .lines(1080)
      case .voice: return .voice
      case .mono: return .mono
      case .fade: return .fade(2)
      case .pitch: return .pitch(2)
      case .noSilence: return .noSilence
      case .lock: return .lock
      case .unlock: return .unlock
      case .numbers: return .numbers
      case .sheet: return .sheet(2)
      case .dpi: return .dpi(300)
      case .pictures: return .pictures
      case .tables: return .tables
      case .tidy: return .tidy(.pretty)
      }
    }

    /// What it can be done to. A PDF and no other document: the rest have no
    /// pages until something is made of them.
    var kinds: Set<ConvertKind> {
      switch self {
      case .trim, .divide, .speed, .loop, .reverse, .normalize: return [.audio, .video]
      case .mute, .frames: return [.video]
      case .crop, .turn: return [.image, .video, .document]
      case .removeBackground: return [.image, .video]
      case .pages, .dropPages: return [.document]
      case .lighter: return [.image, .video, .audio, .document]
      case .sync: return [.video]
      case .adjust, .border, .mark: return [.image]
      case .digest: return Set(ConvertKind.allCases)
      case .wave: return [.audio]
      case .enhance: return [.image]
      case .upscale: return [.image]
      case .scan: return [.image]
      case .gray: return [.image, .video]
      case .blurBackground: return [.image]
      case .round: return [.image]
      case .tile: return [.image]
      case .layers: return [.image]
      case .slowMotion: return [.video]
      case .still: return [.video]
      case .rate: return [.video]
      case .lines: return [.video]
      case .voice: return [.audio, .video]
      case .mono: return [.audio, .video]
      case .fade: return [.audio, .video]
      case .pitch: return [.audio, .video]
      case .noSilence: return [.audio, .video]
      case .lock: return [.document]
      case .unlock: return [.document]
      case .numbers: return [.document]
      case .sheet: return [.document]
      case .dpi: return [.document]
      case .pictures: return [.document]
      case .tables: return [.document, .image]
      case .tidy: return [.data, .document]
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
    case .lighter: return .lighter
    case .sync: return .sync
    case .adjust: return .adjust
    case .border: return .border
    case .mark: return .mark
    case .digest: return .digest
    case .wave: return .wave
    case .enhance: return .enhance
    case .upscale: return .upscale
    case .scan: return .scan
    case .gray: return .gray
    case .blurBackground: return .blurBackground
    case .round: return .round
    case .tile: return .tile
    case .layers: return .layers
    case .slowMotion: return .slowMotion
    case .still: return .still
    case .rate: return .rate
    case .lines: return .lines
    case .voice: return .voice
    case .mono: return .mono
    case .fade: return .fade
    case .pitch: return .pitch
    case .noSilence: return .noSilence
    case .lock: return .lock
    case .unlock: return .unlock
    case .numbers: return .numbers
    case .sheet: return .sheet
    case .dpi: return .dpi
    case .pictures: return .pictures
    case .tables: return .tables
    case .tidy: return .tidy
    }
  }

  /// What people reach for, by what is in their hand.
  static func handy(for kind: ConvertKind) -> [Tool] {
    let words: [ConvertKind: [String]] = [
      .image: ["nobg", "crop1x1", "rotate90"],
      .video: ["mute", "speed2x", "normalize", "rotate90", "crop1x1", "crop9x16"],
      .audio: ["normalize", "speed1.5x", "split2"],
      .document: ["splitpages", "rotate90", "crop1x1"],
    ]
    return (words[kind] ?? []).compactMap(Tool.init(word:))
  }

  /// What it makes is about the file, and not the file.
  var leavesTheOriginal: Bool { [.digest, .frames, .wave, .still, .layers, .pictures, .tables].contains(kind) }

  /// What it makes of a film is pictures.
  var takesAFrame: Bool { kind == .frames || kind == .still }

  /// What it makes is a set, and goes in a folder.
  var makesASet: Bool { [.layers, .pictures].contains(kind) }

  var asksAPassword: Bool { self == .lock || self == .unlock }

  /// As it would be read back: a preset keeps the word, and a word nothing reads
  /// takes the preset with it.
  var readable: Tool? { Tool(word: word) }

  /// What another step of takes its place: a turn one way is instead of a turn
  /// another way, and not instead of a mirror.
  var slot: String {
    if case .turn(let turn) = self, turn == .mirror || turn == .flip { return turn.rawValue }
    // And brighter is not instead of more contrast.
    if case .adjust(let what, _) = self { return what.rawValue }
    return kind.rawValue
  }

  func suits(_ type: UTType) -> Bool {
    if case .divide(let division) = self {
      if case .pages = division { return type.conforms(to: .pdf) }
      return ConvertKind(fileType: type).map([.audio, .video].contains) ?? false
    }
    if case .digest = self { return true }
    if case .tidy = self { return Tidier.language(of: type) != nil }
    if case .layers = self { return PSDLayers.reads(type) }
    if kind == .tables, type.conforms(to: .pdf) { return true }
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
    case .crop(.cell(let column, let row, _, _)): return "Tile \(column), \(row)"
    case .pages(let list): return "Pages \(list.text)"
    case .dropPages(let list): return "Without pages \(list.text)"
    case .frames(let seconds): return "A frame every \(Self.text(seconds)) s"
    case .sync(let thousandths): return "Sound \(abs(thousandths)) ms \(thousandths < 0 ? "earlier" : "later")"
    case .adjust(let what, let much): return "\(what.rawValue.capitalized) \(what == .blur || much < 0 ? "" : "+")\(much)"
    case .border(let width, let isBlack): return "\(isBlack ? "Black" : "White") border, \(width) px"
    case .mark(let text): return "Watermark “\(text)”"
    case .digest(let digest): return digest == .sha256 ? "SHA-256" : "Base64"
    case .upscale(let times): return "Enlarge \(times)×"
    case .round(let radius): return "Round the corners, \(radius) px"
    case .tile(let across, let down): return "Cut into \(across) × \(down)"
    case .slowMotion(let times): return "Slow motion \(times)×"
    case .still(let second): return "The frame at \(Self.clock(second))"
    case .rate(let frames): return "\(frames) frames a second"
    case .lines(let lines): return lines == 2160 ? "4K at most" : "\(lines)p at most"
    case .fade(let seconds): return "Fade in and out, \(Self.text(seconds)) s"
    case .pitch(let steps): return "Pitch \(steps > 0 ? "+" : "")\(steps)"
    case .sheet(let count): return "\(count) pages a sheet"
    case .dpi(let dots): return "\(dots) dpi"
    case .tidy(let tidying): return tidying == .min ? "Written short" : "Written out"
    case .mute, .normalize, .reverse, .removeBackground, .lighter, .wave, .enhance, .scan, .gray, .blurBackground, .layers,
         .voice, .mono, .noSilence, .lock, .unlock, .numbers, .pictures, .tables:
      return kind.title
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
