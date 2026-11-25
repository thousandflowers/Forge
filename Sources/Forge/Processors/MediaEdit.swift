import AVFoundation
import Foundation

/// What a chain does to a recording's time, sound and shape, in one place: the
/// system's path reads it one way and ffmpeg's another.
///
/// Time is said of the original: the part is taken first, and what is left is
/// turned round, sped up and repeated.
struct MediaEdit {
  var part: Span?
  var isFast = false
  var speed = 1.0
  var loops = 1
  var isReversed = false
  var isMuted = false
  var isEvened = false
  /// Seconds the sound comes after the picture.
  var delay = 0.0
  /// Everything that changes the picture's shape, in the order it was asked.
  private(set) var shapes: [Shape] = []
  var isGray = false
  /// Whoever is in it, without what is behind them.
  var isCutOut = false
  /// How many frames there are to be for every one.
  var slow = 1
  /// Frames a second.
  var rate: Double?
  var keepsVoice = false
  var isMono = false
  /// Seconds the sound takes to come up and to go.
  var fade = 0.0
  /// Semitones.
  var pitch = 0
  var dropsSilence = false

  enum Shape {
    case turn(Tool.Turn)
    case crop(Tool.Crop)
    case size(width: Int?, height: Int?, mode: ResizeFitMode)
    /// The short side, and never larger than it is.
    case lines(Int)
  }

  init(_ operations: [Operation]) {
    for operation in operations {
      switch operation {
      case .resize(let width, let height, let mode) where width != nil || height != nil:
        shapes.append(.size(width: width, height: height, mode: mode))
      case .tool(.trim(let span, let fast)): part = span; isFast = fast
      case .tool(.speed(let times)): speed = times
      case .tool(.loop(let times)): loops = times
      case .tool(.reverse): isReversed = true
      case .tool(.mute): isMuted = true
      case .tool(.normalize): isEvened = true
      case .tool(.sync(let thousandths)): delay = Double(thousandths) / 1000
      case .tool(.turn(let turn)): shapes.append(.turn(turn))
      case .tool(.crop(let crop)): shapes.append(.crop(crop))
      case .tool(.lines(let lines)): shapes.append(.lines(lines))
      case .tool(.gray): isGray = true
      case .tool(.removeBackground): isCutOut = true
      case .tool(.slowMotion(let times)): slow = times
      case .tool(.rate(let frames)): rate = Double(frames)
      case .tool(.voice): keepsVoice = true
      case .tool(.mono): isMono = true
      case .tool(.fade(let seconds)): fade = seconds
      case .tool(.pitch(let steps)): pitch = steps
      case .tool(.noSilence): dropsSilence = true
      default: break
      }
    }
  }

  /// Whether the recording itself is another: not only its shape.
  var changesTime: Bool { part != nil || pace != 1 || loops > 1 || isReversed || dropsSilence }
  var rewritesSound: Bool { isReversed || isEvened || keepsVoice || isMono || fade > 0 || pitch != 0 }
  var changesSound: Bool { changesTime || rewritesSound }
  /// Whether its pictures are drawn again, one by one.
  var repaints: Bool { isGray || isCutOut }
  /// Their times are the film's, and nothing puts them right.
  var keepsSubtitles: Bool { pace == 1 && !isReversed }
  var isNothing: Bool { !changesTime && !isMuted && !rewritesSound && !repaints && delay == 0 }
  /// How fast it goes by, all told.
  var pace: Double { speed / Double(slow) }

  // MARK: - The system's way

  /// How long what is left comes out, in seconds.
  func length(of whole: Double) -> Double {
    guard let kept = (part ?? Span()).clamped(to: whole) else { return 0 }
    return (kept.upperBound - kept.lowerBound) / pace * Double(loops)
  }

