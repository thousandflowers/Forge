import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Forge

final class NewWordTests: XCTestCase {
  func test_wordsSayWhatTheyAre() {
    let words: [(String, Tool)] = [
      ("enhance", .enhance), ("upscale2x", .upscale(2)), ("scan", .scan), ("gray", .gray), ("blurbg", .blurBackground), ("round40", .round(40)),
      ("grid3x3", .tile(3, 3)), ("layers", .layers), ("slowmo2x", .slowMotion(2)), ("at10s", .still(at: 10)), ("fps30", .rate(30)),
      ("480p", .lines(480)), ("4k", .lines(2160)), ("voice", .voice), ("mono", .mono), ("fade2s", .fade(2)), ("pitch+2", .pitch(2)),
      ("pitch-3", .pitch(-3)), ("nosilence", .noSilence), ("askpassword", .lock), ("unlock", .unlock), ("numbers", .numbers),
      ("2up", .sheet(2)), ("4up", .sheet(4)), ("dpi300", .dpi(300)), ("images", .pictures), ("tables", .tables),
      ("min", .tidy(.min)), ("pretty", .tidy(.pretty)), ("crop2,1of3x3", .crop(.cell(column: 2, row: 1, across: 3, down: 3))),
    ]
    for (word, tool) in words {
      XCTAssertEqual(Tool(word: word), tool, word)
      XCTAssertEqual(tool.word, word)
      XCTAssertEqual(tool.readable, tool, word)
      XCTAssertFalse(tool.title.isEmpty)
    }
    XCTAssertEqual(Tool(word: "at1m20"), .still(at: 80))
    for word in ["upscale9x", "round2", "grid1x1", "grid0x3", "slowmo1x", "at10", "fps0", "fps999", "99p", "fade0s", "pitch2", "pitch+0", "pitch+30",
                 "3up", "dpi5", "crop4,1of3x3", "crop0,1of3x3"] {
      XCTAssertNil(Tool(word: word), word)
    }
  }

  func test_aWordForAnotherKindOfFileIsAName() {
    func tools(_ name: String) -> [Tool] { NameTokens.read(name).tools }
    XCTAssertEqual(tools("song_scan.mp3"), [])
    XCTAssertEqual(tools("photo_1080p.jpg"), [])
    XCTAssertEqual(tools("photo_layers.jpg"), [])
    XCTAssertEqual(tools("photo_numbers.jpg"), [])
    XCTAssertEqual(tools("notes_min.txt"), [])
    XCTAssertEqual(tools("poster_layers.psd"), [.layers])
    XCTAssertEqual(tools("data_min.json"), [.tidy(.min)])
    XCTAssertEqual(tools("site_pretty.css"), [.tidy(.pretty)])
    XCTAssertEqual(tools("film_gray.mov"), [.gray])
    XCTAssertEqual(tools("page_tables.jpg"), [.tables])
  }

  func test_whatTheyComeOutAs() {
    func format(_ name: String) -> UTType? {
      NameTokens.applying(to: [], from: name).compactMap { if case .convertFormat(let to) = $0 { return to } else { return nil } }.first
    }
    XCTAssertEqual(format("clip_nobg.mp4"), .quickTimeMovie)
    XCTAssertEqual(format("photo_nobg.jpg"), .png)
    XCTAssertEqual(format("photo_round40.jpg"), .png)
    XCTAssertEqual(format("clip_at10s.mp4"), .jpeg)
    XCTAssertEqual(format("doc_dpi300.pdf"), .jpeg)
    XCTAssertEqual(format("doc_tables.pdf"), UTType(filenameExtension: "xlsx"))
    XCTAssertNil(format("doc_numbers.pdf"))
  }

