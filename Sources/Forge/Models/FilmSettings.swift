import Foundation

/// Everything about how a film is written that somebody might want to say,
/// and nothing they have to: what is left alone is left to the encoder.
///
/// Each choice carries what it means to ffmpeg, so adding one is adding a case
/// and not another branch somewhere else.
struct FilmSettings: Codable, Hashable, Sendable {
  var encoder: Encoder = .h264
  var rate: Rate = .quality(75)
  var speed: Speed = .medium
  /// Frames a second; nil for as many as there are.
  var framesPerSecond: Int?
  var interlacing: Interlacing = .leave
  var noise: Noise = .leave
  var sharpness: Sharpness = .leave
  var smoothsBlocks = false
  var crop: Crop = .none
  var turn: Turn = .none
  var isGrey = false
  var isRec709 = false
  var sound: Sound = .automatic
  var soundKilobits: Int?
  var channels: Channels = .asIs
  var evensLoudness = false
  var keepsSubtitles = true
  /// Seconds in; nil for the beginning and the end.
  var from: Int?
  var to: Int?

  enum Encoder: String, Codable, CaseIterable, Sendable {
    case h264, hevc, av1, vp9, h264Apple, hevcApple

    var title: String {
      switch self {
      case .h264: return "H.264"
      case .hevc: return "HEVC"
      case .av1: return "AV1"
      case .vp9: return "VP9"
      case .h264Apple: return "H.264, fast"
      case .hevcApple: return "HEVC, fast"
      }
    }

    var name: String {
      switch self {
      case .h264: return "libx264"
      case .hevc: return "libx265"
      case .av1: return "libsvtav1"
      case .vp9: return "libvpx-vp9"
      case .h264Apple: return "h264_videotoolbox"
      case .hevcApple: return "hevc_videotoolbox"
      }
    }

    /// Tried, one by one, with the ffmpeg Homebrew installs.
    var containers: [String] {
      switch self {
      case .h264, .h264Apple: return ["mp4", "m4v", "mov", "mkv"]
      case .hevc, .hevcApple: return ["mp4", "mov", "mkv"]
      case .av1, .vp9: return ["mp4", "mkv", "webm"]
      }
    }

    var isApple: Bool { self == .h264Apple || self == .hevcApple }
    var isHEVC: Bool { self == .hevc || self == .hevcApple }

    /// Its own scale at 1 and at 100. Lower is better, but for Apple's.
    private var scale: (worst: Double, best: Double) {
      switch self {
      case .h264, .hevc: return (40, 16)
      case .av1: return (60, 18)
      case .vp9: return (55, 15)
      case .h264Apple, .hevcApple: return (1, 100)
      }
    }

    /// A quality of 1 to 100, on the scale this encoder counts in.
    func level(for quality: Int) -> Int {
      let share = Double(min(max(quality, 1), 100) - 1) / 99
      return Int((scale.worst + (scale.best - scale.worst) * share).rounded())
    }

    var scaleName: String { isApple ? "Q" : "RF" }
  }

  enum Rate: Codable, Hashable, Sendable {
    /// The same quality throughout, whatever it weighs.
    case quality(Int)
    /// About this many kilobits a second, whatever it looks like.
    case kilobits(Int)
  }

  enum Speed: String, Codable, CaseIterable, Sendable {
    case fast, medium, slow

    var title: String { rawValue.capitalized }
    var x26: String { rawValue }
    var av1: Int { self == .fast ? 10 : self == .medium ? 8 : 5 }
    var vp9: Int { self == .fast ? 5 : self == .medium ? 3 : 1 }
  }

  enum Interlacing: String, Codable, CaseIterable, Sendable {
    case leave, deinterlace, film

    var title: String {
      switch self {
      case .leave: return "Leave it"
      case .deinterlace: return "Deinterlace"
      case .film: return "Back to film (detelecine)"
      }
    }

    var filter: String? {
      switch self {
      case .leave: return nil
      // Only the frames that say they are interlaced.
      case .deinterlace: return "bwdif=mode=send_frame:deint=interlaced"
      case .film: return "fieldmatch,bwdif=mode=send_frame:deint=interlaced,decimate"
      }
    }
  }

  enum Noise: String, Codable, CaseIterable, Sendable {
    case leave, light, medium, strong, strongest

    var title: String { self == .leave ? "Leave it" : rawValue.capitalized }

    var filter: String? {
      switch self {
      case .leave: return nil
      case .light: return "hqdn3d=2:1.5:3:2.5"
      case .medium: return "hqdn3d=4:3:6:4.5"
      case .strong: return "hqdn3d=8:6:12:9"
      case .strongest: return "nlmeans=s=4"
      }
    }

    /// Said before it is run, because afterwards is an hour too late.
    var warning: String? {
      self == .strongest ? "Very slow: on an M2 Pro, eleven seconds for each second of 720p." : nil
    }
  }

  enum Sharpness: String, Codable, CaseIterable, Sendable {
    case leave, light, strong

    var title: String { self == .leave ? "Leave it" : rawValue.capitalized }

