import AVFoundation
import AudioToolbox
import Foundation
import UniformTypeIdentifiers

/// A specific encoder, when the container alone does not say enough.
///
/// An `.m4a` can hold AAC or Apple Lossless, and a `.mov` can hold H.264,
/// HEVC or ProRes. Forge picked one and never mentioned the others, which is
/// why Apple Lossless and Opus were listed as impossible when they were only
/// unreachable.
enum Codec: String, Codable, Hashable, CaseIterable, Sendable {
  case h264
  case hevc
  case proRes422
  case proRes4444
  case aac
  case appleLossless
  case flac
  case linearPCM
  case opus

  var title: String {
    switch self {
    case .h264: return "H.264"
    case .hevc: return "HEVC"
    case .proRes422: return "ProRes 422"
    case .proRes4444: return "ProRes 4444"
    case .aac: return "AAC"
    case .appleLossless: return "Apple Lossless"
    case .flac: return "FLAC"
    case .linearPCM: return "Uncompressed"
    case .opus: return "Opus"
    }
  }

  var isVideo: Bool {
    switch self {
    case .h264, .hevc, .proRes422, .proRes4444: return true
    default: return false
    }
  }

  /// The Core Audio format, for the audio ones.
  var audioFormatID: AudioFormatID? {
    switch self {
    case .aac: return kAudioFormatMPEG4AAC
    case .appleLossless: return kAudioFormatAppleLossless
    case .flac: return kAudioFormatFLAC
    case .linearPCM: return kAudioFormatLinearPCM
    case .opus: return kAudioFormatOpus
    default: return nil
    }
  }

  /// The export preset that encodes with this, if the system offers it.
  ///
  /// H.264 has no preset of its own - it is what the sized presets produce -
  /// so it is chosen by dimensions rather than by name.
  var exportPreset: String? {
    switch self {
    case .hevc: return AVAssetExportPresetHEVCHighestQuality
    case .proRes422: return AVAssetExportPresetAppleProRes422LPCM
    case .proRes4444: return AVAssetExportPresetAppleProRes4444LPCM
    default: return nil
    }
  }

  /// Codecs this machine can actually encode with, asked of the system.
  static let available: [Codec] = allCases.filter { codec in
    if let preset = codec.exportPreset {
      return AVAssetExportSession.allExportPresets().contains(preset)
    }
    if let formatID = codec.audioFormatID {
      return FormatCatalog.canEncode(formatID)
    }
    // H.264 is always there: it is what every sized preset produces.
    return codec == .h264
  }

  static var videoCodecs: [Codec] { available.filter(\.isVideo) }
  static var audioCodecs: [Codec] { available.filter { !$0.isVideo } }
}
