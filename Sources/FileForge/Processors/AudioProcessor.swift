import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Native audio processor using AVFoundation
final class AudioProcessor: FileProcessor, @unchecked Sendable {
  let name = "Audio Processor"
  let isNative = true
  let supportedTypes: [UTType] = [.mp3, .wav, .m4a, .aac, .flac, .alac, .aiff, .wav]

  func canProcess(_ file: ProcessableFile) -> Bool {
    supportedTypes.contains { file.fileType.conforms(to: $0) }
  }

  func supportedOutputTypes(for input: UTType) -> [UTType] {
    // Common audio formats
    return [.mp3, .m4a, .wav, .aac, .flac]
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
    guard let outputType = AVFileType(rawValue: outputUTI.identifier) else {
      throw ProcessingError.unsupportedFormat(outputUTI)
    }

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
      throw ProcessingError.conversionFailed(reason: "Cannot create asset writer")
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

    writerInput.requestMediaDataWhenReady(on: processingQueue) {
      while writerInput.isReadyForMoreMediaData {
        guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
          writerInput.markAsFinished()
          break
        }

        writerInput.append(sampleBuffer)

        // Progress
        if let timing = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) {
          processedSamples += 1
          let fraction = Double(processedSamples) / Double(max(1, totalSamples))
          progress(0.3 + fraction * 0.6)
        }
      }
    }

    writer.finishWriting {
      reader.cancelWriting()
    }

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
    return .m4a // default
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