  /// `a.pdf` renamed `a_tables.csv`, which is nothing a PDF becomes otherwise.
  func test_aWordAndAnotherExtensionAtOnce() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("forge-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func job(_ name: String) throws -> Retype? {
      let url = folder.appendingPathComponent(name)
      try Fixture.pdf(at: url, pages: 1)
      return Retype.wanted(of: url, before: "a.pdf")
    }
    XCTAssertEqual(try job("a_tables.csv")?.preset.readsTools, true)
    XCTAssertEqual(try job("a_dpi300.jpg")?.preset.readsTools, true)
    XCTAssertNil(try job("a.csv"))
  }

  /// The password is asked for, and nothing that is kept says it.
  func test_aPasswordIsNowhereInTheStep() throws {
    XCTAssertTrue(Tool.lock.asksAPassword && Tool.unlock.asksAPassword)
    XCTAssertEqual([Forge.Operation.split([Branch(name: "a", actions: [.tool(.lock)])])].everyTool, [.lock])
  }
}

final class NewPictureWordTests: ToolTestCase {
  private func pixel(_ url: URL, _ x: Double, _ y: Double) throws -> [Int] {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(CGContext(
      data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let at = (Int(Double(image.height - 1) * y) * image.width + Int(Double(image.width - 1) * x)) * 4
    return bytes[at..<(at + 4)].map(Int.init)
  }

  func test_gray() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let made = try await run(["gray"], on: source)[0]
    for (x, y) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8)] {
      let colour = try pixel(made, x, y)
      XCTAssertLessThanOrEqual(abs(colour[0] - colour[1]) + abs(colour[1] - colour[2]), 4, "\(colour)")
    }
  }

  func test_enlarging() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let made = try await run(["upscale3x"], on: source)[0]
    XCTAssertEqual(try ProcessableFile(url: made).dimensions, Dimensions(width: 960, height: 600))
    XCTAssertEqual(try Quarters.read(made), try Quarters.read(source))
  }

  func test_roundCornersAreSeenThrough() async throws {
    let source = path("a.jpg")
    try Fixture.image(at: source)
    let made = try await run(["round40"], on: source)[0]
    XCTAssertEqual(made.pathExtension, "png")
    XCTAssertEqual(try pixel(made, 0, 0)[3], 0)
    XCTAssertEqual(try pixel(made, 0.5, 0.5)[3], 255)
    XCTAssertEqual(try pixel(made, 0.5, 0)[3], 255)
  }

  func test_roundCornersOnWhiteWhereNothingIsSeenThrough() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let made = try await run(["round40"], on: source, to: .jpeg)[0]
    XCTAssertGreaterThan(try pixel(made, 0, 0).min() ?? 0, 240)
  }

  /// Not a row of pixels lost, whatever does not divide.
  func test_tilesAreAllOfIt() async throws {
    let source = path("a.png")
    try Fixture.image(at: source, width: 320, height: 200)
    let made = try await run(["grid3x3"], on: source)
    XCTAssertEqual(made.count, 9)
    let sizes = try made.map { try XCTUnwrap(ProcessableFile(url: $0).dimensions) }
    XCTAssertEqual(sizes[0].width + sizes[1].width + sizes[2].width, 320)
    XCTAssertEqual(sizes[0].height + sizes[3].height + sizes[6].height, 200)
    XCTAssertEqual(made.map { $0.deletingPathExtension().lastPathComponent }.first, "a_01")
  }

  func test_aSheetOfPaperIsStraightened() async throws {
    let source = path("a.png")
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 1200, height: 1200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.25, green: 0.15, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.addLines(between: [CGPoint(x: 260, y: 250), CGPoint(x: 820, y: 160), CGPoint(x: 900, y: 960), CGPoint(x: 340, y: 1050)])
    context.fillPath()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let made = try await run(["scan"], on: source)[0]
    for (x, y) in [(0.03, 0.03), (0.97, 0.03), (0.03, 0.97), (0.97, 0.97)] {
      XCTAssertGreaterThan(try pixel(made, x, y)[2], 200, "paper at every corner")
    }
  }

  func test_noSheetNoScan() async throws {
    let source = path("a.png")
    try Fixture.noise(at: source, width: 400, height: 400)
    let said = await reason { _ = try await self.run(["scan"], on: source) }
    XCTAssertTrue(said.contains("sheet of paper"), said)
  }

  // MARK: - Layers

  /// 8 x 4, two layers: one the size of it, and a smaller one half see-through.
  private func psd(_ way: Int) -> Data {
    func big(_ value: Int, _ size: Int) -> Data { Data((0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    func plane(_ value: UInt8, _ width: Int, _ height: Int) -> Data {
      if way == 0 { return big(0, 2) + Data(repeating: value, count: width * height) }
      var rows = big(1, 2)
      for _ in 0..<height { rows += big(2, 2) }
      for _ in 0..<height { rows += Data([UInt8(bitPattern: Int8(1 - width)), value]) }
      return rows
    }
    struct Layer { let box: [Int]; let name: String; let planes: [(Int, Data)] }
    let layers = [
      Layer(box: [0, 0, 4, 8], name: "Back", planes: [(0, plane(255, 8, 4)), (1, plane(0, 8, 4)), (2, plane(0, 8, 4))]),
      Layer(box: [1, 2, 3, 6], name: "a/b", planes: [(-1, plane(128, 4, 2)), (0, plane(0, 4, 2)), (1, plane(0, 4, 2)), (2, plane(255, 4, 2))]),
    ]
    var info = big(2, 2)
    for layer in layers {
      layer.box.forEach { info += big($0, 4) }
      info += big(layer.planes.count, 2)
      for (id, data) in layer.planes { info += big(id, 2) + big(data.count, 4) }
      var name = Data([UInt8(layer.name.utf8.count)]) + Data(layer.name.utf8)
      while name.count % 4 != 0 { name.append(0) }
      info += Data("8BIMnorm".utf8) + Data([255, 0, 0, 0]) + big(8 + name.count, 4) + big(0, 4) + big(0, 4) + name
    }
    for layer in layers { layer.planes.forEach { info += $0.1 } }
    if info.count % 2 == 1 { info.append(0) }
    let head = Data("8BPS".utf8) + big(1, 2) + Data(count: 6) + big(3, 2) + big(4, 4) + big(8, 4) + big(8, 2) + big(3, 2) + big(0, 4) + big(0, 4)
    return head + big(info.count + 8, 4) + big(info.count, 4) + info + big(0, 4) + big(0, 2) + Data(repeating: 0, count: 96)
  }

  func test_layersFromTheTopDown() async throws {
    for way in 0...1 {
      let source = path("poster\(way).psd")
      try psd(way).write(to: source)
      let made = try await run(["layers"], on: source)
      XCTAssertEqual(made.map(\.lastPathComponent), ["poster\(way).png", "poster\(way)-002 Back.png"])
      XCTAssertEqual(made[0].deletingLastPathComponent().lastPathComponent, "poster\(way)", "a set goes in a folder")
      XCTAssertEqual(try pixel(made[0], 0, 0)[3], 0)
      XCTAssertEqual(try pixel(made[0], 0.5, 0.5)[3], 128)
      XCTAssertEqual(try pixel(made[1], 0.5, 0.5), [255, 0, 0, 255])
    }
  }

  func test_aBrokenPhotoshopFileIsSaid() async throws {
    let whole = psd(0)
    for length in [10, 40, 60, 120, whole.count / 2] {
      let source = path("b\(length).psd")
      try whole.prefix(length).write(to: source)
      XCTAssertThrowsError(try PSDLayers.read(source), "\(length)")
    }
  }
}

final class NewSoundWordTests: ToolTestCase {
  private func samples(_ url: URL) throws -> (left: [Float], rate: Double, channels: Int) {
    let file = try AVAudioFile(forReading: url)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    while file.framePosition < file.length {
      let piece = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
      try file.read(into: piece)
      guard piece.frameLength > 0 else { break }
      memcpy(buffer.floatChannelData![0] + Int(buffer.frameLength), piece.floatChannelData![0], Int(piece.frameLength) * 4)
      buffer.frameLength += piece.frameLength
    }
    return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), file.processingFormat.sampleRate, Int(file.processingFormat.channelCount))
  }

  private func loud(_ all: ArraySlice<Float>) -> Float { (all.reduce(0) { $0 + $1 * $1 } / Float(max(1, all.count))).squareRoot() }

  private func write(_ parts: [(seconds: Double, hertz: Double, level: Float)], to url: URL) throws {
    let rate = 44_100.0
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
    ])
    for part in parts {
      let count = AVAudioFrameCount(part.seconds * rate)
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
      buffer.frameLength = count
      for channel in 0..<2 {
        for index in 0..<Int(count) { buffer.floatChannelData![channel][index] = part.level * Float(sin(2 * .pi * part.hertz * Double(index) / rate)) }
      }
      try file.write(from: buffer)
    }
  }

  private func crossings(_ all: [Float]) -> Double { Double(zip(all, all.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count) / Double(all.count) }

  func test_mono() async throws {
    let source = path("a.wav")
    try write([(1, 440, 0.5)], to: source)
    let made = try samples(try await run(["mono"], on: source)[0])
    XCTAssertEqual(made.channels, 1)
    XCTAssertEqual(made.left.count, 44_100)
    XCTAssertEqual(loud(made.left[...]), Float(0.5).squareRoot() / 2, accuracy: 0.01)
  }

  func test_fade() async throws {
    let source = path("a.wav")
    try write([(4, 440, 0.5)], to: source)
    let made = try samples(try await run(["fade1s"], on: source)[0]).left
    XCTAssertEqual(made.count, 4 * 44_100)
    XCTAssertLessThan(loud(made[0..<1000]), 0.02)
    XCTAssertEqual(loud(made[20_000..<24_000]), 0.35 / 2, accuracy: 0.04)
    XCTAssertEqual(loud(made[80_000..<90_000]), 0.35, accuracy: 0.02)
    XCTAssertLessThan(loud(made.suffix(1000)), 0.02)
  }

  func test_pitchIsHigherAndAsLong() async throws {
    let source = path("a.wav")
    try write([(3, 440, 0.5)], to: source)
    let before = try samples(source).left, made = try samples(try await run(["pitch+12"], on: source)[0]).left
    XCTAssertEqual(made.count, before.count)
    XCTAssertEqual(crossings(Array(made[40_000..<90_000])) / crossings(Array(before[40_000..<90_000])), 2, accuracy: 0.05)
  }

  func test_longSilencesGo() async throws {
    let source = path("a.wav")
    try write([(1, 440, 0.5), (3, 440, 0), (1, 440, 0.5), (0.3, 440, 0), (1, 440, 0.5)], to: source)
    let made = try await run(["nosilence"], on: source)[0]
    // The short one stays, and a little on either side of the long one.
    let length = try await seconds(made)
    XCTAssertEqual(length, 3.6, accuracy: 0.1)
  }

  func test_nothingToSkip() async throws {
    let source = path("a.wav")
    try write([(2, 440, 0.5)], to: source)
    let said = await reason { _ = try await self.run(["nosilence"], on: source) }
    XCTAssertTrue(said.contains("no long silences"), said)
    let quiet = path("b.wav")
    try write([(2, 440, 0)], to: quiet)
    let other = await reason { _ = try await self.run(["nosilence"], on: quiet) }
    XCTAssertTrue(other.contains("nothing but silence"), other)
  }

  func test_parts() {
    let heard = Array(repeating: true, count: 50) + Array(repeating: false, count: 100) + Array(repeating: true, count: 50)
    let parts = Silence.parts(heard, within: 0...4)
    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(parts[0].upperBound, 1.15, accuracy: 0.001)
    XCTAssertEqual(parts[1].lowerBound, 2.85, accuracy: 0.001)
  }

  /// A hum is not a voice, and goes; as long as it was.
  func test_voice() async throws {
    let source = path("a.wav")
    try write([(3, 120, 0.2)], to: source)
    let made = try samples(try await run(["voice"], on: source)[0]).left
    XCTAssertEqual(made.count, 3 * 44_100)
    XCTAssertLessThan(loud(made[44_100..<120_000]), 0.05)
  }
}

