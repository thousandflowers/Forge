import XCTest
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers
@testable import Forge

final class MoreWordTests: XCTestCase {
  func test_words() {
    let words: [(String, Tool)] = [
      ("sync250ms", .sync(250)), ("sync-40ms", .sync(-40)), ("brightness+20", .adjust(.brightness, 20)),
      ("contrast-10", .adjust(.contrast, -10)), ("saturation+100", .adjust(.saturation, 100)), ("blur5", .adjust(.blur, 5)),
      ("border40", .border(40)), ("border8black", .border(8, isBlack: true)), ("mark(© Goose 2026)", .mark("© Goose 2026")),
      ("sha256", .digest(.sha256)), ("base64", .digest(.base64)),
    ]
    for (word, tool) in words {
      XCTAssertEqual(Tool(word: word), tool, word)
      XCTAssertEqual(tool.word, word)
    }
    for word in ["sync0ms", "brightness20", "brightness+101", "blur0", "border0", "mark()", "contrast"] { XCTAssertNil(Tool(word: word), word) }
  }

  func test_everyKindOfToolHasAWordThatMakesIt() {
    for kind in Tool.Kind.allCases {
      XCTAssertEqual(Tool(word: kind.blank.word), kind.blank, kind.rawValue)
      XCTAssertEqual(kind.blank.kind, kind)
    }
  }
}

final class MorePictureToolTests: ToolTestCase {
  private func colour(_ url: URL, _ x: Double, _ y: Double) throws -> [Int] {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
      data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let at = (Int(Double(image.height - 1) * y) * image.width + Int(Double(image.width - 1) * x)) * 4
    return bytes[at..<(at + 3)].map(Int.init)
  }

  private func grey(_ url: URL, _ level: CGFloat) throws {
    let context = CGContext(
      data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: level, green: level, blue: level, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  func test_aBorder() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let made = try await run(["border40"], on: source)[0]
    XCTAssertEqual(try ProcessableFile(url: made).dimensions, Dimensions(width: 400, height: 280))
    XCTAssertEqual(try colour(made, 0.5, 0.02), [255, 255, 255])
    let black = try await run(["border40black"], on: source)[0]
    XCTAssertEqual(try colour(black, 0.01, 0.5), [0, 0, 0])
    XCTAssertEqual(try colour(black, 0.3, 0.3)[0], 255, "and the picture in it")
  }

  func test_adjustments() async throws {
    let source = path("a.png")
    try grey(source, 0.5)
    let brighter = try await run(["brightness+50"], on: source)[0]
    XCTAssertGreaterThan(try colour(brighter, 0.5, 0.5)[0], 150)
    let darker = try await run(["brightness-50"], on: source)[0]
    XCTAssertLessThan(try colour(darker, 0.5, 0.5)[0], 110)
    let colours = path("b.png")
    try Quarters.image(at: colours)
    let none = try await run(["saturation-100"], on: colours)[0]
    let red = try colour(none, 0.2, 0.2)
    XCTAssertLessThan((red.max() ?? 0) - (red.min() ?? 0), 4, "\(red)")
    let blurred = try await run(["blur20"], on: colours)[0]
    XCTAssertEqual(try ProcessableFile(url: blurred).dimensions, Dimensions(width: 320, height: 200))
    let middle = try colour(blurred, 0.5, 0.2)
    XCTAssertTrue(middle[0] > 40 && middle[1] > 40, "red and green run together: \(middle)")
  }

  func test_twoAdjustmentsAreTwoSteps() {
    XCTAssertEqual([Forge.Operation]().adding(.adjust(.brightness, 10)).adding(.adjust(.contrast, 5)).count, 2)
    XCTAssertEqual([Forge.Operation]().adding(.adjust(.brightness, 10)).adding(.adjust(.brightness, 5)), [.tool(.adjust(.brightness, 5))])
  }

  func test_aWatermark() async throws {
    for level in [CGFloat(0), 1] {
      let source = path("g\(Int(level)).png")
      try grey(source, level)
      let made = try await run(["mark(FORGE)"], on: source)[0]
      var different = 0
      for x in stride(from: 0.6, to: 1.0, by: 0.005) { for y in stride(from: 0.85, to: 1.0, by: 0.005) where abs(try colour(made, x, y)[0] - Int(level * 255)) > 20 { different += 1 } }
      XCTAssertGreaterThan(different, 15, "it cannot be read on \(level == 0 ? "black" : "white")")
      XCTAssertEqual(try colour(made, 0.1, 0.1)[0], Int(level * 255), "and only in the corner")
    }
  }
}

final class DigestTests: ToolTestCase {
  func test_sha256() async throws {
    let source = path("a.txt")
    try Data("goose".utf8).write(to: source)
    let made = try await run(["sha256"], on: source)[0]
    XCTAssertEqual(made.pathExtension, "txt")
    let expected = SHA256.hash(data: Data("goose".utf8)).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(try String(contentsOf: made, encoding: .utf8), "\(expected)  a.txt\n")
  }

