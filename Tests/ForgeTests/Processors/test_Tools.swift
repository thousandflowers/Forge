import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Forge

/// A quarter of it red, one green, one blue and one white, so that a turn the
/// wrong way is a different picture and not a rounding.
enum Quarters {
  enum Colour: String { case red, green, blue, white, black, clear, other }
  static let colours: [CGColor] = [
    CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
    CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 1),
  ]

  /// Red green over blue white.
  static func picture(width: Int = 320, height: Int = 200) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for (index, colour) in colours.enumerated() {
      context.setFillColor(colour)
      context.fill(CGRect(
        x: index % 2 * width / 2, y: index < 2 ? height / 2 : 0, width: width / 2, height: height / 2
      ))
    }
    return context.makeImage()!
  }

  /// Top left, top right, bottom left, bottom right.
  static func read(_ image: CGImage) -> [Colour] {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)].map { point in
      let at = (Int(Double(height) * point.1) * width + Int(Double(width) * point.0)) * 4
      let (red, green, blue, alpha) = (bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3])
      if alpha < 40 { return .clear }
      switch (red > 128, green > 128, blue > 128) {
      case (true, false, false): return .red
      case (false, true, false): return .green
      case (false, false, true): return .blue
      case (true, true, true): return .white
      case (false, false, false): return .black
      default: return .other
      }
    }
  }

  static func read(_ url: URL) throws -> [Colour] {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    return read(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
  }

  static func image(at url: URL, width: Int = 320, height: Int = 200) throws {
    let type = UTType(filenameExtension: url.pathExtension)!
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, picture(width: width, height: height), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  static func film(at url: URL, width: Int = 320, height: Int = 200, seconds: Double = 2) async throws {
    let frames = (0..<Int(seconds * 10)).map { _ in ImageFrame(image: picture(width: width, height: height), duration: 0.1) }
    try await MovieWriter.write(frames, to: url, as: UTType(filenameExtension: url.pathExtension)!) { _ in }
  }

  static func frame(of url: URL, at seconds: Double = 0.5) throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
  }
}

class ToolTestCase: BaseTestCase {
  /// The file through a chain, beside nothing: into a folder of its own.
  func run(_ words: [String], on url: URL, to format: UTType? = nil, mode: DestinationMode = .copyTo, more: [Forge.Operation] = []) async throws -> [URL] {
    let formats: [Forge.Operation] = format.map { [.convertFormat(to: $0)] } ?? []
    let actions = formats + more + words.map { .tool(Tool(word: $0)!) }
    let preset = RulePreset(name: "t", description: "", category: .custom, actions: actions)
    let out = path("out-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: url), with: preset, destinationMode: mode, destinationURL: mode == .overwrite ? nil : out
    ) { _ in }
    return entry.outputs
  }

  func seconds(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

  func reason(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> String {
    do { try await work(); XCTFail("it did not refuse", file: file, line: line); return "" } catch { return error.localizedDescription }
  }
}

final class PictureToolTests: ToolTestCase {
  func test_turns() async throws {
    let expected: [(String, [Quarters.Colour], Int)] = [
      ("rotate90", [.blue, .red, .white, .green], 200), ("rotate270", [.green, .white, .red, .blue], 200),
      ("rotate180", [.white, .blue, .green, .red], 320), ("mirror", [.green, .red, .white, .blue], 320),
      ("flip", [.blue, .white, .red, .green], 320),
    ]
    let source = path("a.png")
    try Quarters.image(at: source)
    for (word, colours, width) in expected {
      let made = try await run([word], on: source)[0]
      XCTAssertEqual(try Quarters.read(made), colours, word)
      XCTAssertEqual(try ProcessableFile(url: made).dimensions?.width, width, word)
    }
  }

  func test_crops() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let squared = try await run(["crop1x1"], on: source)[0]
    let square = try ProcessableFile(url: squared)
    XCTAssertEqual(square.dimensions, Dimensions(width: 200, height: 200))
    let stood = try await run(["crop9x16"], on: source)[0]
    let tall = try ProcessableFile(url: stood)
    XCTAssertEqual(tall.dimensions, Dimensions(width: 112, height: 200))
    let box = try await run(["crop160,0,160x100"], on: source)[0]
    XCTAssertEqual(try Quarters.read(box), [.green, .green, .green, .green])
    XCTAssertEqual(try ProcessableFile(url: box).dimensions, Dimensions(width: 160, height: 100))
    let said = await reason { _ = try await self.run(["crop900,900,10x10"], on: source) }
    XCTAssertTrue(said.contains("320 × 200"), said)
  }

  /// In the order they were asked: half of it and then turned is not turned
  /// and then half of it.
  func test_order() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let cropped = try await run(["crop0,0,160x200", "rotate90"], on: source)[0]
    XCTAssertEqual(try Quarters.read(cropped), [.blue, .red, .blue, .red])
  }