final class NewFilmWordTests: ToolTestCase {
  private func picture(_ url: URL) async throws -> (size: CGSize, frames: Int, rate: Float) {
    let asset = AVURLAsset(url: url)
    let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var frames = 0
    while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
    return (try await track.load(.naturalSize), frames, try await track.load(.nominalFrameRate))
  }

  private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }

  func test_lines() async throws {
    let source = try await Fixture.video(at: path("a.mov"))
    let made = try await run(["240p"], on: source)[0]
    let size = try await picture(made).size
    XCTAssertEqual(size.height, 240)
    XCTAssertEqual(size.width, 426, accuracy: 2)
    let said = await reason { _ = try await self.run(["1080p"], on: source) }
    XCTAssertTrue(said.contains("no larger"), said)
  }

  func test_rate() async throws {
    let source = try await Fixture.video(at: path("a.mov"), seconds: 2)
    let made = try await run(["fps10"], on: source)[0]
    let found = try await picture(made)
    XCTAssertEqual(found.rate, 10, accuracy: 0.5)
    XCTAssertEqual(found.frames, 20, accuracy: 1)
  }

  func test_aFrameAtAMoment() async throws {
    let source = try await Fixture.video(at: path("a.mov"), seconds: 2)
    let made = try await run(["at1s"], on: source)
    XCTAssertEqual(made.count, 1)
    XCTAssertEqual(try ProcessableFile(url: made[0]).dimensions, Dimensions(width: 640, height: 360))
    let end = try await run(["at2s"], on: source)
    XCTAssertEqual(end.count, 1, "the very end is the last picture")
    let said = await reason { _ = try await self.run(["at9s"], on: source) }
    XCTAssertTrue(said.contains("nothing at"), said)
  }

  /// Twice as long, and nearly twice as many frames.
  func test_slowMotion() async throws {
    guard #available(macOS 15.4, *) else { throw XCTSkip("needs macOS 15.4") }
    let source = try await Fixture.video(at: path("a.mov"), seconds: 1)
    let before = try await picture(source), whole = try await seconds(source)
    let made = try await run(["slowmo2x"], on: source)[0]
    let after = try await picture(made), length = try await seconds(made)
    XCTAssertEqual(length, whole * 2, accuracy: 0.1)
    XCTAssertEqual(after.frames, before.frames * 2 - 1, accuracy: 2)
  }

  func test_grayFilmKeepsItsSound() async throws {
    let source = try await Fixture.video(at: path("a.mov"))
    let made = try await run(["gray"], on: source)[0]
    let sound = try await AVURLAsset(url: made).loadTracks(withMediaType: .audio).count
    XCTAssertEqual(sound, 1)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: made))
    let frame = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    XCTAssertLessThanOrEqual(Int(pixel.prefix(3).max()!) - Int(pixel.prefix(3).min()!), 8, "\(pixel)")
  }

  /// Whoever is in it: here, the left half.
  func test_aFilmWithoutItsBackground() async throws {
    FilmFrames.peopleForTests = { image in
      CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: image.extent.width / 2, height: image.extent.height))
        .composited(over: CIImage(color: .black).cropped(to: image.extent))
    }
    defer { FilmFrames.peopleForTests = nil }
    let source = try await Fixture.video(at: path("a.mov"))
    let made = try await run(["nobg"], on: source)[0]
    XCTAssertEqual(made.pathExtension, "mov")
    let asset = AVURLAsset(url: made)
    let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
    let described = try await track.load(.mediaCharacteristics)
    XCTAssertTrue(described.contains(.containsAlphaChannel))
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
    reader.add(output)
    reader.startReading()
    let buffer = try XCTUnwrap(output.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer)
    XCTAssertGreaterThan(base[180 * row + 160 * 4 + 3], 250)
    XCTAssertLessThan(base[180 * row + 480 * 4 + 3], 5)
  }

  func test_nobodyInTheFilm() async throws {
    let source = try await Fixture.video(at: path("a.mov"))
    let said = await reason { _ = try await self.run(["nobg"], on: source) }
    XCTAssertTrue(said.contains("nobody"), said)
  }

  func test_whatOnlyMacOSDoesIsSaid() {
    XCTAssertNotNil(MediaEdit([.tool(.voice)]).ffmpegRefusal)
    XCTAssertNotNil(MediaEdit([.tool(.slowMotion(2))]).ffmpegRefusal)
    XCTAssertNil(MediaEdit([.tool(.mono), .tool(.gray)]).ffmpegRefusal)
    XCTAssertEqual(MediaEdit([.tool(.pitch(24))]).ffmpegSound.filter { $0.hasPrefix("atempo") }.count, 2)
  }
}