  func test_base64InPiecesIsBase64() async throws {
    let source = path("a.png")
    try Fixture.noise(at: source, width: 900, height: 700)
    XCTAssertGreaterThan(size(of: source), 3 << 18, "or it is all one piece")
    let made = try await run(["base64"], on: source)[0]
    XCTAssertEqual(Data(base64Encoded: try Data(contentsOf: made)), try Data(contentsOf: source))
  }
}

final class ArchiveTests: ToolTestCase {
  private func archive(_ name: String, _ arguments: [String]) throws -> URL {
    let folder = try folder("in")
    try Data("goose".utf8).write(to: folder.appendingPathComponent("a.txt"))
    try Data(count: 5000).write(to: folder.appendingPathComponent("b.bin"))
    let url = path(name)
    try ExternalTools.run(ArchiveProcessor.tool, ["-c"] + arguments + ["-f", url.path, "-C", folder.path, "a.txt", "b.bin"])
    return url
  }

  private func names(_ url: URL) throws -> [String] {
    let process = Process()
    process.executableURL = ArchiveProcessor.tool
    process.arguments = ["-tf", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let said = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: said, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
  }

  func test_fromOneToAnother() async throws {
    for (name, arguments) in [("a.7z", ["--format", "7zip"]), ("a.tar", ["--format", "pax"]), ("a.tgz", ["-z"])] {
      let source = try archive(name, arguments)
      XCTAssertEqual(ConvertKind(fileType: try ProcessableFile(url: source).fileType), .archive, name)
      let made = try await run([], on: source, to: .zip)[0]
      XCTAssertEqual(try names(made), ["a.txt", "b.bin"], name)
    }
    let zip = try archive("b.zip", ["--format", "zip"])
    let seven = try await run([], on: zip, to: UTType(filenameExtension: "7z")!)[0]
    XCTAssertEqual(try names(seven), ["a.txt", "b.bin"])
  }

  func test_whatIsOffered() throws {
    let source = try ProcessableFile(url: try archive("a.7z", ["--format", "7zip"]))
    let offered = ConvertKind.archive.outputGroups(for: [source]).flatMap(\.formats).compactMap(\.type)
    XCTAssertTrue(offered.contains(.zip))
    XCTAssertFalse(offered.contains(source.fileType))
    XCTAssertFalse(Conversions.can(source, become: .png))
  }

  func test_aDamagedOne() async throws {
    let source = path("a.7z")
    try Data("not an archive".utf8).write(to: source)
    let said = await reason { _ = try await self.run([], on: source, to: .zip) }
    XCTAssertTrue(said.contains("a.7z cannot be read"), said)
  }
}

final class MoreSoundToolTests: ToolTestCase {
  func test_aRingtone() async throws {
    let source = try Fixture.audio(at: path("a.wav"), seconds: 3)
    let type = try XCTUnwrap(UTType(filenameExtension: "m4r"))
    let made = try await run(["trim0-2"], on: source, to: type)[0]
    XCTAssertEqual(made.pathExtension, "m4r")
    let length = try await seconds(made)
    XCTAssertEqual(length, 2, accuracy: 0.15)
  }

  /// A film whose sound begins a second in, moved about.
  func test_movingTheSound() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 3)
    func loudFrom(_ url: URL) async throws -> Double {
      let folder = try self.folder("s-\(UUID().uuidString)")
      let sound = try await MediaRender.firstSound(of: AVURLAsset(url: url), like: url, in: folder)
      let file = try AVAudioFile(forReading: try XCTUnwrap(sound))
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
      try file.read(into: buffer)
      let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
      let first = samples.firstIndex { abs($0) > 0.05 } ?? samples.count
      return Double(first) / file.processingFormat.sampleRate
    }
    let later = try await run(["sync1000ms"], on: source)[0]
    let starts = try await loudFrom(later)
    XCTAssertEqual(starts, 1, accuracy: 0.1)
    let length = try await seconds(later)
    XCTAssertEqual(length, 3, accuracy: 0.15)
    let earlier = try await run(["sync-1000ms"], on: later)[0]
    let again = try await loudFrom(earlier)
    XCTAssertLessThan(again, 0.1)
  }
}