    var filter: String? {
      switch self {
      case .leave: return nil
      case .light: return "unsharp=5:5:0.6"
      case .strong: return "unsharp=5:5:1.2"
      }
    }
  }

  enum Crop: Codable, Hashable, Sendable {
    case none
    /// Whatever black there is all the way through.
    case blackBars
    case edges(top: Int, bottom: Int, left: Int, right: Int)
  }

  enum Turn: String, Codable, CaseIterable, Sendable {
    case none, right, left, half, mirror

    var title: String {
      switch self {
      case .none: return "Leave it"
      case .right: return "90° right"
      case .left: return "90° left"
      case .half: return "180°"
      case .mirror: return "Mirror"
      }
    }

    var filter: String? {
      switch self {
      case .none: return nil
      case .right: return "transpose=1"
      case .left: return "transpose=2"
      case .half: return "hflip,vflip"
      case .mirror: return "hflip"
      }
    }
  }

  enum Sound: String, Codable, CaseIterable, Sendable {
    case automatic, asItIs, aac, opus, mp3, flac, none

    var title: String {
      switch self {
      case .automatic: return "Automatic"
      case .asItIs: return "As it is"
      case .aac: return "AAC"
      case .opus: return "Opus"
      case .mp3: return "MP3"
      case .flac: return "FLAC"
      case .none: return "No sound"
      }
    }

    var name: String? {
      switch self {
      case .automatic, .none: return nil
      case .asItIs: return "copy"
      case .aac: return "aac"
      case .opus: return "libopus"
      case .mp3: return "libmp3lame"
      case .flac: return "flac"
      }
    }

    /// Nil where the container is not this choice's business.
    var containers: [String]? {
      switch self {
      case .automatic, .asItIs, .none: return nil
      case .aac: return ["mp4", "m4v", "mov", "mkv"]
      case .opus: return ["mp4", "mkv", "webm"]
      case .mp3: return ["mp4", "mov", "mkv"]
      case .flac: return ["mp4", "mkv"]
      }
    }

    /// A rate means nothing to a copy or to a lossless encoder.
    var takesRate: Bool { [.automatic, .aac, .opus, .mp3].contains(self) }
  }

  enum Channels: String, Codable, CaseIterable, Sendable {
    case asIs, stereo, mono

    var title: String { self == .asIs ? "As they are" : rawValue.capitalized }
    var count: Int? { self == .asIs ? nil : self == .stereo ? 2 : 1 }
  }

  // MARK: - In words

  var summary: String {
    var parts = [encoder.title]
    switch rate {
    case .quality(let quality): parts.append("\(encoder.scaleName) \(encoder.level(for: quality))")
    case .kilobits(let kilobits): parts.append("\(kilobits) kb/s")
    }
    if let framesPerSecond { parts.append("\(framesPerSecond) fps") }
    if interlacing != .leave { parts.append(interlacing == .film ? "detelecine" : "deinterlace") }
    if noise != .leave { parts.append("less noise") }
    if crop != .none { parts.append("crop") }
    if from != nil || to != nil { parts.append("part") }
    return parts.joined(separator: " · ")
  }

  // MARK: - In ffmpeg's

  /// Why these settings cannot go into that container, if they cannot.
  func refusal(for container: String) -> String? {
    func said(_ title: String, _ holders: [String]) -> String {
      "\(title) does not fit in \(container.uppercased()). \(holders.map { $0.uppercased() }.formatted(.list(type: .and).locale(Locale(identifier: "en")))) \(holders.count == 1 ? "holds" : "hold") it."
    }
    if !encoder.containers.contains(container) { return said(encoder.title, encoder.containers) }
    if let holders = sound.containers, !holders.contains(container) { return said(sound.title, holders) }
    if let from, let to, to <= from { return "The part to keep ends before it starts." }
    return nil
  }

  /// How much of a film this long is kept, in seconds.
  func kept(of length: Double) -> Double {
    max(0, min(to.map(Double.init) ?? length, length) - Double(from ?? 0))
  }

  /// Before the input: skipping there is quick, and to the frame.
  var inputArguments: [String] { from.map { ["-ss", "\($0)"] } ?? [] }

  /// - Parameters:
  ///   - picture: the filters the rest of the chain asked for, in its order.
  ///   - sound: the same, for what is heard.
  ///   - bars: what `.blackBars` came to.
  func outputArguments(for container: String, picture: [String] = [], sound: [String] = [], bars: String?) -> [String] {
    var arguments: [String] = []
    if let to { arguments += ["-t", "\(max(1, to - (from ?? 0)))"] }
    let filters = filters(picture: picture, bars: bars)
    if !filters.isEmpty { arguments += ["-vf", filters.joined(separator: ",")] }
    if let framesPerSecond { arguments += ["-r", "\(framesPerSecond)"] }
    arguments += videoArguments(for: container) + soundArguments(for: container, filters: sound)
    if ["mp4", "m4v", "mov"].contains(container) { arguments += ["-movflags", "+faststart"] }
    return arguments
  }

