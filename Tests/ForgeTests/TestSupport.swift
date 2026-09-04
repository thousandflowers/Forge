import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Forge

/// Shared base class for Forge unit tests.
///
/// Every fixture is built at runtime rather than checked in, so the suite runs
/// anywhere without binary files in the repository and without depending on
/// tools that may not exist on a CI machine.
class BaseTestCase: XCTestCase {
  private(set) var workspace: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let workspace { try? FileManager.default.removeItem(at: workspace) }
    try super.tearDownWithError()
  }

  func path(_ name: String) -> URL { workspace.appendingPathComponent(name) }

  func folder(_ name: String) throws -> URL {
    let url = path(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A store rooted in this test's scratch directory. Tests used to write
  /// presets, history and backups straight into the real Application Support
  /// folder the app keeps for the person using it.
  private(set) lazy var store = PersistenceManager(root: workspace.appendingPathComponent("store"))

  func coordinator(settings: AppSettings = AppSettings()) -> ProcessingCoordinator {
    ProcessingCoordinator(registry: ProcessorRegistry(), settings: settings, persistence: store)
  }

  func size(of url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.size] as? Int64 ?? -1
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func contents(of folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { !$0.hasPrefix(".") }
      .sorted()
  }
}

// MARK: - Fixtures

enum Fixture {

  /// A gradient image, written with whatever type the extension implies.
  @discardableResult
  static func image(
    at url: URL,
    width: Int = 320,
    height: Int = 200,
    metadata: [CFString: Any]? = nil
  ) throws -> URL {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw Failure("Cannot create a bitmap context")
    }

    for row in 0..<height {
      let fraction = CGFloat(row) / CGFloat(height)
      context.setFillColor(CGColor(red: fraction, green: 1 - fraction, blue: 0.5, alpha: 1))
      context.fill(CGRect(x: 0, y: row, width: width, height: 1))
    }

    guard let image = context.makeImage() else { throw Failure("Cannot render the bitmap") }
    let type = UTType(filenameExtension: url.pathExtension) ?? .png
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, type.identifier as CFString, 1, nil
    ) else {
      throw Failure("Cannot write \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, metadata as CFDictionary?)
    guard CGImageDestinationFinalize(destination) else {
      throw Failure("Cannot finalise \(url.lastPathComponent)")
    }
    return url
  }

  /// A PDF with the requested number of pages.
  @discardableResult
  static func pdf(at url: URL, pages: Int) throws -> URL {
    let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
    var mediaBox = bounds
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
      throw Failure("Cannot create a PDF context")
    }
    for page in 0..<pages {
      context.beginPDFPage(nil)
      let shade = CGFloat(page + 1) / CGFloat(pages + 1)
      context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
      context.fill(bounds)
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  /// A sine tone, written as 16-bit PCM in whatever container the extension names.
  @discardableResult
  static func audio(
    at url: URL,
    seconds: Double = 2,
    sampleRate: Double = 48_000,
    channels: AVAudioChannelCount = 1
  ) throws -> URL {
    guard let format = AVAudioFormat(
      standardFormatWithSampleRate: sampleRate,
      channels: channels
    ) else {
      throw Failure("Cannot describe the audio format")
    }

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: Int(channels),
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: url.pathExtension.lowercased() == "aiff",
    ]

    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      throw Failure("Cannot allocate an audio buffer")
    }
    buffer.frameLength = frames

    for channel in 0..<Int(channels) {
      guard let samples = buffer.floatChannelData?[channel] else { continue }
      for frame in 0..<Int(frames) {
        samples[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate)) * 0.4
      }
    }
    try file.write(from: buffer)
    return url
  }

  /// A short movie. With `withAudio`, the tone above is muxed alongside the
  /// picture, which is what makes "did the conversion keep the audio" testable.
  @discardableResult
  static func video(
    at url: URL,
    seconds: Double = 1,
    size: CGSize = CGSize(width: 640, height: 360),
    withAudio: Bool = true
  ) async throws -> URL {
    let silent = url.deletingLastPathComponent()
      .appendingPathComponent("silent-\(UUID().uuidString).mov")
    try await writePictureTrack(to: silent, seconds: seconds, size: size)
    defer { try? FileManager.default.removeItem(at: silent) }

    guard withAudio else {
      try FileManager.default.moveItem(at: silent, to: url)
      return url
    }

    let tone = url.deletingLastPathComponent()
      .appendingPathComponent("tone-\(UUID().uuidString).m4a")
    try audioAAC(at: tone, seconds: seconds)
    defer { try? FileManager.default.removeItem(at: tone) }

    let composition = AVMutableComposition()
    try await add(track: .video, from: AVURLAsset(url: silent), to: composition)
    try await add(track: .audio, from: AVURLAsset(url: tone), to: composition)

    guard let session = AVAssetExportSession(
      asset: composition,
      presetName: AVAssetExportPresetHighestQuality
    ) else {
      throw Failure("Cannot create an export session")
    }
    session.outputURL = url
    session.outputFileType = .mp4
    await session.export()
    guard session.status == .completed else {
      throw Failure("Cannot mux the fixture: \(session.error?.localizedDescription ?? "unknown")")
    }
    return url
  }

  // MARK: - Fixture internals

  private static func add(
    track mediaType: AVMediaType,
    from asset: AVURLAsset,
    to composition: AVMutableComposition
  ) async throws {
    guard let source = try await asset.loadTracks(withMediaType: mediaType).first else { return }
    guard let target = composition.addMutableTrack(
      withMediaType: mediaType,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      throw Failure("Cannot add a \(mediaType.rawValue) track")
    }
    let duration = try await asset.load(.duration)
    try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
  }

  private static func audioAAC(at url: URL, seconds: Double) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100.0,
      AVNumberOfChannelsKey: 1,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(44_100 * seconds)
          ) else {
      throw Failure("Cannot allocate the tone buffer")
    }
    buffer.frameLength = buffer.frameCapacity
    if let samples = buffer.floatChannelData?[0] {
      for frame in 0..<Int(buffer.frameLength) {
        samples[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / 44_100)) * 0.4
      }
    }
    try file.write(from: buffer)
  }

  private static func writePictureTrack(to url: URL, seconds: Double, size: CGSize) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
      throw Failure("Cannot start writing the fixture: \(writer.error?.localizedDescription ?? "unknown")")
    }
    writer.startSession(atSourceTime: .zero)

    let fps: Int32 = 30
    let total = Int(seconds * Double(fps))
    for frame in 0..<total {
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      guard let pool = adaptor.pixelBufferPool else { throw Failure("No pixel buffer pool") }
      var pixelBuffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
      guard let pixelBuffer else { throw Failure("No pixel buffer") }

      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        let bytes = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        memset(base, Int32(frame * 255 / max(1, total)), bytes)
      }
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

      adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw Failure("Cannot finish the fixture: \(writer.error?.localizedDescription ?? "unknown")")
    }
  }
}

struct Failure: LocalizedError {
  let reason: String
  init(_ reason: String) { self.reason = reason }
  var errorDescription: String? { reason }
}

// MARK: - Convenience

extension UTType {
  static var mp4: UTType { .mpeg4Movie }
  static var mov: UTType { .quickTimeMovie }
  static var m4a: UTType { UTType("com.apple.m4a-audio")! }
  static var flac: UTType { UTType("org.xiph.flac")! }
}

extension AVURLAsset {
  func trackCounts() async throws -> (video: Int, audio: Int) {
    async let video = loadTracks(withMediaType: .video).count
    async let audio = loadTracks(withMediaType: .audio).count
    return (try await video, try await audio)
  }
}

extension RulePreset {
  /// Terse constructor for tests, which care about operations and not names.
  static func make(
    format: UTType? = nil,
    resize: ResizeSpec? = nil,
    quality: Int? = nil,
    filters: [FilterType] = [],
    category: PresetCategory = .custom
  ) -> RulePreset {
    RulePreset(
      name: "test",
      description: "test preset",
      targetFormat: format,
      resize: resize,
      quality: quality,
      filters: filters,
      category: category
    )
  }
}
