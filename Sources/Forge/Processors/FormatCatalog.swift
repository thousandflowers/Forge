import Foundation
import AVFoundation
import AudioToolbox
import CoreGraphics
import ImageIO
import ModelIO
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

  /// Image types this machine can decode: what ImageIO reads, plus the vectors
  /// QuickLook draws.
  static let readableImageTypes: Set<UTType> = Self.types(CGImageSourceCopyTypeIdentifiers())
    .union(rasterizableVectorTypes)

  /// Vectors ImageIO cannot read and QuickLook can draw - on the machine this
  /// is running on, which is not every machine: the SVG generator answers on
  /// macOS 26 and hands back a square that is not the artwork on macOS 14.
  /// `VectorProcessor` settles it by drawing one and looking at it.
  static let rasterizableVectorTypes: Set<UTType> = VectorProcessor.canDraw ? [.svg] : []

  /// What to call a file of this type.
  ///
  /// `preferredFilenameExtension` is the system's answer and is sometimes not
  /// anybody else's: `public.toml` prefers `cfg`, and `public.yaml` prefers
  /// `yml`. When the type is named after one of the extensions it declares -
  /// `public.toml` after `toml` - that one is used instead, which leaves every
  /// other type exactly as it was.
  /// Where the name in the identifier is not the one anybody types. The rule
  /// below prefers the identifier's own word, which is right for TOML (the
  /// system prefers `cfg`) and wrong for Markdown, written as `.markdown`.
  private static let whatPeopleCallIt: [String: String] = ["net.daringfireball.markdown": "md"]

  /// The format an extension names, where Forge knows of one.
  static func type(named format: String) -> UTType? {
    if let type = UTType(filenameExtension: format), !type.isDynamic { return type }
    // Only then: the formats macOS has no type for and Forge writes anyway.
    // Taking this branch first would have handed back a dynamic type for
    // `txt`, which has a perfectly good one of its own.
    if Toml.handles(format) || Subtitles.writes(format),
       let text = UTType(filenameExtension: format, conformingTo: .plainText) {
      return text
    }
    // WOFF2 has no type on macOS either, and is a font rather than text.
    if ExternalBridge.Fonts.handles(format),
       let font = UTType(filenameExtension: format, conformingTo: .font) {
      return font
    }
    // What pandoc writes and macOS has no name for: rst, org, tex, ipynb.
    if ExternalBridge.pandocWritesFormat(format),
       let text = UTType(filenameExtension: format, conformingTo: .text) {
      return text
    }
    return nil
  }

  static func fileExtension(for type: UTType) -> String? {
    if let spoken = whatPeopleCallIt[type.identifier] { return spoken }
    let declared = type.tags[.filenameExtension] ?? []
    if let named = type.identifier.split(separator: ".").last.map(String.init),
       declared.contains(named) {
      return named
    }
    return type.preferredFilenameExtension
  }

  static func isRasterizableVector(_ type: UTType) -> Bool {
    rasterizableVectorTypes.contains { type == $0 || type.conforms(to: $0) }
  }

  /// Image types ImageIO can encode on this machine.
  ///
  /// Notably excludes WebP: macOS reads it but ships no encoder for it.
  static let writableImageTypes: Set<UTType> = Self.types(CGImageDestinationCopyTypeIdentifiers())
    .filter(Self.writesAPicture)

  /// ImageIO's list says what it has an encoder for, not what the encoder
  /// does: DDS is on it and no DDS is ever written. So each format is asked
  /// to write one small square picture, once, and offered only if it does.
  private static func writesAPicture(as type: UTType) -> Bool {
    let side = 256
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(NSMutableData(), type.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
  }

  // MARK: - Audio and video

  /// Everything AVFoundation can open, audio and video alike. Which of the two
  /// a given file is depends on the tracks it actually contains, so the split
  /// is made per file rather than guessed from the extension.
  static let readableMediaTypes: Set<UTType> = Set(
    AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }
      // AVFoundation's list includes what a player follows as well as what it
      // plays: playlists and caption files, in which it then finds no tracks.
      // Filed as films, they were offered a film's formats and failed in all.
      .filter { $0.conforms(to: .audiovisualContent) || $0.conforms(to: .audio) }
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

  /// 3D model formats, asked of ModelIO. Notably absent: glTF, GLB and FBX.
  static let readableModelTypes: Set<UTType> = Self.modelTypes { MDLAsset.canImportFileExtension($0) }
  static let writableModelTypes: Set<UTType> = Self.modelTypes { MDLAsset.canExportFileExtension($0) }

  static func isReadableModel(_ type: UTType) -> Bool { readableModelTypes.contains(type) }
  static func isWritableModel(_ type: UTType) -> Bool { writableModelTypes.contains(type) }

  // MARK: - Queries

  static func isReadableImage(_ type: UTType) -> Bool {
    if readableImageTypes.contains(type) { return true }
    if readableImageTypes.contains(where: { type.conforms(to: $0) }) { return true }
    // One extension can belong to several types, and the one macOS files a
    // photo under is not always the one ImageIO lists: an .orf is
    // `com.olympus.raw-image`, and ImageIO reads `com.olympus.or-raw-image`.
    guard let fileExtension = type.preferredFilenameExtension else { return false }
    return UTType.types(tag: fileExtension, tagClass: .filenameExtension, conformingTo: nil)
      .contains(where: readableImageTypes.contains)
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

  /// Whether this type can hold more than one image in a single file.
  ///
  /// ImageIO exposes no query for it, so the set is declared. It is short and
  /// stable: GIF and HEICS animate, TIFF and PDF are multi-page, and
  /// everything else ImageIO writes holds exactly one image.
  static func holdsMultipleFrames(_ type: UTType) -> Bool {
    multiFrameTypes.contains { type.conforms(to: $0) }
  }

  private static let multiFrameTypes: Set<UTType> = Set(
    ["com.compuserve.gif", "public.heics", "public.tiff", "com.adobe.pdf"].compactMap { UTType($0) }
  )

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
      // The audiobook container. macOS types the extension as the protected
      // variant, which describes the type database rather than the file: what
      // gets written is plain AAC in an MP4 container.
      (UTType("com.apple.protected-mpeg-4-audio-b"), kAudioFormatMPEG4AAC),
      // An iPhone's ringtone, which is an M4A by another name.
      (UTType("com.apple.mpeg-4-ringtone"), kAudioFormatMPEG4AAC),
    ]
    // Apple Lossless and Opus are both encodable on macOS but deliberately
    // absent: ALAC shares the .m4a container with AAC and Opus is written into
    // CAF, and this table maps one container to one codec. Offering them needs
    // a way to choose the codec, not another row here.

    return candidates.reduce(into: [:]) { result, candidate in
      guard let type = candidate.0,
            canEncodeAudio(type: type, formatID: candidate.1) else { return }
      result[type] = candidate.1
    }
  }

  /// Whether this host can encode with a given Core Audio format, in any
  /// container it fits.
  static func canEncode(_ formatID: AudioFormatID) -> Bool {
    let containers = ["m4a", "caf", "wav", "flac", "aiff"]
    return containers.contains { ext in
      guard let type = UTType(filenameExtension: ext) else { return false }
      return canEncodeAudio(type: type, formatID: formatID)
    }
  }

  /// Try to open a throwaway file for writing: the cheapest honest answer to
  /// "can this host encode that".
  static func canEncodeAudio(type: UTType, formatID: AudioFormatID) -> Bool {
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

  /// ModelIO answers per extension, so the candidates are extensions and the
  /// answer decides which survive.
  private static func modelTypes(_ supported: (String) -> Bool) -> Set<UTType> {
    let candidates = ["obj", "stl", "ply", "abc", "usd", "usda", "usdc", "usdz"]
    return Set(candidates.filter(supported).compactMap { UTType(filenameExtension: $0) })
  }

  /// The movie containers AVFoundation exports to.
  private static func videoContainers() -> Set<UTType> {
    Set([AVFileType.mp4, .mov, .m4v].compactMap { UTType($0.rawValue) })
  }
}