final class NewPDFWordTests: ToolTestCase {
  override func tearDown() {
    PDFLock.ask = nil
    super.tearDown()
  }

  private func answering(_ answers: [String]) -> Asked {
    let asked = Asked(answers)
    PDFLock.ask = { await asked.next($0) }
    return asked
  }

  private actor Asked {
    private var answers: [String]
    private(set) var questions: [PDFLock.Question] = []
    init(_ answers: [String]) { self.answers = answers }
    func next(_ question: PDFLock.Question) -> String? {
      questions.append(question)
      return answers.isEmpty ? nil : answers.removeFirst()
    }
  }

  func test_aPasswordPutOnAndTakenOff() async throws {
    let source = try Fixture.pdf(at: path("a.pdf"), pages: 3)
    _ = answering(["goose"])
    let locked = try await run(["askpassword"], on: source)[0]
    XCTAssertEqual(PDFDocument(url: locked)?.isLocked, true)
    XCTAssertNil(try Data(contentsOf: locked).range(of: Data("goose".utf8)))
    XCTAssertNotNil(try Data(contentsOf: locked).range(of: Data("AESV".utf8)), "a lock that is still a lock")

    let asked = answering(["duck", "goose"])
    let open = try await run(["unlock"], on: locked)[0]
    let pdf = try XCTUnwrap(PDFDocument(url: open))
    XCTAssertFalse(pdf.isEncrypted)
    XCTAssertEqual(pdf.pageCount, 3)
    let questions = await asked.questions
    XCTAssertEqual(questions.map(\.isAgain), [false, true])
  }

