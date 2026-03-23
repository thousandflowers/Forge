import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Native video processor using AVFoundation
final class VideoProcessor: FileProcessor, @unchecked Sendable {
  let name = "Video Processor"
  let isNative = true
  let supportedTypes: [UTType] = [.mp4, .mov, .m4v, .avi, .mkv, .webm]

  private let session = ProcessSession()

  func canProcess(_ file: ProcessableFile) -> Bool {
    supportedTypes.contains { file.fileType.conforms(to: $0) }
  }

  func supportedOutputTypes(for input: UTType) -> [UTType] {
    // Output to common MP4/H.264 for maximum compatibility
    return [.mp4, .mov, .m4v]
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
    guard asset.tracks(withMediaType: .video).count > 0 else {
      throw ProcessingError.conversionFailed(reason: "No video tracks found")
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

    // Setup video track reader output
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      throw ProcessingError.conversionFailed(reason: "No video track")
    }

    let outputSettings = buildReaderOutputSettings()
    let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
    reader.add(readerOutput)

    // Setup writer
    guard let writer = try? AVAssetWriter(outputURL: output, fileType: outputType) else {
      throw ProcessingError.conversionFailed(reason: "Cannot create asset writer")
    }

    // Setup writer input
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: buildWriterInputSettings(from: operations, source: videoTrack))
    writerInput.expectsMediaDataInRealTime = false

    // Add pixel buffer adaptation if needed
    let sourcePixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)
    ]

    writer.add(writerInput)

    // Determine transformation (resize, crop)
    let transform = determineCompositionTransform(for: operations, sourceTrack: videoTrack)
    writerInput.transform = transform

    // Start reading/writing
    guard writer.startWriting(), reader.startReading() else {
      throw ProcessingError.conversionFailed(reason: "Failed to start reader/writer")
    }

    writer.startSession(atSourceTime: .zero)

    // Use a background queue for processing
    let processingQueue = DispatchQueue(label: "com.fileforge.videoprocessor")

    var totalFrames: Int64 = 0
    var processedFrames: Int64 = 0

    // Estimate total frames from duration and nominal frame rate
    let duration = asset.duration
    let fps = videoTrack.nominalFrameRate
    totalFrames = Int64(duration.seconds * fps)

    writerInput.requestMediaDataWhenReady(on: processingQueue) {
      while writerInput.isReadyForMoreMediaData {
        guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
          writerInput.markAsFinished()
          break
        }

        // Here we could apply filters, but for MVP we just passthrough
        // Advanced: convert to CIImage, apply CIFilter, write back

        if let timing = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) {
          writerInput.append(sampleBuffer)
          processedFrames += 1

          let fraction = Double(processedFrames) / Double(max(1, totalFrames))
          progress(0.3 + fraction * 0.6) // 30%-90% progress
        }
      }
    }

    // Wait for completion
    writer.finishWriting {
      reader.cancelWriting()
    }

    // Check status
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
      outputDimensions: nil, // Would need to read back
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
    return .mp4 // default
  }

  private func buildReaderOutputSettings() -> [String: Any] {
    // Use BGRA for easy conversion to CIImage if needed later
    return [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
  }

  private func buildWriterInputSettings(from operations: [Operation], source: AVAssetTrack) -> [String: Any] {
    // Base codec settings
    var settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: source.naturalSize.width,
      AVVideoHeightKey: source.naturalSize.height
    ]

    // Quality/bitrate
    if let qualityOp = operations.first(where: { if case .quality = $0 { return true } else { return false } }),
       case .quality(let level) = qualityOp {
      // Approximate: quality 1-100 maps to bitrate 500k-20M
      let bitrate = 500_000 + (Int64(level) * 195_000)
      settings[AVVideoAverageBitRateKey] = bitrate
    } else {
      settings[AVVideoAverageBitRateKey] = 5_000_000 // default 5Mbps
    }

    return settings
  }

  private func determineCompositionTransform(for operations: [Operation], sourceTrack: AVAssetTrack) -> CGAffineTransform {
    // If resize operations exist, we'd adjust the transform or use AVMutableVideoComposition
    // For MVP, passthrough (identity)
    return .identity
  }
}

/// Simple session wrapper for cancellation support
final class ProcessSession {
  private var isCancelled = false

  func cancel() {
    isCancelled = true
  }

  func checkCancellation() throws {
    if isCancelled {
      throw ProcessingError.operationFailed(operation: "processing", underlying: nil)
    }
  }
}
