import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Native audio processor using AVFoundation
final class AudioProcessor: FileProcessor, @unchecked Sendable {
  let name = "Audio Processor"
  let isNative = true
  let supportedTypes: [UTType] = {
    var types: [UTType] = []
    let audioUTIs = [
      "public.mp3",
      "public.wav",
      "public.aiff-audio",
      "com.apple.m4a-audio",
      "public.aac-audio",
      "public.flac",
      "com.apple.alac"
    ]
    for utiString in audioUTIs {
      if let type = UTType(utiString) {
        types.append(type)
      }
    }
    return types
  }()

  func canProcess(_ file: ProcessableFile) -> Bool {
    supportedTypes.contains { file.fileType.conforms(to: $0) }
  }

  func supportedOutputTypes(for input: UTType) -> [UTType] {
    // Common audio formats - use basic types that are always available
    var types: [UTType] = []
    if let mp3 = UTType(mimeType: "audio/mpeg") { types.append(mp3) }
    if let wav = UTType(filenameExtension: "wav") { types.append(wav) }
    if let aiff = UTType(filenameExtension: "aiff") { types.append(aiff) }
    // Also try to add common ones via identifiers
    if let m4a = UTType("com.apple.m4a-audio") { types.append(m4a) }
    if let aac = UTType("public.aac-audio") { types.append(aac) }
    if let flac = UTType("public.flac") { types.append(flac) }
    return types
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    try validateOperations(operations, for: try Self.determineInputType(input))

    // Load asset
    let asset = AVURLAsset(url: input)
    guard asset.tracks(withMediaType: .audio).count > 0 else {
      throw ProcessingError.conversionFailed(reason: "No audio tracks found")
    }

    // Determine output format
    let outputUTI = Self.determineOutputUTI(from: output, operations: operations)
    let outputType = AVFileType(outputUTI.identifier)

    // Create reader
    guard let reader = try? AVAssetReader(asset: asset) else {
      throw ProcessingError.conversionFailed(reason: "Cannot create asset reader")
    }

    guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
      throw ProcessingError.conversionFailed(reason: "No audio track")
    }

    let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
    reader.add(readerOutput)

    // Create writer
    guard let writer = try? AVAssetWriter(outputURL: output, fileType: outputType) else {
      throw ProcessingError.conversionFailed(reason: "Cannot create asset writer for format \(outputUTI.identifier)")
    }

    let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: buildWriterSettings(from: operations))
    writer.add(writerInput)

    guard writer.startWriting(), reader.startReading() else {
      throw ProcessingError.conversionFailed(reason: "Failed to start reader/writer")
    }

    writer.startSession(atSourceTime: .zero)

    let processingQueue = DispatchQueue(label: "com.fileforge.audioprocessor")

    var totalSamples: Int64 = 0
    var processedSamples: Int64 = 0

    // Estimate total from duration and sample rate
    let duration = asset.duration
    let sampleRate = audioTrack.naturalTimeScale // approximations
    totalSamples = Int64(duration.seconds * Double(sampleRate))

    processingQueue.async {
      writerInput.requestMediaDataWhenReady(on: processingQueue) {
        while writerInput.isReadyForMoreMediaData {
          guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
            writerInput.markAsFinished()
            break
          }

          writerInput.append(sampleBuffer)

          // Progress
          processedSamples += 1
          let fraction = Double(processedSamples) / Double(max(1, totalSamples))
          progress(0.3 + fraction * 0.6)
        }
      }

      writer.finishWriting {
        reader.cancelReading()
      }
    }

    // Wait for completion (simplified for MVP)
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

    switch writer.status {
    case .completed:
      break
    case .failed, .cancelled:
      throw ProcessingError.conversionFailed(reason: writer.error?.localizedDescription ?? "Unknown writer error")
    default:
      break
    }

    progress(1.0)

    let outputSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64 ?? 0
    let durationTime = Date().timeIntervalSince(start)

    return ProcessingResult(
      outputURL: output,
      outputSize: outputSize,
      outputDimensions: nil,
      duration: durationTime
    )
  }

  // MARK: - Helpers

  private static func determineInputType(_ url: URL) throws -> UTType {
    guard let type = UTType(filenameExtension: url.pathExtension) else {
      throw ProcessingError.unknownType
    }
    return type
  }

  private static func determineOutputUTI(from outputURL: URL, operations: [Operation]) -> UTType {
    if let convertOp = operations.first(where: { if case .convertFormat = $0 { return true } else { return false } }),
       case .convertFormat(let to) = convertOp {
      return to
    }
    if let type = UTType(filenameExtension: outputURL.pathExtension) {
      return type
    }
    // Default to M4A (AAC in MP4 container)
    return UTType(filenameExtension: "m4a") ?? UTType("com.apple.m4a-audio") ?? .audio
  }

  private func buildWriterSettings(from operations: [Operation]) -> [String: Any] {
    var settings: [String: Any] = [:]

    // Determine codec and bitrate
    var bitrate: Int = 256_000 // default 256kbps

    if let qualityOp = operations.first(where: { if case .quality = $0 { return true } else { return false } }),
       case .quality(let level) = qualityOp {
      bitrate = 64_000 + (level * 3_200) // map 1-100 to 64k-368k
    }

    settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
    settings[AVEncoderBitRateKey] = bitrate
    settings[AVNumberOfChannelsKey] = 2
    settings[AVSampleRateKey] = 44_100

    return settings
  }
}