  /// Asked to replace it, the original stays all the same, and no copy of it is
  /// put away without its password.
  func test_theOriginalStaysAndNothingOfItIsPutAway() async throws {
    let source = try Fixture.pdf(at: path("contract_askpassword.pdf"), pages: 1)
    let before = try Data(contentsOf: source)
    for mode in [DestinationMode.overwrite, .moveTo] {
      _ = answering(["goose"])
      let made = try await run([], on: source, mode: mode)
      XCTAssertEqual(made.map(\.lastPathComponent), ["contract locked.pdf"])
      XCTAssertEqual(PDFDocument(url: made[0])?.isLocked, true)
      XCTAssertEqual(try Data(contentsOf: source), before)
      XCTAssertEqual(contents(of: store.backupsDirectory), [])
    }
  }

  func test_aLockedPDFBecomesPictures() async throws {
    let source = try Fixture.pdf(at: path("a.pdf"), pages: 2)
    _ = answering(["goose", "goose"])
    let locked = try await run(["askpassword"], on: source)[0]
    let made = try await run(["unlock"], on: locked, to: .png)
    XCTAssertEqual(made.count, 2)
  }

  func test_nothingIsDoneWithoutOne() async throws {
    let source = try Fixture.pdf(at: path("a.pdf"), pages: 1)
    let nobody = await reason { _ = try await self.run(["askpassword"], on: source) }
    XCTAssertTrue(nobody.contains("nowhere"), nobody)
    _ = answering([])
    do { _ = try await run(["askpassword"], on: source); XCTFail("it went on") } catch is CancellationError {}
    let open = await reason { _ = try await self.run(["unlock"], on: source) }
    XCTAssertTrue(open.contains("no password"), open)
  }

