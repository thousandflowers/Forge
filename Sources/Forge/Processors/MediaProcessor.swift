import Foundation
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers

/// Audio and video conversion, both handled through AVFoundation's own
/// pipelines.
///
/// Audio and video live together because the distinction is a property of the
/// file, not of its extension: a `.mov` carrying only an audio track is an
/// audio file, and deciding from the extension is how every `.wav` ended up
/// routed to a processor that had never really supported it.
///
/// Both paths delegate encoding to AVFoundation rather than pumping sample
/// buffers by hand. The hand-rolled version dropped audio tracks, ignored
/// resize requests, reported success on unfinished files, and crashed the
/// process outright on malformed writer settings.
final class MediaProcessor: FileProcessor, @unchecked Sendable {
  let name = "Media Processor"

  var supportedTypes: [UTType] { Array(FormatCatalog.readableMediaTypes) }

  func canProcess(_ file: ProcessableFile) -> Bool {
    FormatCatalog.isReadableMedia(file.fileType)
  }

  func supportedOutputTypes(for input: UTType) -> [UTType] {
    let audio = Array(FormatCatalog.writableAudioTypes.keys)
    let video = Array(FormatCatalog.writableVideoTypes)
    return (audio + video).sorted { $0.identifier < $1.identifier }
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    let asset = AVURLAsset(url: input)

    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)

    guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
      throw ProcessingError.conversionFailed(
        reason: "\(input.lastPathComponent) contains no audio or video tracks"
      )
    }

    if videoTracks.isEmpty {
      return try await convertAudio(input, to: output, operations: operations, start: start, progress: progress)
    }
    return try await exportVideo(asset, to: output, operations: operations, start: start, progress: progress)
  }

  // MARK: - Video

  private func exportVideo(
    _ asset: AVURLAsset,
    to output: URL,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let outputType = Self.outputType(for: output, operations: operations, fallback: .mpeg4Movie)
    guard FormatCatalog.isWritableVideo(outputType) else {
      throw ProcessingError.unsupportedFormat(outputType)
    }

    let presetName = Self.videoPreset(for: operations, available: AVAssetExportSession.allExportPresets())

    guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
      throw ProcessingError.conversionFailed(reason: "No export preset available for this video")
    }

    let fileType = AVFileType(outputType.identifier)
    guard session.supportedFileTypes.contains(fileType) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot write \(outputType.preferredFilenameExtension ?? outputType.identifier) from this video"
      )
    }

    session.outputURL = output
    session.outputFileType = fileType
    session.shouldOptimizeForNetworkUse = true

    // The export publishes progress as a polled property, so a sibling task
    // samples it while the export runs.
    let box = ExportBox(session)
    let reporter = Task {
      while !Task.isCancelled && box.session.status == .exporting {
        progress(Double(box.session.progress))
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    defer { reporter.cancel() }

    await withTaskCancellationHandler {
      await box.session.export()
    } onCancel: {
      box.session.cancelExport()
    }

    switch session.status {
    case .completed:
      break
    case .cancelled:
      throw CancellationError()
    default:
      throw ProcessingError.conversionFailed(
        reason: session.error?.localizedDescription ?? "Video export did not complete"
      )
    }

    progress(1.0)

    let written = AVURLAsset(url: output)
    var dimensions: (width: Int, height: Int)?
    if let track = try await written.loadTracks(withMediaType: .video).first {
      let size = try await track.load(.naturalSize)
      dimensions = (Int(abs(size.width)), Int(abs(size.height)))
    }

    return ProcessingResult(
      outputURL: output,
      outputSize: try Self.fileSize(output),
      outputDimensions: dimensions,
      duration: Date().timeIntervalSince(start)
    )
  }

  /// Pick the export preset that best matches the requested operations.
  ///
  /// Preset names carry their own dimensions (`AVAssetExportPreset1280x720`),
  /// so the choice is read out of the names the system offers rather than from
  /// a hardcoded mapping that would rot with every OS release.
  static func videoPreset(for operations: [Operation], available: [String]) -> String {
    let sized = available.compactMap { name -> (name: String, pixels: Int, width: Int, height: Int)? in
      guard let size = Self.dimensions(inPresetNamed: name) else { return nil }
      return (name, size.width * size.height, size.width, size.height)
    }

    if let target = operations.compactMap(Self.resizeTarget).first, !sized.isEmpty {
      let covering = sized
        .filter { $0.width >= target.width && $0.height >= target.height }
        .min { $0.pixels < $1.pixels }
      let largest = sized.max { $0.pixels < $1.pixels }
      if let chosen = covering ?? largest { return chosen.name }
    }

    if let quality = operations.compactMap(Self.qualityLevel).first {
      let tiers = [
        (limit: 33, preset: AVAssetExportPresetLowQuality),
        (limit: 66, preset: AVAssetExportPresetMediumQuality),
        (limit: 100, preset: AVAssetExportPresetHighestQuality),
      ]
      if let tier = tiers.first(where: { quality <= $0.limit && available.contains($0.preset) }) {
        return tier.preset
      }
    }

    return available.contains(AVAssetExportPresetHighestQuality)
      ? AVAssetExportPresetHighestQuality
      : AVAssetExportPresetPassthrough
  }

  /// Read `1280x720` out of `AVAssetExportPreset1280x720`.
  static func dimensions(inPresetNamed name: String) -> (width: Int, height: Int)? {
    let allowed: Set<Character> = Set("0123456789x")
    let trailing = String(name.reversed().prefix { allowed.contains($0) }.reversed())
    let parts = trailing.split(separator: "x")
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
    return (width, height)
  }

  private static func resizeTarget(_ operation: Operation) -> (width: Int, height: Int)? {
    guard case .resize(let width, let height, _) = operation,
          let width, let height else { return nil }
    return (width, height)
  }

  private static func qualityLevel(_ operation: Operation) -> Int? {
    guard case .quality(let level) = operation else { return nil }
    return level
  }

  // MARK: - Audio

  private func convertAudio(
    _ input: URL,
    to output: URL,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let outputType = Self.outputType(for: output, operations: operations, fallback: .mpeg4Audio)
    guard let formatID = FormatCatalog.audioFormatID(for: outputType) else {
      throw ProcessingError.unsupportedFormat(outputType)
    }

    let inputFile = try AVAudioFile(forReading: input)
    let sourceFormat = inputFile.processingFormat

    // Sample rate and channel count follow the source: Forge offers no way to
    // ask for anything else, and silently resampling a 48 kHz mono recording
    // to 44.1 kHz stereo is not a conversion the user requested.
    var settings: [String: Any] = [
      AVFormatIDKey: formatID,
      AVSampleRateKey: sourceFormat.sampleRate,
      AVNumberOfChannelsKey: Int(sourceFormat.channelCount),
    ]
    if formatID == kAudioFormatLinearPCM {
      settings[AVLinearPCMBitDepthKey] = 16
      settings[AVLinearPCMIsFloatKey] = false
      settings[AVLinearPCMIsBigEndianKey] = FormatCatalog.usesBigEndianPCM(outputType)
    } else if let quality = operations.compactMap(Self.qualityLevel).first {
      settings[AVEncoderBitRateKey] = Self.bitrate(forQuality: quality, channels: Int(sourceFormat.channelCount))
    }

    let totalFrames = inputFile.length
    try Self.writeSamples(from: inputFile, to: output, settings: settings, format: sourceFormat) { position in
      progress(totalFrames > 0 ? Double(position) / Double(totalFrames) : 0)
    }

    progress(1.0)

    return ProcessingResult(
      outputURL: output,
      outputSize: try Self.fileSize(output),
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  /// Stream the samples across in bounded chunks, keeping memory flat on long
  /// recordings. Leaving this scope closes the output file, which is what makes
  /// the result valid: a previous version measured the file while it was still
  /// open and reported success on a partial write.
  private static func writeSamples(
    from inputFile: AVAudioFile,
    to output: URL,
    settings: [String: Any],
    format: AVAudioFormat,
    progress: (AVAudioFramePosition) -> Void
  ) throws {
    let outputFile = try AVAudioFile(forWriting: output, settings: settings)
    let chunk: AVAudioFrameCount = 64 * 1024

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
      throw ProcessingError.conversionFailed(reason: "Cannot allocate an audio buffer")
    }

    // Bounded by the source length: reading past the end throws rather than
    // returning zero frames.
    while inputFile.framePosition < inputFile.length {
      try Task.checkCancellation()
      let remaining = AVAudioFrameCount(min(Int64(chunk), inputFile.length - inputFile.framePosition))
      try inputFile.read(into: buffer, frameCount: remaining)
      guard buffer.frameLength > 0 else { break }
      try outputFile.write(from: buffer)
      progress(inputFile.framePosition)
    }
    _ = outputFile
  }

  /// Map a 1-100 quality level onto a per-channel bitrate.
  private static func bitrate(forQuality quality: Int, channels: Int) -> Int {
    let perChannel = 32_000 + (max(1, min(100, quality)) * 1_280)
    return perChannel * max(1, channels)
  }

  // MARK: - Shared helpers

  private static func outputType(for output: URL, operations: [Operation], fallback: UTType) -> UTType {
    let requested = operations.compactMap { operation -> UTType? in
      guard case .convertFormat(let to) = operation else { return nil }
      return to
    }.first
    return requested ?? UTType(filenameExtension: output.pathExtension) ?? fallback
  }

  private static func fileSize(_ url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.size] as? Int64 ?? 0
  }
}

/// Reading `progress` and calling `cancelExport()` from another task is what
/// an export session is for, but the class itself predates `Sendable`.
private final class ExportBox: @unchecked Sendable {
  let session: AVAssetExportSession
  init(_ session: AVAssetExportSession) { self.session = session }
}
