import Foundation
import AVFoundation
import AudioToolbox
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Single source of truth for the formats Forge can actually handle.
///
/// Every list here is derived from the running system rather than written by
/// hand: ImageIO reports which image types it can decode and encode, and
/// AVFoundation reports which media types it can open. Hardcoded UTI strings
/// were the cause of whole formats being silently unsupported (a made-up
/// `"public.wav"` resolves to nil, so every WAV was rejected) and of claiming
/// formats the host cannot write (WebP is readable but not writable).
enum FormatCatalog {
  // MARK: - Images

  /// Image types ImageIO can decode on this machine.
  static let readableImageTypes: Set<UTType> = Self.types(CGImageSourceCopyTypeIdentifiers())

  /// Image types ImageIO can encode on this machine.
  ///
  /// Notably excludes WebP: macOS reads it but ships no encoder for it.
  static let writableImageTypes: Set<UTType> = Self.types(CGImageDestinationCopyTypeIdentifiers())

  // MARK: - Audio and video

  /// Everything AVFoundation can open, audio and video alike. Which of the two
  /// a given file is depends on the tracks it actually contains, so the split
  /// is made per file rather than guessed from the extension.
  static let readableMediaTypes: Set<UTType> = Set(
    AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }
  )

  /// Movie containers AVFoundation can export to. The export itself validates
  /// the pairing against the specific asset and reports a real error, so this
  /// is a starting set, not a promise.
  static let writableVideoTypes: Set<UTType> = Self.videoContainers()

  /// Audio containers Forge can write, each paired with the codec it carries.
  ///
  /// No system API exposes container/codec compatibility, so the pairings are
  /// declared here — but each one is verified against the running system before
  /// it is offered, so a host that cannot encode FLAC simply never lists it.
  static let writableAudioTypes: [UTType: AudioFormatID] = Self.probeAudioTypes()

  // MARK: - Queries

  static func isReadableImage(_ type: UTType) -> Bool {
    if readableImageTypes.contains(type) { return true }
    return readableImageTypes.contains { type.conforms(to: $0) }
  }

  static func isWritableImage(_ type: UTType) -> Bool {
    if writableImageTypes.contains(type) { return true }
    return writableImageTypes.contains { type.conforms(to: $0) }
  }

  static func isReadableMedia(_ type: UTType) -> Bool {
    if readableMediaTypes.contains(type) { return true }
    return readableMediaTypes.contains { type.conforms(to: $0) }
  }

  /// The codec to encode with when writing audio to `type`, if this host can.
  static func audioFormatID(for type: UTType) -> AudioFormatID? {
    if let exact = writableAudioTypes[type] { return exact }
    return writableAudioTypes.first { type.conforms(to: $0.key) }?.value
  }

  static func isWritableVideo(_ type: UTType) -> Bool {
    if writableVideoTypes.contains(type) { return true }
    return writableVideoTypes.contains { type.conforms(to: $0) }
  }

  /// Big-endian samples are the AIFF convention; every other PCM container
  /// here is little-endian.
  static func usesBigEndianPCM(_ type: UTType) -> Bool {
    type.conforms(to: .aiff)
  }

  // MARK: - Probing

  private static func types(_ identifiers: CFArray?) -> Set<UTType> {
    guard let ids = identifiers as? [String] else { return [] }
    return Set(ids.compactMap { UTType($0) })
  }

  /// Candidate audio containers, filtered down to the ones this host can
  /// really open for writing.
  private static func probeAudioTypes() -> [UTType: AudioFormatID] {
    let candidates: [(UTType?, AudioFormatID)] = [
      (.wav, kAudioFormatLinearPCM),
      (.aiff, kAudioFormatLinearPCM),
      (UTType("com.apple.coreaudio-format"), kAudioFormatLinearPCM),
      (UTType("com.apple.m4a-audio"), kAudioFormatMPEG4AAC),
      (UTType("org.xiph.flac"), kAudioFormatFLAC),
    ]

    return candidates.reduce(into: [:]) { result, candidate in
      guard let type = candidate.0,
            canEncodeAudio(type: type, formatID: candidate.1) else { return }
      result[type] = candidate.1
    }
  }

  /// Try to open a throwaway file for writing: the cheapest honest answer to
  /// "can this host encode that".
  private static func canEncodeAudio(type: UTType, formatID: AudioFormatID) -> Bool {
    guard let ext = type.preferredFilenameExtension else { return false }
    let probe = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-probe-\(UUID().uuidString).\(ext)")
    defer { try? FileManager.default.removeItem(at: probe) }

    var settings: [String: Any] = [
      AVFormatIDKey: formatID,
      AVSampleRateKey: 44_100.0,
      AVNumberOfChannelsKey: 2,
    ]
    if formatID == kAudioFormatLinearPCM {
      settings[AVLinearPCMBitDepthKey] = 16
      settings[AVLinearPCMIsFloatKey] = false
      settings[AVLinearPCMIsBigEndianKey] = usesBigEndianPCM(type)
    }
    return (try? AVAudioFile(forWriting: probe, settings: settings)) != nil
  }

  /// The movie containers AVFoundation exports to.
  private static func videoContainers() -> Set<UTType> {
    Set([AVFileType.mp4, .mov, .m4v].compactMap { UTType($0.rawValue) })
  }
}