  /// Once for a file, however many come of it, and nowhere in what is kept.
  func test_askedOnceAndNotWrittenDown() async throws {
    let source = try Fixture.pdf(at: path("a.pdf"), pages: 4)
    let asked = answering(["zebra-crossing"])
    let made = try await run(["split2pages", "askpassword"], on: source)
    XCTAssertEqual(made.count, 2)
    XCTAssertTrue(made.allSatisfy { PDFDocument(url: $0)?.isLocked == true })
    let count = await asked.questions.count
    XCTAssertEqual(count, 1)
    let files = FileManager.default.enumerator(at: store.root, includingPropertiesForKeys: nil)
    for case let url as URL in files! {
      guard let data = try? Data(contentsOf: url) else { continue }
      XCTAssertNil(data.range(of: Data("zebra-crossing".utf8)), url.path)
    }
  }

  func test_numbers() async throws {
    let source = try Fixture.pdf(at: path("a.pdf"), pages: 2)
    let madeURL = try await run(["numbers"], on: source)[0]
    let made = try XCTUnwrap(PDFDocument(url: madeURL))
    XCTAssertEqual((0..<2).map { made.page(at: $0)?.annotations.first?.contents }, ["1", "2"])
    XCTAssertEqual(made.page(at: 0)?.string, PDFDocument(url: source)?.page(at: 0)?.string)
  }