  /// The recording with the part taken, the rest left out, and the time
  /// changed. Nothing is encoded: it is the same samples, played otherwise.
  func applied(to asset: AVURLAsset) async throws -> AVMutableComposition {
    let timescale: CMTimeScale = 60_000
    let whole = try await asset.load(.duration).seconds
    guard let kept = (part ?? Span()).clamped(to: whole) else {
      throw ProcessingError.conversionFailed(
        reason: "\(asset.url.lastPathComponent) is \(Tool.clock(whole)) long: there is nothing in the part asked for."
      )
    }
    let heard = dropsSilence ? try await Silence.loudParts(of: asset, within: kept) : [kept]
    let ranges = heard.map { part in
      CMTimeRange(
        start: CMTime(seconds: part.lowerBound, preferredTimescale: timescale),
        end: CMTime(seconds: part.upperBound, preferredTimescale: timescale)
      )
    }
    let once = ranges.reduce(CMTime.zero) { $0 + $1.duration }
    let composition = AVMutableComposition()
    // One at a time: inserted as a whole, an asset leaves its pictures lying
    // on their side and takes along tracks that play nothing.
    let kinds: [AVMediaType] = [.video] + (isMuted ? [] : [.audio]) + (pace == 1 ? [.subtitle, .closedCaption] : [])
    for kind in kinds {
      for track in try await asset.loadTracks(withMediaType: kind) {
        guard let copy = composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
        if kind == .video { copy.preferredTransform = try await track.load(.preferredTransform) }
        copy.languageCode = try await track.load(.languageCode)
        // A track may begin after the film does, or end before it.
        // Sound that comes later is, at any moment, what was heard before it.
        let late = kind == .audio ? CMTime(seconds: delay, preferredTimescale: timescale) : .zero
        let whole = try await track.load(.timeRange)
        for turn in 0..<loops {
          var start = CMTimeMultiply(once, multiplier: Int32(turn))
          for range in ranges {
            let wanted = CMTimeRange(start: range.start - late, duration: range.duration)
            let there = whole.intersection(wanted)
            if there.duration > .zero { try copy.insertTimeRange(there, of: track, at: start + (there.start - wanted.start)) }
            start = start + range.duration
          }
        }
      }
    }
    if pace != 1 {
      let all = CMTimeRange(start: .zero, duration: CMTimeMultiply(once, multiplier: Int32(loops)))
      composition.scaleTimeRange(all, toDuration: CMTimeMultiplyByFloat64(all.duration, multiplier: 1 / pace))
    }
    return composition
  }

  /// The picture's frame and how it lands in it, or nil where nothing changes
  /// its shape. Each step is worked out on what the one before left.
  func placement(of stored: CGSize, turned: CGAffineTransform) throws -> (size: CGSize, transform: CGAffineTransform)? {
    guard !shapes.isEmpty else { return nil }
    let shown = CGRect(origin: .zero, size: stored).applying(turned)
    var size = CGSize(width: abs(shown.width), height: abs(shown.height))
    var transform = turned.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
    for shape in shapes {
      switch shape {
      case .turn(let turn):
        let step = turn.transform(of: size)
        transform = transform.concatenating(step.transform)
        size = step.size
      case .crop(let crop):
        let box = try crop.box(in: size)
        transform = transform.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
        size = box.size
      case .size(let width, let height, let mode):
        guard let render = MediaProcessor.renderSize(natural: size, width: width, height: height, mode: mode) else { continue }
        transform = transform.concatenating(MediaProcessor.placement(of: size, in: render, mode: mode))
        size = render
      case .lines(let lines):
        let short = min(size.width, size.height)
        guard short > CGFloat(lines), let render = MediaProcessor.renderSize(
          natural: size, width: size.width <= size.height ? lines : nil, height: size.width <= size.height ? nil : lines, mode: .proportional
        ) else { continue }
        transform = transform.concatenating(MediaProcessor.placement(of: size, in: render, mode: .proportional))
        size = render
      }
    }
    // Encoders want even sides. Cut, never stretched.
    let even = CGSize(width: max(2, floor(size.width / 2) * 2), height: max(2, floor(size.height / 2) * 2))
    return (even, transform)
  }

  // MARK: - ffmpeg's way

  /// Before the input, so that the filters see only the part.
  var ffmpegInput: [String] {
    var arguments: [String] = []
    if loops > 1 { arguments += ["-stream_loop", "\(loops - 1)"] }
    if let from = part?.from, from > 0 { arguments += ["-ss", Tool.text(from)] }
    if let to = part?.to { arguments += ["-t", Tool.text(to - (part?.from ?? 0))] }
    return arguments
  }

  /// What ffmpeg is not asked to do: repeating a part repeats the whole.
  var ffmpegRefusal: String? {
    if loops > 1 && part != nil { return "A part of it can be repeated in MP4, MOV and M4A. Keep the part first, then repeat it." }
    guard let step = mac else { return nil }
    return "“\(step.title)” is done by macOS, in MP4, MOV and M4A. Convert it to one of those first."
  }

  /// What only macOS does, of what is asked.
  var mac: Tool.Kind? {
    if keepsVoice { return .voice }
    if dropsSilence { return .noSilence }
    if slow > 1 { return .slowMotion }
    return isCutOut ? .removeBackground : nil
  }

  var ffmpegPicture: [String] {
    var filters: [String] = []
    for shape in shapes {
      switch shape {
      case .turn(let turn): filters.append(turn.ffmpeg)
      case .crop(let crop): filters.append(crop.ffmpeg)
      case .size(let width, let height, let mode): filters.append(ExternalBridge.scaling(width: width, height: height, mode: mode))
      case .lines(let lines): filters.append("scale='if(gt(iw,ih),-2,min(iw,\(lines)))':'if(gt(iw,ih),min(ih,\(lines)),-2)'")
      }
    }
    if isGray { filters.append("hue=s=0") }
    if isReversed { filters.append("reverse") }
    if speed != 1 { filters.append("setpts=PTS/\(Tool.text(speed))") }
    if let rate { filters.append("fps=\(Tool.text(rate))") }
    return filters
  }

