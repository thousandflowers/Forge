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
  /// Everything that changes the picture's shape, in the order it was asked.
  private(set) var shapes: [Shape] = []

  enum Shape {
    case turn(Tool.Turn)
    case crop(Tool.Crop)
    case size(width: Int?, height: Int?, mode: ResizeFitMode)
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
      case .tool(.turn(let turn)): shapes.append(.turn(turn))
      case .tool(.crop(let crop)): shapes.append(.crop(crop))
      default: break
      }
    }
  }

  /// Whether the recording itself is another: not only its shape.
  var changesTime: Bool { part != nil || speed != 1 || loops > 1 || isReversed }
  var changesSound: Bool { changesTime || isEvened }
  /// Their times are the film's, and nothing puts them right.
  var keepsSubtitles: Bool { speed == 1 && !isReversed }
  var isNothing: Bool { !changesTime && !isMuted && !isEvened }

  // MARK: - The system's way

  /// How long what is left comes out, in seconds.
  func length(of whole: Double) -> Double {
    guard let kept = (part ?? Span()).clamped(to: whole) else { return 0 }
    return (kept.upperBound - kept.lowerBound) / speed * Double(loops)
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
    let range = CMTimeRange(
      start: CMTime(seconds: kept.lowerBound, preferredTimescale: timescale),
      end: CMTime(seconds: kept.upperBound, preferredTimescale: timescale)
    )
    let composition = AVMutableComposition()
    // One at a time: inserted as a whole, an asset leaves its pictures lying
    // on their side and takes along tracks that play nothing.
    let kinds: [AVMediaType] = [.video] + (isMuted ? [] : [.audio]) + (speed == 1 ? [.subtitle, .closedCaption] : [])
    for kind in kinds {
      for track in try await asset.loadTracks(withMediaType: kind) {
        guard let copy = composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
        if kind == .video { copy.preferredTransform = try await track.load(.preferredTransform) }
        copy.languageCode = try await track.load(.languageCode)
        // A track may begin after the film does, or end before it.
        let there = try await track.load(.timeRange).intersection(range)
        guard there.duration > .zero else { continue }
        for turn in 0..<loops {
          let at = CMTimeMultiply(range.duration, multiplier: Int32(turn)) + (there.start - range.start)
          try copy.insertTimeRange(there, of: track, at: at)
        }
      }
    }
    if speed != 1 {
      let all = CMTimeRange(start: .zero, duration: CMTimeMultiply(range.duration, multiplier: Int32(loops)))
      composition.scaleTimeRange(all, toDuration: CMTimeMultiplyByFloat64(all.duration, multiplier: 1 / speed))
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
    loops > 1 && part != nil ? "A part of it can be repeated in MP4, MOV and M4A. Keep the part first, then repeat it." : nil
  }

  var ffmpegPicture: [String] {
    var filters: [String] = []
    for shape in shapes {
      switch shape {
      case .turn(let turn): filters.append(turn.ffmpeg)
      case .crop(let crop): filters.append(crop.ffmpeg)
      case .size(let width, let height, let mode): filters.append(ExternalBridge.scaling(width: width, height: height, mode: mode))
      }
    }
    if isReversed { filters.append("reverse") }
    if speed != 1 { filters.append("setpts=PTS/\(Tool.text(speed))") }
    return filters
  }

  var ffmpegSound: [String] {
    var filters: [String] = []
    if isReversed { filters.append("areverse") }
    // It takes half to a hundred times; less is half again.
    var left = speed
    while left < 0.5 { filters.append("atempo=0.5"); left /= 0.5 }
    if left != 1 { filters.append("atempo=\(Tool.text(left))") }
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
    }
  }

  var ffmpeg: String {
    switch self {
    case .shape(let across, let down):
      return "crop='min(iw,ih*\(across)/\(down))':'min(ih,iw*\(down)/\(across))'"
    case .box(let x, let y, let width, let height):
      return "crop='min(\(width),iw-\(x))':'min(\(height),ih-\(y))':\(x):\(y)"
    }
  }
}