  func test_severalToASheet() async throws {
    let source = try Fixture.pdf(at: path("a.pdf"), pages: 5)
    let twoURL = try await run(["2up"], on: source)[0]
    let two = try XCTUnwrap(PDFDocument(url: twoURL))
    XCTAssertEqual(two.pageCount, 3)
    XCTAssertEqual(two.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 200, height: 300), "a wide page goes one above the other")
    let fourURL = try await run(["4up"], on: source)[0]
    let four = try XCTUnwrap(PDFDocument(url: fourURL))
    XCTAssertEqual(four.pageCount, 2)
    XCTAssertEqual(four.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 300, height: 200))
    XCTAssertTrue(PDFTools.grid(2, of: CGSize(width: 210, height: 297)) == (2, 1))
    XCTAssertTrue(PDFTools.grid(6, of: CGSize(width: 210, height: 297)) == (3, 2))
    XCTAssertTrue(PDFTools.grid(8, of: CGSize(width: 210, height: 297)) == (4, 2))
  }

  func test_dotsPerInch() async throws {
    let source = try Fixture.pdf(at: path("a.pdf"), pages: 1)
    let made = try await run(["dpi300"], on: source)[0]
    XCTAssertEqual(made.pathExtension, "jpeg")
    XCTAssertEqual(try ProcessableFile(url: made).dimensions, Dimensions(width: 1250, height: 833))
  }

  /// A JPEG put in a PDF comes out of it byte for byte.
  func test_picturesAsTheyWerePutThere() async throws {
    let picture = path("p.jpg")
    try Fixture.image(at: picture, width: 120, height: 80)
    let source = path("a.pdf")
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
    let jpeg = try XCTUnwrap(CGDataProvider(url: picture as CFURL).flatMap { CGImage(jpegDataProviderSource: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent) })
    for _ in 0..<2 {
      context.beginPDFPage(nil)
      context.draw(jpeg, in: CGRect(x: 10, y: 10, width: 120, height: 80))
      context.endPDFPage()
    }
    context.closePDF()
    let made = try await run(["images"], on: source)
    XCTAssertEqual(made.count, 1, "the same one twice is one")
    XCTAssertEqual(try ProcessableFile(url: made[0]).dimensions, Dimensions(width: 120, height: 80))
    XCTAssertEqual(made[0].pathExtension, "jpeg")
    let none = await reason { _ = try await self.run(["images"], on: try Fixture.pdf(at: self.path("b.pdf"), pages: 1)) }
    XCTAssertTrue(none.contains("no pictures"), none)
  }

  func test_tables() async throws {
    guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
    let source = path("t.png")
    let context = try XCTUnwrap(CGContext(data: nil, width: 900, height: 420, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 900, height: 420))
    let rows = [["Item", "Quantity", "Price"], ["Paper", "100", "12.50"], ["Ink", "3", "30.00"], ["Brush", "7", "4.20"]]
    for (index, row) in rows.enumerated() {
      for (column, word) in row.enumerated() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 28, nil)]))
        context.textPosition = CGPoint(x: 60 + column * 290, y: 330 - index * 80)
        CTLineDraw(line, context)
      }
    }
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(2)
    for index in 0...4 { context.strokeLineSegments(between: [CGPoint(x: 40, y: 60 + index * 80), CGPoint(x: 860, y: 60 + index * 80)]) }
    for x in [40, 330, 620, 860] { context.strokeLineSegments(between: [CGPoint(x: x, y: 60), CGPoint(x: x, y: 380)]) }
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let made = try await run(["tables"], on: source, to: .commaSeparatedText)[0]
    XCTAssertEqual(try String(contentsOf: made, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init), rows.map { $0.joined(separator: ",") })
    let book = try await run(["tables"], on: source)[0]
    XCTAssertEqual(book.pathExtension, "xlsx")
  }
}

