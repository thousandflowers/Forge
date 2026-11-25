import AVFoundation
import CoreImage
import Foundation
import VideoToolbox
import Vision

/// A film's pictures, drawn again one by one.
///
/// Into ProRes, which is encoded again on the way out: what is lost twice shows.
enum FilmFrames {
  private static let cannot = ProcessingError.conversionFailed(reason: "The film could not be drawn again.")

  /// Every picture through `paint`, the right way up.
  static func repaint(
    _ track: AVAssetTrack, in asset: AVAsset, to url: URL, seeThrough: Bool = false, paint: @escaping (CIImage) throws -> CIImage
  ) async throws {
    let stored = try await track.load(.naturalSize), turned = try await track.load(.preferredTransform)
    let shown = CGRect(origin: .zero, size: stored).applying(turned)
    let size = CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded())
    // Core Image counts from the bottom and the film from the top.
    let upright = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -stored.height)
      .concatenating(turned)
      .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
      .concatenating(CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -size.height))
    let context = CIContext(options: [.cacheIntermediates: false])
    let format = seeThrough ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    let read = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    try await write(track, in: asset, reading: read, to: url, size: size, as: seeThrough ? .proRes4444 : .proRes422, format: format) { frame, out in
      let image = try paint(CIImage(cvPixelBuffer: frame).transformed(by: upright)).cropped(to: CGRect(origin: .zero, size: size))
      CVBufferPropagateAttachments(frame, out)
      if seeThrough {
        // Whatever the film was in, what can be seen through is sRGB.
        CVBufferRemoveAllAttachments(out)
        context.clearCaches()
        context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
      } else {
        let space = CVBufferCopyAttachments(frame, .shouldPropagate).flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() }
        context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: space ?? CGColorSpace(name: CGColorSpace.itur_709))
      }
    }
  }

  /// Somebody else's idea of where people are: there is nobody in a test.
  nonisolated(unsafe) static var peopleForTests: (@Sendable (CIImage) -> CIImage?)?

  /// People, and nothing behind them.
  static func cutOut(_ track: AVAssetTrack, in asset: AVAsset, to url: URL) async throws {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .accurate
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    // One after the other, so that it follows whoever it is.
    let sequence = VNSequenceRequestHandler()
    var sawSomebody = false
    func people(in image: CIImage) throws -> CIImage? {
      if let pretend = peopleForTests {
        sawSomebody = true
        return pretend(image)
      }
      try sequence.perform([request], on: image)
      guard let mask = request.results?.first?.pixelBuffer else { return nil }
      if !sawSomebody { sawSomebody = hasAnything(mask) }
      return PictureTools.fitted(CIImage(cvPixelBuffer: mask), to: image)
    }
    try await repaint(track, in: asset, to: url, seeThrough: true) { image in
      guard let mask = try people(in: image) else { return CIImage.empty() }
      return image.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
      ]).cropped(to: image.extent)
    }
    guard sawSomebody else {
      throw ProcessingError.conversionFailed(reason: "There is nobody in the film: in a film, people are all that macOS tells from what is behind them.")
    }
  }

  private static func hasAnything(_ mask: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return false }
    let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
    var sure = 0
    for y in stride(from: 0, to: height, by: 4) { for x in stride(from: 0, to: width, by: 4) where base[y * row + x] > 128 { sure += 1 } }
    // Some of it, and not a speck.
    return sure * 16 * 200 > width * height
  }

  // MARK: - Slow motion

  /// The frames there are, and between each two the ones there would have been.
  /// The time has been stretched already.
  static func slow(_ track: AVAssetTrack, in asset: AVAsset, by times: Int, to url: URL) async throws {
    guard #available(macOS 15.4, *), VTFrameRateConversionConfiguration.isSupported else {
      throw ProcessingError.conversionFailed(reason: "Slow motion needs macOS 15.4 and an Apple silicon Mac. speed\(Tool.text(1 / Double(times)))x slows it down without making up frames.")
    }
    try await madeUp(track, in: asset, by: times, to: url)
  }

  @available(macOS 15.4, *)
  private static func madeUp(_ track: AVAssetTrack, in asset: AVAsset, by times: Int, to url: URL) async throws {
    let stored = try await track.load(.naturalSize)
    let width = Int(stored.width), height = Int(stored.height)
    guard let configuration = VTFrameRateConversionConfiguration(
      frameWidth: width, frameHeight: height, usePrecomputedFlow: false, qualityPrioritization: .normal, revision: .revision1
    ) else {
      throw ProcessingError.conversionFailed(reason: "macOS cannot make up frames for a film of \(width) × \(height).")
    }
    let processor = VTFrameProcessor()
    try processor.startSession(configuration: configuration)
    defer { processor.endSession() }
    guard let format = configuration.frameSupportedPixelFormats.first.map({ OSType(truncating: $0 as NSNumber) }) else { throw cannot }

    // Frames of its own: what a decoder hands out it wants back.
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, configuration.destinationPixelBufferAttributes as CFDictionary, &pool)
    guard let pool else { throw cannot }
    func blank() throws -> CVPixelBuffer {
      var made: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
      guard let made else { throw cannot }
      return made
    }
    let transfer = try Transfer()
    let writing = try Writing(track: track, to: url, size: stored, codec: .proRes422, format: format)
    let reading = try Reading(track, in: asset, format: format)
    var before: (buffer: CVPixelBuffer, time: CMTime)?
    while let (frame, time) = try reading.next() {
      try Task.checkCancellation()
      let held = try blank()
      try transfer.copy(frame, to: held)
      CVBufferPropagateAttachments(frame, held)
      if let last = before, let source = VTFrameProcessorFrame(buffer: last.buffer, presentationTimeStamp: last.time),
         let next = VTFrameProcessorFrame(buffer: held, presentationTimeStamp: time) {
        try await writing.append(last.buffer, at: last.time)
        let step = CMTimeMultiplyByRatio(time - last.time, multiplier: 1, divisor: Int32(times))
        var made: [(buffer: CVPixelBuffer, time: CMTime)] = []
        for index in 1..<times {
          let buffer = try blank()
          CVBufferPropagateAttachments(frame, buffer)
          made.append((buffer, last.time + CMTimeMultiply(step, multiplier: Int32(index))))
        }
        let frames = made.compactMap { VTFrameProcessorFrame(buffer: $0.buffer, presentationTimeStamp: $0.time) }
        guard let parameters = VTFrameRateConversionParameters(
          sourceFrame: source, nextFrame: next, opticalFlow: nil,
          interpolationPhase: (1..<times).map { Float($0) / Float(times) }, submissionMode: .sequential, destinationFrames: frames
        ) else { throw cannot }
        try await processor.process(parameters: parameters)
        for one in made { try await writing.append(one.buffer, at: one.time) }
      }
      before = (held, time)
    }
    if let before { try await writing.append(before.buffer, at: before.time) }
    try await writing.finish(at: try await track.load(.timeRange).end)
  }

  // MARK: - Reading and writing

  private static func write(
    _ track: AVAssetTrack, in asset: AVAsset, reading read: OSType, to url: URL, size: CGSize, as codec: AVVideoCodecType, format: OSType,
    _ draw: (CVPixelBuffer, CVPixelBuffer) throws -> Void
  ) async throws {
    let writing = try Writing(track: track, to: url, size: size, codec: codec, format: format)
    let reading = try Reading(track, in: asset, format: read)
    while let (frame, time) = try reading.next() {
      try Task.checkCancellation()
      let out = try writing.blank()
      try autoreleasepool { try draw(frame, out) }
      try await writing.append(out, at: time)
    }
    try await writing.finish(at: try await track.load(.timeRange).end)
  }

  private final class Reading {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(_ track: AVAssetTrack, in asset: AVAsset, format: OSType) throws {
      reader = try AVAssetReader(asset: asset)
      output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(format), kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ])
      output.alwaysCopiesSampleData = false
      reader.add(output)
      guard reader.startReading() else { throw reader.error ?? cannot }
    }

    func next() throws -> (CVPixelBuffer, CMTime)? {
      while let sample = output.copyNextSampleBuffer() {
        if let buffer = CMSampleBufferGetImageBuffer(sample) { return (buffer, CMSampleBufferGetPresentationTimeStamp(sample)) }
      }
      guard reader.status == .completed else { throw reader.error ?? cannot }
      return nil
    }
  }

  private final class Writing {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(track: AVAssetTrack, to url: URL, size: CGSize, codec: AVVideoCodecType, format: OSType) throws {
      writer = try AVAssetWriter(outputURL: url, fileType: .mov)
      input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
      ])
      input.expectsMediaDataInRealTime = false
      adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(format), kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ])
      writer.add(input)
      guard writer.startWriting() else { throw writer.error ?? cannot }
      writer.startSession(atSourceTime: .zero)
    }

    deinit { if writer.status == .writing { writer.cancelWriting() } }

    func blank() throws -> CVPixelBuffer {
      var made: CVPixelBuffer?
      if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) }
      guard let made else { throw writer.error ?? cannot }
      return made
    }

    func append(_ buffer: CVPixelBuffer, at time: CMTime) async throws {
      while !input.isReadyForMoreMediaData {
        try Task.checkCancellation()
        guard writer.status == .writing else { throw writer.error ?? cannot }
        try await Task.sleep(nanoseconds: 2_000_000)
      }
      guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? cannot }
    }

    func finish(at end: CMTime) async throws {
      input.markAsFinished()
      writer.endSession(atSourceTime: end)
      await writer.finishWriting()
      guard writer.status == .completed else { throw writer.error ?? cannot }
    }
  }

  private final class Transfer {
    private let session: VTPixelTransferSession

    init() throws {
      var made: VTPixelTransferSession?
      VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made)
      guard let made else { throw cannot }
      session = made
    }

    func copy(_ from: CVPixelBuffer, to: CVPixelBuffer) throws {
      guard VTPixelTransferSessionTransferImage(session, from: from, to: to) == noErr else { throw cannot }
    }

    deinit { VTPixelTransferSessionInvalidate(session) }
  }
}