  func test_aCutOutIsSeeThrough() async throws {
    guard #available(macOS 14, *) else { throw XCTSkip("no mask") }
    // Something round on something plain.
    let source = path("ball_nobg.jpg")
    let context = CGContext(
      data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.85, green: 0.9, blue: 0.95, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
    context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 170, y: 170, width: 260, height: 260))
    let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)

    let made: [URL]
    do { made = try await run([], on: source, to: .jpeg) } catch {
      throw XCTSkip("this machine's Vision finds nothing in a drawing: \(error.localizedDescription)")
    }
    XCTAssertEqual(made[0].lastPathComponent, "ball.png", "a JPEG has nowhere to be see-through")
    XCTAssertEqual(try Quarters.read(made[0]), [.clear, .clear, .clear, .clear])
  }

  func test_aPictureHasNoSpeed() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let said = await reason { _ = try await self.run(["speed2x"], on: source) }
    XCTAssertEqual(said, "“Speed 2×” is not something done to images.")
  }
}

final class FilmToolTests: ToolTestCase {
  /// The fixture goes from black to white in its length.
  private func brightness(_ url: URL, at seconds: Double) throws -> Double {
    let image = try Quarters.frame(of: url, at: seconds)
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Double(bytes[0]) / 255
  }

  func test_aPart() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 4)
    let made = try await run(["trim1-3"], on: source)[0]
    let length = try await seconds(made)
    XCTAssertEqual(length, 2, accuracy: 0.1)
    XCTAssertEqual(try brightness(made, at: 0), 0.25, accuracy: 0.08)
    XCTAssertEqual(try brightness(made, at: 1.9), 0.72, accuracy: 0.08)
    let tracks = try await AVURLAsset(url: made).trackCounts()
    XCTAssertEqual(tracks.audio, 1)
    let open = try await run(["trim3-"], on: source)[0]
    let left = try await seconds(open)
    XCTAssertEqual(left, 1, accuracy: 0.1)
  }

  /// What was cut off is not in the file. Pictures before the cut kept only to
  /// decode the ones after it are hidden from a player and from nobody else.
  func test_whatIsCutOffIsGone() async throws {
    func pictures(_ url: URL) async throws -> Int {
      let asset = AVURLAsset(url: url)
      let track = try await asset.loadTracks(withMediaType: .video)[0]
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      reader.add(output)
      reader.startReading()
      var count = 0
      while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
      return count
    }
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 4)
    let made = try await run(["trim1.5-2"], on: source)[0]
    let there = try await pictures(made)
    XCTAssertLessThanOrEqual(there, 17, "half a second at thirty a second")
  }

  func test_evenVolumeOfNothing() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1, withAudio: false)
    let said = await reason { _ = try await self.run(["normalize"], on: source) }
    XCTAssertEqual(said, "a.mp4 has no sound to even out")
  }

  func test_aFastPartIsNotEncodedAgain() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 4)
    let made = try await run(["trim1-3fast"], on: source)[0]
    let length = try await seconds(made)
    XCTAssertEqual(length, 2, accuracy: 0.15)
    XCTAssertEqual(try brightness(made, at: 0), 0.25, accuracy: 0.08)
  }

  func test_aPartThatIsNotThere() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    let said = await reason { _ = try await self.run(["trim10-20"], on: source) }
    XCTAssertTrue(said.contains("a.mp4 is 0:01"), said)
  }

  func test_speed() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 4)
    let fast = try await run(["speed2x"], on: source)[0]
    let length = try await seconds(fast)
    XCTAssertEqual(length, 2, accuracy: 0.1)
    let tracks = try await AVURLAsset(url: fast).trackCounts()
    XCTAssertEqual(tracks.audio, 1, "its sound is sped up with it")
    let slow = try await run(["trim0-1", "speed0.5x"], on: source)[0]
    let slowed = try await seconds(slow)
    XCTAssertEqual(slowed, 2, accuracy: 0.1)
  }

  func test_mute() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 2)
    let made = try await run(["mute"], on: source)[0]
    let tracks = try await AVURLAsset(url: made).trackCounts()
    XCTAssertEqual(tracks.audio, 0)
    XCTAssertEqual(tracks.video, 1)
  }

  func test_loop() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 2)
    let made = try await run(["trim0-1", "loop3"], on: source)[0]
    let length = try await seconds(made)
    XCTAssertEqual(length, 3, accuracy: 0.15)
    XCTAssertEqual(try brightness(made, at: 1.1), 0.05, accuracy: 0.1, "the second time starts where the first did")
  }

  func test_backwards() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 3)
    let made = try await run(["reverse"], on: source)[0]
    let length = try await seconds(made)
    XCTAssertEqual(length, 3, accuracy: 0.1)
    XCTAssertGreaterThan(try brightness(made, at: 0.1), 0.85)
    XCTAssertEqual(try brightness(made, at: 1.5), 0.5, accuracy: 0.08)
    XCTAssertLessThan(try brightness(made, at: 2.8), 0.15)
    let tracks = try await AVURLAsset(url: made).trackCounts()
    XCTAssertEqual(tracks.audio, 1)
  }

  func test_shapes() async throws {
    let source = path("a.mp4")
    try await Quarters.film(at: source)
    let expected: [([String], [Quarters.Colour], CGSize)] = [
      (["rotate90"], [.blue, .red, .white, .green], CGSize(width: 200, height: 320)),
      (["rotate270"], [.green, .white, .red, .blue], CGSize(width: 200, height: 320)),
      (["rotate180"], [.white, .blue, .green, .red], CGSize(width: 320, height: 200)),
      (["mirror"], [.green, .red, .white, .blue], CGSize(width: 320, height: 200)),
      (["flip"], [.blue, .white, .red, .green], CGSize(width: 320, height: 200)),
      (["crop160,0,160x100"], [.green, .green, .green, .green], CGSize(width: 160, height: 100)),
      (["crop1x1"], [.red, .green, .blue, .white], CGSize(width: 200, height: 200)),
      (["crop0,0,160x200", "rotate90"], [.blue, .red, .blue, .red], CGSize(width: 200, height: 160)),
    ]
    for (words, colours, size) in expected {
      let made = try await run(words, on: source)[0]
      let frame = try Quarters.frame(of: made)
      XCTAssertEqual(Quarters.read(frame), colours, "\(words)")
      XCTAssertEqual(CGSize(width: frame.width, height: frame.height), size, "\(words)")
    }
  }

  func test_aTurnAndASize() async throws {
    let source = path("a.mp4")
    try await Quarters.film(at: source)
    let made = try await run([], on: source, more: [.tool(.turn(.right)), .resize(width: 100, height: nil, fitMode: .proportional)])[0]
    let frame = try Quarters.frame(of: made)
    XCTAssertEqual(CGSize(width: frame.width, height: frame.height), CGSize(width: 100, height: 160))
    XCTAssertEqual(Quarters.read(frame), [.blue, .red, .white, .green])
  }

  func test_aMovingPictureOfAPart() async throws {
    let source = path("a.mp4")
    try await Quarters.film(at: source)
    let made = try await run(["trim0-1", "crop160,0,160x100"], on: source, to: .gif)[0]
    XCTAssertEqual(try Quarters.read(made), [.green, .green, .green, .green])
    let count = CGImageSourceGetCount(CGImageSourceCreateWithURL(made as CFURL, nil)!)
    XCTAssertEqual(Double(count), 12, accuracy: 2)
  }

  func test_aFrameEvery() async throws {
    let source = try await Fixture.video(at: path("a_frames1s.mp4"), seconds: 4)
    let made = try await run([], on: source)
    XCTAssertEqual(made.count, 4)
    XCTAssertEqual(made[0].pathExtension, "jpeg")
    XCTAssertEqual(try ProcessableFile(url: made[0]).dimensions?.width, 640)
  }

  func test_parts() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 4)
    let made = try await run(["split4"], on: source)
    XCTAssertEqual(made.map(\.lastPathComponent), ["a_01.mp4", "a_02.mp4", "a_03.mp4", "a_04.mp4"])
    for url in made {
      let length = try await seconds(url)
      XCTAssertEqual(length, 1, accuracy: 0.12)
    }
    XCTAssertEqual(try brightness(made[2], at: 0), 0.5, accuracy: 0.08)
    let every = try await run(["trim0-3.5", "split1.5s"], on: source)
    XCTAssertEqual(every.count, 3)
    let last = try await seconds(every[2])
    XCTAssertEqual(last, 0.5, accuracy: 0.12)
    let said = await reason { _ = try await self.run(["split60s"], on: source) }
    XCTAssertTrue(said.contains("one part"), said)
  }

  func test_partsCannotReplaceOneFile() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 2)
    let said = await reason { _ = try await self.run(["split2"], on: source, mode: .overwrite) }
    XCTAssertTrue(said.contains("cannot replace the original"), said)
    XCTAssertTrue(exists(source))
  }

  /// Renamed, it becomes what its name says and is called what it was.
  func test_aWordInTheName() async throws {
    let source = try await Fixture.video(at: path("clip_mute_speed2x.mp4"), seconds: 4)
    let made = try await run([], on: source, mode: .overwrite)[0]
    XCTAssertEqual(made.lastPathComponent, "clip.mp4")
    XCTAssertFalse(exists(source), "or it would be done again the next time the folder is looked at")
    let length = try await seconds(made)
    XCTAssertEqual(length, 2, accuracy: 0.1)
    let tracks = try await AVURLAsset(url: made).trackCounts()
    XCTAssertEqual(tracks.audio, 0)
  }

  /// Its title, after its film has become another.
  func test_itsTagsAreKept() async throws {
    let source = path("a.mov")
    try await Fixture.taggedVideo(at: source, title: "Goose", artist: "Somebody")
    let made = try await run(["mute"], on: source, to: .quickTimeMovie)[0]
    let before = try await AVURLAsset(url: source).load(.metadata).compactMap(\.commonKey)
    let after = try await AVURLAsset(url: made).load(.metadata).compactMap(\.commonKey)
    XCTAssertFalse(before.isEmpty)
    XCTAssertTrue(Set(before).isSubset(of: Set(after)), "\(before) became \(after)")
  }
}