final class TidyTests: ToolTestCase {
  func test_json() throws {
    let text = "{\"b\": 1.10, \"a\":[1,{\"x\":null}],\"s\":\"a { b , c }\",\"e\":[], \"o\":{}}"
    XCTAssertEqual(try Tidier.tidied(text, .json, .min), "{\"b\":1.10,\"a\":[1,{\"x\":null}],\"s\":\"a { b , c }\",\"e\":[],\"o\":{}}")
    XCTAssertEqual(try Tidier.tidied(text, .json, .pretty), """
      {
        "b": 1.10,
        "a": [
          1,
          {
            "x": null
          }
        ],
        "s": "a { b , c }",
        "e": [],
        "o": {}
      }

      """)
    XCTAssertThrowsError(try Tidier.tidied("{\"a\": }", .json, .min))
  }

  func test_css() throws {
    let text = "/* n */ .a > .b , .a .b:hover{ color : red ; margin:0 auto }\n@media screen and (max-width: 9px){.x::after{content: \"}; {\";width:calc(100% - 2px);}}"
    XCTAssertEqual(
      try Tidier.tidied(text, .css, .min),
      ".a > .b,.a .b:hover{color:red;margin:0 auto}@media screen and (max-width: 9px){.x::after{content:\"}; {\";width:calc(100% - 2px)}}"
    )
    let long = try Tidier.tidied(text, .css, .pretty)
    XCTAssertTrue(long.contains("\n  margin: 0 auto\n}"), long)
    XCTAssertEqual(try Tidier.tidied(long, .css, .min), try Tidier.tidied(text, .css, .min), "there and back")
    XCTAssertThrowsError(try Tidier.tidied("a { b: c", .css, .min))
  }

  func test_javaScript() throws {
    let text = """
      // a note
      const a = 1
      const b = a / 2 / 3, re = /a  [/]b/g
      function f(x) { if (x) /q  r/.test(x); return `t ${x + `${a}`}  z`; }
      let i = 0
      i
      ++i
      const c = a - -i, d = "a  //  b"
      """
    let short = try Tidier.tidied(text, .javaScript, .min)
    for kept in ["/a  [/]b/g", "/q  r/", "`}  z`", "\"a  //  b\"", "i\n++i", "a- -i"] { XCTAssertTrue(short.contains(kept), "\(kept) in \(short)") }
    XCTAssertFalse(short.contains("a note"))
    let long = try Tidier.tidied(short, .javaScript, .pretty)
    XCTAssertTrue(long.contains("\n  if(x)/q  r/.test(x);\n") || long.contains("\n  if (x) /q  r/.test(x);\n") || long.contains("/q  r/.test(x);\n"), long)
    XCTAssertThrowsError(try Tidier.tidied("f(", .javaScript, .min))
  }

  func test_xml() throws {
    let text = "<?xml version=\"1.0\"?>\n<!-- c --><r a=\"1>2\"><x> <y/> </x><p>a <b>b</b> <i>c</i> &amp;</p><z><![CDATA[ <k> ]]></z></r>"
    XCTAssertEqual(try Tidier.tidied(text, .xml, .min), "<?xml version=\"1.0\"?><r a=\"1>2\"><x><y/></x><p>a <b>b</b> <i>c</i> &amp;</p><z><![CDATA[ <k> ]]></z></r>")
    let long = try Tidier.tidied(text, .xml, .pretty)
    XCTAssertTrue(long.contains("<!-- c -->\n<r a=\"1>2\">\n  <x>\n    <y/>\n  </x>\n  <p>a <b>b</b> <i>c</i> &amp;</p>"), long)
    XCTAssertThrowsError(try Tidier.tidied("<a><b></a>", .xml, .min))
  }

  /// What Forge opens for nothing else.
  func test_aStyleSheetByItsName() async throws {
    let source = path("site_min.css")
    try "a { b : c }".write(to: source, atomically: true, encoding: .utf8)
    let made = try await run([], on: source)[0]
    XCTAssertEqual(made.lastPathComponent, "site.css")
    XCTAssertEqual(try String(contentsOf: made, encoding: .utf8), "a{b:c}")
  }
}