  var ffmpegSound: [String] {
    var filters: [String] = []
    if delay > 0 { filters.append("adelay=\(Int(delay * 1000)):all=1") }
    if delay < 0 { filters.append("atrim=start=\(Tool.text(-delay)),asetpts=PTS-STARTPTS") }
    if isReversed { filters.append("areverse") }
    // It takes half to a hundred times; less is half again.
    var left = speed
    while left < 0.5 { filters.append("atempo=0.5"); left /= 0.5 }
    if left != 1 { filters.append("atempo=\(Tool.text(left))") }
    if pitch != 0 {
      let times = pow(2, Double(pitch) / 12)
      filters.append("aresample=48000,asetrate=\(Int((48_000 * times).rounded())),aresample=48000")
      // Within half and double, which two octaves are not.
      let each = times > 2 || times < 0.5 ? 2 : 1
      filters += Array(repeating: "atempo=\(Tool.text(pow(1 / times, 1 / Double(each))))", count: each)
    }
    if isMono { filters.append("aformat=channel_layouts=mono") }
    // The end is not known until it comes: it is the beginning, backwards.
    if fade > 0 {
      let up = "afade=t=in:d=\(Tool.text(fade))"
      filters.append("\(up),areverse,\(up),areverse")
    }
    if isEvened { filters.append("loudnorm=I=\(Int(Loudness.target)):TP=-1.5:LRA=11") }
    return filters
  }
}

extension Tool.Turn {
  /// What it does to a frame, y downwards, back at the corner.
  func transform(of size: CGSize) -> (transform: CGAffineTransform, size: CGSize) {
    switch self {
    case .right: return (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0), CGSize(width: size.height, height: size.width))
    case .left: return (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width), CGSize(width: size.height, height: size.width))
    case .half: return (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height), size)
    case .mirror: return (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0), size)
    case .flip: return (CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height), size)
    }
  }

  var ffmpeg: String {
    switch self {
    case .right: return "transpose=1"
    case .left: return "transpose=2"
    case .half: return "hflip,vflip"
    case .mirror: return "hflip"
    case .flip: return "vflip"
    }
  }
}

extension Tool.Crop {
  /// Where it is in a frame this big, from the top left.
  /// - Parameter focus: the point the shape is drawn round; the middle if nil.
  func box(in size: CGSize, around focus: CGPoint? = nil) throws -> CGRect {
    switch self {
    case .shape(let across, let down):
      let ratio = CGFloat(across) / CGFloat(down)
      let box = CGSize(width: min(size.width, size.height * ratio).rounded(.down), height: min(size.height, size.width / ratio).rounded(.down))
      let centre = focus ?? CGPoint(x: size.width / 2, y: size.height / 2)
      return CGRect(
        x: min(max(centre.x - box.width / 2, 0), size.width - box.width).rounded(.down),
        y: min(max(centre.y - box.height / 2, 0), size.height - box.height).rounded(.down),
        width: max(1, box.width), height: max(1, box.height)
      )
    case .box(let x, let y, let width, let height):
      let box = CGRect(x: x, y: y, width: width, height: height).intersection(CGRect(origin: .zero, size: size))
      guard !box.isNull, box.width >= 1, box.height >= 1 else {
        throw ProcessingError.conversionFailed(
          reason: "The crop is outside the picture, which is \(Int(size.width)) × \(Int(size.height))."
        )
      }
      return box
    case .cell(let column, let row, let across, let down):
      // Edges worked out from the whole, so that no row of pixels is lost
      // between one tile and the next.
      func edge(_ index: Int, of count: Int, _ side: CGFloat) -> CGFloat { (side * CGFloat(index) / CGFloat(count)).rounded() }
      let left = edge(column - 1, of: across, size.width), right = edge(column, of: across, size.width)
      let top = edge(row - 1, of: down, size.height), bottom = edge(row, of: down, size.height)
      guard right > left, bottom > top else {
        throw ProcessingError.conversionFailed(reason: "The picture is too small for \(across) × \(down) tiles.")
      }
      return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
  }

  var ffmpeg: String {
    switch self {
    case .shape(let across, let down):
      return "crop='min(iw,ih*\(across)/\(down))':'min(ih,iw*\(down)/\(across))'"
    case .box(let x, let y, let width, let height):
      return "crop='min(\(width),iw-\(x))':'min(\(height),ih-\(y))':\(x):\(y)"
    case .cell(let column, let row, let across, let down):
      return "crop=iw/\(across):ih/\(down):iw*\(column - 1)/\(across):ih*\(row - 1)/\(down)"
    }
  }
}
