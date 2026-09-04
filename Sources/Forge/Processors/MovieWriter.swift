import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Writes a sequence of images out as a movie.
///
/// This is the other half of the frame export: a video becomes an animated GIF,
/// and an animated GIF becomes a video.
enum MovieWriter {

  /// Frame rate used when the source frames carry no timing of their own.
  static let defaultFrameRate: Int32 = 12

  static func write(
    _ frames: [ImageFrame],
    to output: URL,
    as type: UTType,
    progress: (Double) -> Void
  ) async throws {
    guard let first = frames.first else {
      throw ProcessingError.conversionFailed(reason: "Nothing to write")
    }

    // H.264 rejects odd dimensions, and a frame taken from an arbitrary image
    // is very often odd.
    let size = CGSize(width: (first.image.width / 2) * 2, height: (first.image.height / 2) * 2)
    guard size.width > 0, size.height > 0 else {
      throw ProcessingError.conversionFailed(reason: "The frames are too small to encode")
    }

    let writer = try AVAssetWriter(outputURL: output, fileType: AVFileType(type.identifier))
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
    ])
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
      ]
    )

    writer.add(input)
    guard writer.startWriting() else {
      throw ProcessingError.conversionFailed(
        reason: writer.error?.localizedDescription ?? "Cannot start writing the movie"
      )
    }
    writer.startSession(atSourceTime: .zero)

    let timescale: CMTimeScale = 600
    var elapsed = CMTime.zero

    for (index, frame) in frames.enumerated() {
      try Task.checkCancellation()
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      guard let pool = adaptor.pixelBufferPool else {
        throw ProcessingError.conversionFailed(reason: "Cannot allocate video frames")
      }
      let buffer = try pixelBuffer(from: frame.image, size: size, pool: pool)
      adaptor.append(buffer, withPresentationTime: elapsed)

      // Honour each frame's own delay, so a GIF keeps its pacing.
      let step = frame.duration > 0 ? frame.duration : 1 / Double(defaultFrameRate)
      elapsed = CMTimeAdd(elapsed, CMTime(seconds: step, preferredTimescale: timescale))
      progress(Double(index + 1) / Double(frames.count))
    }

    input.markAsFinished()
    await writer.finishWriting()

    guard writer.status == .completed else {
      throw ProcessingError.conversionFailed(
        reason: writer.error?.localizedDescription ?? "The movie did not finish writing"
      )
    }
  }

  private static func pixelBuffer(from image: CGImage, size: CGSize, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else {
      throw ProcessingError.conversionFailed(reason: "Cannot allocate a video frame")
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: Int(size.width),
      height: Int(size.height),
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else {
      throw ProcessingError.conversionFailed(reason: "Cannot draw a video frame")
    }

    context.draw(image, in: CGRect(origin: .zero, size: size))
    return buffer
  }
}