  /// Noise before shape, shape before sharpness: each is worse at its job
  /// after the next.
  private func filters(picture: [String], bars: String?) -> [String] {
    var filters = [interlacing.filter, noise.filter, smoothsBlocks ? "deblock" : nil].compactMap { $0 }
    switch crop {
    case .none: break
    case .blackBars: if let bars { filters.append(bars) }
    case .edges(let top, let bottom, let left, let right):
      let sides = [top, bottom, left, right].map { max(0, $0) }
      filters.append("crop=iw-\(sides[2] + sides[3]):ih-\(sides[0] + sides[1]):\(sides[2]):\(sides[0])")
    }
    filters += picture
    filters += [turn.filter, sharpness.filter, isGrey ? "hue=s=0" : nil, isRec709 ? "colorspace=all=bt709:iall=bt601-6-625" : nil].compactMap { $0 }
    // Encoders want even sides, and a crop or a turn may leave them odd.
    return filters.isEmpty ? [] : filters + ["crop=trunc(iw/2)*2:trunc(ih/2)*2"]
  }

  private func videoArguments(for container: String) -> [String] {
    var arguments = ["-c:v", encoder.name]
    switch encoder {
    case .h264, .hevc: arguments += ["-preset", speed.x26]
    case .av1: arguments += ["-preset", "\(speed.av1)"]
    case .vp9: arguments += ["-cpu-used", "\(speed.vp9)", "-row-mt", "1"]
    case .h264Apple, .hevcApple: break
    }
    switch rate {
    case .quality(let quality):
      arguments += [encoder.isApple ? "-q:v" : "-crf", "\(encoder.level(for: quality))"]
      // Without it VP9 takes the quality for a ceiling and keeps to 200 kb/s.
      if encoder == .vp9 { arguments += ["-b:v", "0"] }
    case .kilobits(let kilobits):
      arguments += ["-b:v", "\(max(50, kilobits))k"]
    }
    // Ten-bit and 4:4:4 H.264 are files nothing here plays.
    if encoder == .h264 || encoder == .h264Apple { arguments += ["-pix_fmt", "yuv420p"] }
    // The tag QuickTime looks for.
    if encoder.isHEVC, container != "mkv" { arguments += ["-tag:v", "hvc1"] }
    return arguments
  }

  private func soundArguments(for container: String, filters: [String]) -> [String] {
    guard sound != .none else { return ["-an"] }
    var arguments: [String] = []
    // A copy cannot be changed, and what has to change is encoded.
    let changes = evensLoudness || channels != .asIs || !filters.isEmpty
    if let name = sound.name, !(sound == .asItIs && changes) { arguments += ["-c:a", name] }
    if sound.takesRate, let soundKilobits { arguments += ["-b:a", "\(min(max(soundKilobits, 16), 640))k"] }
    if let count = channels.count { arguments += ["-ac", "\(count)"] }
    // Evened out it comes back at 192 kHz, which no player expects.
    let all = filters + (evensLoudness && !filters.contains { $0.hasPrefix("loudnorm") } ? ["loudnorm"] : [])
    if !all.isEmpty { arguments += ["-af", all.joined(separator: ",")] }
    if all.contains(where: { $0.hasPrefix("loudnorm") }) { arguments += ["-ar", "48000"] }
    return arguments
  }
}

extension FilmSettings {
  /// Every setting but the first two may be missing from a file written before
  /// it existed.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ key: CodingKeys, _ otherwise: T) throws -> T { try values.decodeIfPresent(T.self, forKey: key) ?? otherwise }
    let fresh = FilmSettings()
    encoder = try value(.encoder, fresh.encoder)
    rate = try value(.rate, fresh.rate)
    speed = try value(.speed, fresh.speed)
    framesPerSecond = try values.decodeIfPresent(Int.self, forKey: .framesPerSecond)
    interlacing = try value(.interlacing, fresh.interlacing)
    noise = try value(.noise, fresh.noise)
    sharpness = try value(.sharpness, fresh.sharpness)
    smoothsBlocks = try value(.smoothsBlocks, fresh.smoothsBlocks)
    crop = try value(.crop, fresh.crop)
    turn = try value(.turn, fresh.turn)
    isGrey = try value(.isGrey, fresh.isGrey)
    isRec709 = try value(.isRec709, fresh.isRec709)
    sound = try value(.sound, fresh.sound)
    soundKilobits = try values.decodeIfPresent(Int.self, forKey: .soundKilobits)
    channels = try value(.channels, fresh.channels)
    evensLoudness = try value(.evensLoudness, fresh.evensLoudness)
    keepsSubtitles = try value(.keepsSubtitles, fresh.keepsSubtitles)
    from = try values.decodeIfPresent(Int.self, forKey: .from)
    to = try values.decodeIfPresent(Int.self, forKey: .to)
  }
}

extension [Operation] {
  /// What was said about the film, if anything was.
  var film: FilmSettings? {
    compactMap { if case .film(let settings) = $0 { return settings } else { return nil } }.first
  }
}