final class SoundToolTests: ToolTestCase {
  func test_aPartAndASpeed() async throws {
    let source = try Fixture.audio(at: path("a.wav"), seconds: 4)
    let part = try await run(["trim1-3"], on: source)[0]
    let length = try await seconds(part)
    XCTAssertEqual(length, 2, accuracy: 0.05)
    let format = try AVAudioFile(forReading: part).fileFormat
    XCTAssertEqual(format.settings[AVLinearPCMBitDepthKey] as? Int, 16, "as deep as it was")
    let fast = try await run(["speed2x"], on: source, to: .m4a)[0]
    let faster = try await seconds(fast)
    XCTAssertEqual(faster, 2, accuracy: 0.15)
  }

  /// Faster, and not higher.
  func test_thePitchStays() async throws {
    let source = try Fixture.audio(at: path("a.wav"), seconds: 4)
    let fast = try await run(["speed2x"], on: source)[0]
    let file = try AVAudioFile(forReading: fast)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let middle = samples[(samples.count / 4)..<(samples.count * 3 / 4)]
    let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
    let hertz = Double(crossings) / (Double(middle.count) / file.fileFormat.sampleRate)
    XCTAssertEqual(hertz, 440, accuracy: 12)
  }

  func test_backwardsTwiceIsForwards() async throws {
    let source = path("a.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    do {
      let file = try AVAudioFile(forWriting: source, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
      ])
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
      buffer.frameLength = 96_000
      for index in 0..<96_000 { buffer.floatChannelData![0][index] = Float(index) / 96_000 * 0.8 }
      try file.write(from: buffer)
    }
    func samples(_ url: URL) throws -> [Float] {
      let file = try AVAudioFile(forReading: url)
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
      try file.read(into: buffer)
      return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    let back = try samples(try await run(["reverse"], on: source)[0])
    XCTAssertEqual(back.count, 96_000)
    guard back.count == 96_000 else { return }
    XCTAssertGreaterThan(back[10], 0.79)
    XCTAssertLessThan(back[95_990], 0.01)
  }

