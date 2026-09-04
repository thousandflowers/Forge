import Foundation
import AppKit
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

  func canProcess(_ file: ProcessableFile) -> Bool {
    FormatCatalog.isReadableMedia(file.fileType)
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

    // Media asked for text is transcribed, whether the words are in a
    // recording or in the soundtrack of a video.
    let wanted = Self.outputType(for: output, operations: operations, fallback: .mpeg4Movie)
    // Anything with a soundtrack asked for words becomes words. Which words
    // file it becomes is up to the extension: a recording renamed .rtf comes
    // out as RTF, .docx as DOCX, .pdf as a PDF of the transcript.
    if Self.isWords(wanted), !audioTracks.isEmpty {
      return try await transcribe(
        input, to: output, as: wanted, operations: operations, start: start, progress: progress
      )
    }

    if videoTracks.isEmpty {
      // Audio asked for a movie container is wrapped rather than converted:
      // the export writes the track into the container as it stands.
      let requestedType = Self.outputType(for: output, operations: operations, fallback: .mpeg4Audio)
      if FormatCatalog.isWritableVideo(requestedType) {
        return try await exportVideo(asset, to: output, operations: operations, start: start, progress: progress)
      }
      return try await convertAudio(input, to: output, operations: operations, start: start, progress: progress)
    }

    // A video asked to become an image is a frame export, not a re-encode:
    // this is what turns a clip into an animated GIF, or into a folder of
    // stills.
    let requested = Self.outputType(for: output, operations: operations, fallback: .mpeg4Movie)
    if FormatCatalog.isWritableImage(requested) {
      return try await exportFrames(
        asset, to: output, as: requested, operations: operations, start: start, progress: progress
      )
    }

    return try await exportVideo(asset, to: output, operations: operations, start: start, progress: progress)
  }

  // MARK: - Words out of a recording

  /// Whether a type is somewhere words can be written: plain text, or any of
  /// the document formats AppKit writes.
  static func isWords(_ type: UTType) -> Bool {
    type.conforms(to: .plainText) || DocumentText.canWrite(type)
  }

  private func transcribe(
    _ input: URL,
    to output: URL,
    as wanted: UTType,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    // The recognition language doubles as the transcription one: both answer
    // "which language is this in".
    let locale = operations.compactMap { operation -> String? in
      guard case .recognizeText(let languages) = operation else { return nil }
      return languages.first
    }.first

    let text = try await Transcription.text(of: input, locale: locale, progress: progress)

    if wanted.conforms(to: .plainText) {
      try text.write(to: output, atomically: true, encoding: .utf8)
    } else {
      // AppKit's document writer belongs to the main actor.
      let words = NSAttributedString(string: text)
      try await MainActor.run { try DocumentText.write(words, to: output, as: wanted) }
    }
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  // MARK: - Frames out of a video

  /// How often to sample when turning a video into frames. Twelve is the
  /// long-standing convention for an animated GIF: smooth enough to read, and
  /// small enough to send.
  private static let framesPerSecond: Double = 12

  /// Longest side of an exported frame when the preset does not say. A GIF at
  /// the source resolution is unusable at any length, so there is a default,
  /// and `--resize` overrides it.
  private static let defaultFrameSide: CGFloat = 640

  private func exportFrames(
    _ asset: AVURLAsset,
    to output: URL,
    as type: UTType,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let duration = try await asset.load(.duration).seconds
    guard duration > 0 else {
      throw ProcessingError.conversionFailed(reason: "The video has no duration to sample")
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = try await Self.frameSize(for: operations, asset: asset)

    let step = 1 / Self.framesPerSecond
    let times = stride(from: 0, to: duration, by: step).map {
      CMTime(seconds: $0, preferredTimescale: 600)
    }
    guard !times.isEmpty else {
      throw ProcessingError.conversionFailed(reason: "The video is too short to sample")
    }

    var frames: [ImageFrame] = []
    frames.reserveCapacity(times.count)
    for (index, time) in times.enumerated() {
      try Task.checkCancellation()
      let image = try generator.copyCGImage(at: time, actualTime: nil)
      frames.append(ImageFrame(image: image, duration: step))
      progress(Double(index + 1) / Double(times.count) * 0.9)
    }

    let extras = try Self.writeFrames(frames, to: output, as: type, operations: operations)
    progress(1.0)

    return ProcessingResult(
      outputURL: output,
      outputSize: try Self.fileSize(output),
      outputDimensions: (frames[0].image.width, frames[0].image.height),
      duration: Date().timeIntervalSince(start),
      additionalOutputs: extras
    )
  }

  /// The size to sample at: what the preset asked for, or a readable default
  /// that never enlarges the source.
  private static func frameSize(for operations: [Operation], asset: AVURLAsset) async throws -> CGSize {
    if let target = operations.compactMap(resizeTarget).first {
      return CGSize(width: target.width, height: target.height)
    }
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      return CGSize(width: defaultFrameSide, height: defaultFrameSide)
    }
    let natural = try await track.load(.naturalSize)
    let longest = max(abs(natural.width), abs(natural.height))
    guard longest > defaultFrameSide else { return natural }
    let scale = defaultFrameSide / longest
    return CGSize(width: abs(natural.width) * scale, height: abs(natural.height) * scale)
  }

  private static func writeFrames(
    _ frames: [ImageFrame],
    to output: URL,
    as type: UTType,
    operations: [Operation]
  ) throws -> [URL] {
    var options: [CFString: Any] = [:]
    if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
      let level = operations.compactMap(qualityLevel).first ?? ImageProcessor.defaultQuality
      options[kCGImageDestinationLossyCompressionQuality] = Float(level) / 100
    }

    if FormatCatalog.holdsMultipleFrames(type) {
      try ImageFrames.write(frames, to: output, as: type, frameOptions: options)
      return []
    }

    var extras: [URL] = []
    for (index, frame) in frames.enumerated() {
      let destination = index == 0 ? output : output.numbered(index + 1)
      try ImageFrames.write([frame], to: destination, as: type, frameOptions: options)
      if index > 0 { extras.append(destination) }
    }
    return extras
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
      throw ProcessingError.unsupportedConversion(from: .movie, to: outputType)
    }

    let fileType = AVFileType(outputType.identifier)
    let available = AVAssetExportSession.allExportPresets()
    // A named codec wins over a size: asking for ProRes and getting H.264
    // because the preset list is sorted by pixels would be the wrong answer.
    let preferred = Self.chosenCodec(in: operations)?.exportPreset
      ?? Self.videoPreset(for: operations, available: available)

    // Not every preset works with every asset, and the ones that do cannot
    // always write every container. Try the best match, then fall back rather
    // than failing on a video AVFoundation is perfectly able to convert.
    guard let session = Self.makeSession(
      asset: asset,
      preferred: preferred,
      fileType: fileType
    ) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot write \(outputType.preferredFilenameExtension ?? outputType.identifier) from this video"
      )
    }

    session.outputURL = output
    session.outputFileType = fileType
    session.shouldOptimizeForNetworkUse = true

    // The export publishes progress as a polled property, so a sibling task
    // samples it while the export runs. It has to keep polling through the
    // statuses before `.exporting` too: sampling only while already exporting
    // meant the loop exited immediately and no progress was ever reported.
    let box = ExportBox(session)
    let reporter = Task {
      while !Task.isCancelled {
        switch box.session.status {
        case .completed, .failed, .cancelled:
          return
        case .exporting:
          progress(Double(box.session.progress))
        default:
          break
        }
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

  /// The first preset that both opens for this asset and writes this container.
  private static func makeSession(
    asset: AVAsset,
    preferred: String,
    fileType: AVFileType
  ) -> AVAssetExportSession? {
    let candidates = [preferred, AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough]
    for name in candidates {
      guard let session = AVAssetExportSession(asset: asset, presetName: name),
            session.supportedFileTypes.contains(fileType) else { continue }
      return session
    }
    return nil
  }

  static func chosenCodec(in operations: [Operation]) -> Codec? {
    operations.compactMap { if case .encode(let codec) = $0 { return codec } else { return nil } }.first
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

    // A chosen codec decides what goes in the container, which is what makes
    // Apple Lossless in an .m4a and Opus in a .caf reachable at all.
    let chosen = Self.chosenCodec(in: operations)?.audioFormatID
    if let chosen, !FormatCatalog.canEncodeAudio(type: outputType, formatID: chosen) {
      throw ProcessingError.conversionFailed(
        reason: "\(Self.chosenCodec(in: operations)?.title ?? "That codec") does not fit in "
          + "\(outputType.preferredFilenameExtension?.uppercased() ?? outputType.identifier)."
      )
    }

    guard let formatID = chosen ?? FormatCatalog.audioFormatID(for: outputType) else {
      let inputType = UTType(filenameExtension: input.pathExtension) ?? .audio
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputType)
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