final class FilmAndSomethingTests: ToolTestCase {
  func test_anotherSound() async throws {
    let film = try await Fixture.video(at: path("film.mp4"), seconds: 2, withAudio: false)
    let sound = try Fixture.audio(at: path("voice.wav"), seconds: 5)
    let files = [try ProcessableFile(url: sound), try ProcessableFile(url: film)]
    XCTAssertEqual(Joiner.kinds(for: files), [.dubbed])
    XCTAssertEqual(AskOptions.choices(for: .join, files: files).map(\.label), ["Film with this sound"])
    let made = try await coordinator().join(files, as: .dubbed, into: path("out"))
    XCTAssertEqual(made.lastPathComponent, "film joined.mp4")
    let tracks = try await AVURLAsset(url: made).trackCounts()
    XCTAssertEqual([tracks.video, tracks.audio], [1, 1])
    let length = try await seconds(made)
    XCTAssertEqual(length, 2, accuracy: 0.15, "no longer than its picture")
  }

  func test_subtitles() async throws {
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil, "ffmpeg is not here")
    let film = try await Fixture.video(at: path("film.mp4"), seconds: 2)
    let words = path("film.srt")
    try "1\n00:00:00,200 --> 00:00:01,000\nHonk\n".write(to: words, atomically: true, encoding: .utf8)
    let files = [try ProcessableFile(url: film), try ProcessableFile(url: words)]
    XCTAssertEqual(Joiner.kinds(for: files), [.subtitled, .burned])
    let made = try await coordinator().join(files, as: .subtitled, into: path("out"))
    let found = try await AVURLAsset(url: made).loadTracks(withMediaType: .subtitle)
    XCTAssertEqual(found.count, 1)
  }
}

final class MoreFilmSettingsTests: ToolTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil, "ffmpeg is not here")
  }

  func test_twoPasses() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    for encoder in [FilmSettings.Encoder.h264, .hevc, .vp9] {
      var film = FilmSettings()
      film.encoder = encoder
      film.rate = .kilobits(300)
      film.isTwoPass = true
      XCTAssertEqual(film.passes, 2)
      let made = try await run([], on: source, to: .mpeg4Movie, more: [.film(film)])[0]
      XCTAssertGreaterThan(size(of: made), 0, encoder.title)
      let left = try FileManager.default.contentsOfDirectory(atPath: made.deletingLastPathComponent().path)
      XCTAssertEqual(left, [made.lastPathComponent], "what the passes wrote down is gone")
    }
    var quality = FilmSettings()
    quality.isTwoPass = true
    XCTAssertEqual(quality.passes, 1, "a quality is the same in one")
  }

  /// A LUT that makes everything blue, in a folder ffmpeg would trip over.
  func test_aLUT() async throws {
    let folder = try folder("it's: a folder")
    let lut = folder.appendingPathComponent("blue.cube")
    let rows = (0..<8).map { _ in "0 0 1" }.joined(separator: "\n")
    try "LUT_3D_SIZE 2\n\(rows)\n".write(to: lut, atomically: true, encoding: .utf8)
    let source = path("a.mp4")
    try await Quarters.film(at: source)
    var film = FilmSettings()
    film.lut = lut.path
    let made = try await run([], on: source, to: .mpeg4Movie, more: [.film(film)])[0]
    XCTAssertEqual(Quarters.read(try Quarters.frame(of: made)), [.blue, .blue, .blue, .blue])
    film.lut = "/nowhere/gone.cube"
    let said = await reason { _ = try await self.run([], on: source, to: .mpeg4Movie, more: [.film(film)]) }
    XCTAssertTrue(said.contains("gone.cube"), said)
  }

  func test_oldSettingsAreRead() throws {
    let old = try JSONDecoder().decode(FilmSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(old, FilmSettings())
  }
}

final class NamedWithoutAPresetTests: XCTestCase {
  private let web = RulePreset(name: "Web", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])

  /// The folder's own preset is for pictures, and the name says what it wants.
  func test_aNameNeedsNoPreset() {
    for folder in [nil, web] {
      guard case .run(let preset) = Arrival.of(URL(fileURLWithPath: "/tmp/clip_mute.mp4"), folderPreset: folder, presets: [web], onlyWhenRenamed: true) else {
        return XCTFail("left alone")
      }
      XCTAssertEqual(preset.actions, [])
    }
    XCTAssertEqual(Arrival.of(URL(fileURLWithPath: "/tmp/clip.mp4"), folderPreset: web, presets: [web], onlyWhenRenamed: false), .leave)
  }
}

final class TraceTests: ToolTestCase {
  func test_aPictureAsOutlines() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let made = try await run([], on: source, to: .svg)[0]
    let text = try String(contentsOf: made, encoding: .utf8)
    XCTAssertTrue(text.contains("<path"), text)
    XCTAssertEqual(made.pathExtension, "svg")
  }
}