  /// A quiet one and a loud one come out as loud as each other.
  func test_evenVolume() async throws {
    var levels: [Double] = []
    for (name, gain) in [("quiet", Float(0.02)), ("loud", Float(0.6))] {
      let source = path("\(name).wav")
      do {
        let file = try AVAudioFile(forWriting: source, settings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 144_000)!
        buffer.frameLength = 144_000
        for index in 0..<144_000 { buffer.floatChannelData![0][index] = Float(sin(2 * Double.pi * 997 * Double(index) / 48_000)) * gain }
        try file.write(from: buffer)
      }
      let made = try await run(["normalize"], on: source)[0]
      levels.append(try Loudness.measure(try AVAudioFile(forReading: made)).loudness)
    }
    XCTAssertEqual(levels[0], Loudness.target, accuracy: 0.5)
    XCTAssertEqual(levels[1], Loudness.target, accuracy: 0.5)
  }

  /// The measure's own yardstick: a full-scale 997 Hz sine in one channel is
  /// −3.01 LKFS.
  func test_theMeasureIsTheStandards() throws {
    let source = path("a.wav")
    do {
      let file = try AVAudioFile(forWriting: source, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
      ])
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 240_000)!
      buffer.frameLength = 240_000
      for index in 0..<240_000 { buffer.floatChannelData![0][index] = Float(sin(2 * Double.pi * 997 * Double(index) / 48_000)) * 0.9999 }
      try file.write(from: buffer)
    }
    XCTAssertEqual(try Loudness.measure(try AVAudioFile(forReading: source)).loudness, -3.01, accuracy: 0.1)
  }

  func test_aSoundtrackOfAPart() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 4)
    let made = try await run(["trim1-3"], on: source, to: .m4a)[0]
    let length = try await seconds(made)
    XCTAssertEqual(length, 2, accuracy: 0.15)
  }

  func test_parts() async throws {
    let source = try Fixture.audio(at: path("a.wav"), seconds: 3)
    let made = try await run(["split1s"], on: source)
    XCTAssertEqual(made.count, 3)
  }
}

/// The same tools where the work is ffmpeg's.
final class ToolFFmpegTests: ToolTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil, "ffmpeg is not here")
  }

  private func probe(_ url: URL, _ what: [String]) throws -> String {
    let process = Process()
    process.executableURL = try XCTUnwrap(ExternalTools.locate("ffprobe"))
    process.arguments = ["-v", "error"] + what + ["-of", "csv=p=0", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let said = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func test_aMatroskaFilm() async throws {
    let mp4 = try await Fixture.video(at: path("a.mp4"), seconds: 4)
    let mkv = try XCTUnwrap(UTType(filenameExtension: "mkv"))
    let made = try await run(["trim1-3", "speed2x", "mute", "rotate90"], on: mp4, to: mkv)[0]
    XCTAssertEqual(try XCTUnwrap(Double(probe(made, ["-show_entries", "format=duration"]))), 1, accuracy: 0.15)
    XCTAssertEqual(try probe(made, ["-show_entries", "stream=codec_type"]), "video")
    XCTAssertEqual(try probe(made, ["-show_entries", "stream=width,height"]), "360,640")
    let parts = try await run(["split2"], on: made)
    XCTAssertEqual(parts.count, 2)
  }

  func test_anMP3() async throws {
    let wav = try Fixture.audio(at: path("a.wav"), seconds: 4)
    let made = try await run(["trim1-3", "speed0.25x", "normalize"], on: wav, to: .mp3)[0]
    XCTAssertEqual(try XCTUnwrap(Double(probe(made, ["-show_entries", "format=duration"]))), 8, accuracy: 0.3)
    XCTAssertEqual(try probe(made, ["-show_entries", "stream=sample_rate"]), "48000")
  }

  func test_filmSettingsAndTools() async throws {
    let source = path("a.mp4")
    try await Quarters.film(at: source)
    let made = try await run(["crop160,0,160x100", "trim0-1"], on: source, to: .mpeg4Movie, more: [.film(FilmSettings())])[0]
    let frame = try Quarters.frame(of: made)
    XCTAssertEqual(Quarters.read(frame), [.green, .green, .green, .green])
    let length = try await seconds(made)
    XCTAssertEqual(length, 1, accuracy: 0.15)
  }

  func test_turnsAreTheSameTurns() async throws {
    let source = path("a.mp4")
    try await Quarters.film(at: source)
    for (word, colours) in [("rotate90", [Quarters.Colour.blue, .red, .white, .green]), ("rotate270", [.green, .white, .red, .blue]), ("flip", [.blue, .white, .red, .green]), ("crop1x1", [.red, .green, .blue, .white])] {
      let made = try await run([word], on: source, to: .mpeg4Movie, more: [.film(FilmSettings())])[0]
      XCTAssertEqual(Quarters.read(try Quarters.frame(of: made)), colours, word)
    }
  }
}

final class PDFToolTests: ToolTestCase {
  /// Pages that say which they are.
  private func document(_ name: String, pages: Int) throws -> URL {
    let url = path(name)
    var box = CGRect(x: 0, y: 0, width: 400, height: 600)
    let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
    for page in 1...pages {
      context.beginPDFPage(nil)
      let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: "Page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 40)]
      ))
      context.textPosition = CGPoint(x: 100, y: 500)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  private func texts(_ url: URL) throws -> [String] {
    let pdf = try XCTUnwrap(PDFDocument(url: url))
    return (0..<pdf.pageCount).map { pdf.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
  }

  func test_pages() async throws {
    let source = try document("a.pdf", pages: 6)
    let expected = [("pages2-4", [2, 3, 4]), ("pages3,1", [3, 1]), ("pages6-5,5", [6, 5, 5]), ("nopages2-5", [1, 6])]
    for (word, pages) in expected {
      let made = try await run([word], on: source)[0]
      XCTAssertEqual(try texts(made), pages.map { "Page \($0)" }, word)
    }
    XCTAssertEqual(try texts(source).count, 6, "the one it was made of is as it was")
    let said = await reason { _ = try await self.run(["pages9"], on: source) }
    XCTAssertTrue(said.contains("6 pages"), said)
  }

  func test_dividing() async throws {
    let source = try document("a.pdf", pages: 5)
    let single = try await run(["splitpages"], on: source)
    XCTAssertEqual(single.map(\.lastPathComponent), ["a_01.pdf", "a_02.pdf", "a_03.pdf", "a_04.pdf", "a_05.pdf"])
    XCTAssertEqual(try texts(single[3]), ["Page 4"])
    let pairs = try await run(["split2pages"], on: source)
    XCTAssertEqual(try pairs.map { try texts($0).count }, [2, 2, 1])
    let some = try await run(["pages5,4,3", "split2pages"], on: source)
    XCTAssertEqual(try some.map { try texts($0) }, [["Page 5", "Page 4"], ["Page 3"]])
  }

  func test_turnedAndCropped() async throws {
    let source = try document("a.pdf", pages: 2)
    func made(_ words: [String]) async throws -> PDFDocument {
      let url = try await run(words, on: source)[0]
      return try XCTUnwrap(PDFDocument(url: url))
    }
    let turned = try await made(["rotate90"])
    XCTAssertEqual(turned.page(at: 1)?.rotation, 90)
    XCTAssertTrue(turned.string?.contains("Page 2") ?? false, "its words are words")
    let cropped = try await made(["crop1x1"])
    XCTAssertEqual(cropped.page(at: 0)?.bounds(for: .cropBox), CGRect(x: 0, y: 100, width: 400, height: 400))
    // The top left of the page as it is seen, once it lies on its side.
    let both = try await made(["rotate90", "crop0,0,300x200"])
    XCTAssertEqual(both.page(at: 0)?.bounds(for: .cropBox), CGRect(x: 0, y: 0, width: 200, height: 300))
  }

  func test_picturesOfSomePages() async throws {
    let source = try document("a.pdf", pages: 5)
    let made = try await run(["pages2-3", "crop0,0,400x300"], on: source, to: .png)
    XCTAssertEqual(made.count, 2)
    XCTAssertEqual(try ProcessableFile(url: made[0]).dimensions, Dimensions(width: 800, height: 600))
  }

  func test_wordsOfSomePages() async throws {
    let source = try document("a.pdf", pages: 5)
    let made = try await run(["pages2"], on: source, to: .plainText)[0]
    XCTAssertEqual(try String(contentsOf: made, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "Page 2")
  }

  func test_aNameWithPages() async throws {
    let source = try document("thesis_pages2-3.pdf", pages: 5)
    let made = try await run([], on: source)[0]
    XCTAssertEqual(made.lastPathComponent, "thesis.pdf")
    XCTAssertEqual(try texts(made), ["Page 2", "Page 3"])
  }

  func test_aSignedDocumentIsLeftAlone() async throws {
    let source = try document("contract.pdf", pages: 2)
    let handle = try FileHandle(forWritingTo: source)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n% /ByteRange [0 10 20 30]\n".utf8))
    try handle.close()
    for word in ["pages1", "rotate90", "lighter"] {
      let said = await reason { _ = try await self.run([word], on: source) }
      XCTAssertTrue(said.contains("contract.pdf is signed"), said)
    }
    let pictures = try await run(["pages2"], on: source, to: .png)
    XCTAssertEqual(pictures.count, 1, "a picture of a page undoes nothing")
  }

  func test_aPageIsNotMirrored() async throws {
    let source = try document("a.pdf", pages: 1)
    let said = await reason { _ = try await self.run(["mirror"], on: source) }
    XCTAssertEqual(said, "“Mirror” is not something done to PDFs.")
  }
}

final class LighterToolTests: ToolTestCase {
  /// A page with a scan on it, words over the scan, and a link to the second.
  private func scan(_ name: String) throws -> URL {
    let url = path(name)
    let noise = path("noise.png")
    try Fixture.noise(at: noise, width: 1200, height: 1600)
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(noise as CFURL, nil))
    let picture = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
    for page in 1...2 {
      context.beginPDFPage(nil)
      context.draw(picture, in: box)
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 30)]))
      context.textPosition = CGPoint(x: 50, y: 300)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    CGPDFContextSetOutline(context, ["Children": [["Title": "Second", "Destination": 2] as [String: Any]]] as CFDictionary)
    context.closePDF()
    let pdf = try XCTUnwrap(PDFDocument(url: url))
    let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
    link.action = PDFActionGoTo(destination: PDFDestination(page: pdf.page(at: 1)!, at: .zero))
    pdf.page(at: 0)?.addAnnotation(link)
    pdf.page(at: 1)?.rotation = 90
    pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Scan"]
    XCTAssertTrue(pdf.write(to: url))
    return url
  }

  func test_aScanIsLighterAndStillADocument() async throws {
    let source = try scan("scan_lighter.pdf")
    XCTAssertEqual(PDFDocument(url: source)?.outlineRoot?.child(at: 0)?.label, "Second", "what it is made of")
    let made = try await run([], on: source)[0]
    XCTAssertEqual(made.lastPathComponent, "scan.pdf")
    XCTAssertLessThan(size(of: made), size(of: source) / 2)
    let pdf = try XCTUnwrap(PDFDocument(url: made))
    XCTAssertTrue(pdf.string?.contains("Page 2") ?? false, "its words are words")
    XCTAssertEqual(pdf.page(at: 1)?.rotation, 90)
    XCTAssertEqual(pdf.outlineRoot?.child(at: 0)?.label, "Second")
    XCTAssertEqual(pdf.outlineRoot?.child(at: 0)?.destination?.page.map { pdf.index(for: $0) }, 1)
    XCTAssertEqual(pdf.page(at: 0)?.annotations.count, 1)
    XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Scan")
  }

  func test_aPDFUnderASize() async throws {
    let source = try scan("scan.pdf")
    let ceiling = Int(size(of: source)) / 4
    let made = try await run([], on: source, more: [.limitSize(bytes: ceiling)])[0]
    XCTAssertLessThanOrEqual(size(of: made), Int64(ceiling))
    let said = await reason { _ = try await self.run([], on: source, more: [.limitSize(bytes: 900)]) }
    XCTAssertTrue(said.contains("smallest"), said)
  }

  func test_whatIsLightAlreadyIsLeftAlone() async throws {
    let source = path("a.pdf")
    try Fixture.pdf(at: source, pages: 1)
    let said = await reason { _ = try await self.run(["lighter"], on: source) }
    XCTAssertEqual(said, Lighter.notLighter)
  }

  func test_aPictureMadeLighter() async throws {
    let source = path("a.png")
    try Fixture.noise(at: source, width: 800, height: 600)
    let made = try await run(["lighter"], on: source)[0]
    XCTAssertEqual(made.pathExtension, "jpeg")
    XCTAssertLessThan(size(of: made), size(of: source))
  }

  func test_pagesAndLighter() async throws {
    let source = try scan("scan.pdf")
    let made = try await run(["pages2", "lighter"], on: source)[0]
    XCTAssertEqual(PDFDocument(url: made)?.pageCount, 1)
    XCTAssertLessThan(size(of: made), size(of: source) / 2)
  }
}
