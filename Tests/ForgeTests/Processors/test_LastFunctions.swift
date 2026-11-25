import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Forge

final class EmailTests: ToolTestCase {
  private let raw = """
  From: =?utf-8?Q?Ada_Per=C3=B2?= <ada@example.com>
  To: goose@example.com
  Subject: =?UTF-8?B?UGVyY2jDqQ==?= =?UTF-8?Q?_s=C3=AC?=
  Date: Tue, 24 Nov 2026 10:00:00 +0100
  Content-Type: multipart/mixed;
   boundary="outer"

  --outer
  Content-Type: multipart/alternative; boundary=inner

  --inner
  Content-Type: text/plain; charset=utf-8
  Content-Transfer-Encoding: quoted-printable

  Ciao perch=C3=A9 una riga lun=
  ga.
  --inner
  Content-Type: text/html; charset=utf-8

  <p>Ciao <img src="https://example.com/seen.gif"></p>
  --inner--
  --outer
  Content-Type: application/pdf; name=a.pdf
  Content-Disposition: attachment; filename=a.pdf
  Content-Transfer-Encoding: base64

  AAAA
  --outer--
  """.replacingOccurrences(of: "\n", with: "\r\n")

  func test_aMessageAsWords() async throws {
    let source = path("a.eml")
    try raw.write(to: source, atomically: true, encoding: .utf8)
    XCTAssertEqual(ConvertKind(fileType: try ProcessableFile(url: source).fileType), .document)
    let made = try await run([], on: source, to: .plainText)[0]
    let text = try String(contentsOf: made, encoding: .utf8)
    XCTAssertTrue(text.contains("From: Ada Però <ada@example.com>"), text)
    XCTAssertTrue(text.contains("Subject: Perché sì"), text)
    XCTAssertTrue(text.contains("Ciao perché una riga lunga."), text)
    XCTAssertFalse(text.contains("<p>") || text.contains("AAAA"), text)
    let pdf = try await run([], on: source, to: .pdf)[0]
    XCTAssertGreaterThan(size(of: pdf), 500)
  }

  func test_onlyAPage() throws {
    let source = path("a.eml")
    try "From: a@b.c\nContent-Type: text/html; charset=utf-8\n\n<style>x</style><p>Uno &amp; due</p><img src=https://x.y/z>tre".write(to: source, atomically: true, encoding: .utf8)
    XCTAssertEqual(try Email.read(source).text.split(separator: "\n").map(String.init), ["Uno & due", "tre"])
  }

  func test_notAMessage() throws {
    let source = path("a.eml")
    try Data([0, 1, 2, 3]).write(to: source)
    XCTAssertThrowsError(try Email.read(source))
  }
}

final class ClaimsTests: ToolTestCase {
  func test_whatAForgeThatIsGoneLeftBehind() throws {
    let root = try folder("root"), home = try folder("home")
    let notes = root.appendingPathComponent("Writing")
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let empty = home.appendingPathComponent("photo.jpeg"), scratch = home.appendingPathComponent(".forge-X.jpeg"), full = home.appendingPathComponent("mine.jpeg")
    try Data().write(to: empty)
    try Data("half".utf8).write(to: scratch)
    try Data("mine".utf8).write(to: full)
    // A number no process has.
    let list = [empty, scratch, full].map(\.path)
    try JSONEncoder().encode(list).write(to: notes.appendingPathComponent("999999-A.json"))
    let beside = home.appendingPathComponent(".forge-X.jpeg.sb-c7cd-yex")
    try Data("half".utf8).write(to: beside)
    XCTAssertEqual(Claims.sweep(root: root), 3)
    XCTAssertFalse(exists(empty) || exists(scratch) || exists(beside))
    XCTAssertTrue(exists(full), "it has something in it, and is somebody's")
    XCTAssertEqual(contents(of: notes), [])
  }

  func test_whatIsBeingWrittenNowIsLeft() throws {
    let root = try folder("root"), empty = path("now.jpeg")
    try Data().write(to: empty)
    let claims = Claims(root: root)
    claims.add(empty)
    XCTAssertEqual(Claims.sweep(root: root), 0)
    XCTAssertTrue(exists(empty))
    claims.remove(empty)
    XCTAssertEqual(contents(of: root.appendingPathComponent("Writing")), [])
  }

  func test_nothingIsClaimedOnceItIsDone() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    _ = try await run([], on: source, to: .jpeg)
    XCTAssertEqual(contents(of: store.root.appendingPathComponent("Writing")), [])
  }
}

final class SeveralWidthsTests: ToolTestCase {
  func test_oneNameSeveralPictures() async throws {
    let source = path("goose_800px_400px.png")
    try Quarters.image(at: source, width: 1600, height: 1000)
    let made = try await run([], on: source, to: .jpeg)
    XCTAssertEqual(made.map(\.lastPathComponent), ["goose_800px.jpeg", "goose_400px.jpeg"])
    XCTAssertEqual(try made.map { try ProcessableFile(url: $0).dimensions?.width }, [800, 400])
  }

  func test_oneIsAsItWas() {
    XCTAssertEqual(NameTokens.widths("goose_800px.png"), [800])
    XCTAssertEqual(NameTokens.withoutWidths("goose_800px"), "goose_800px")
    XCTAssertEqual(NameTokens.widths("800px_notes.png"), [])
  }
}

final class LastFilmTests: ToolTestCase {
  func test_whatIsSaidAfterFilmSettingsIsSaidOfThem() {
    let chain: [Forge.Operation] = [.film(FilmSettings()), .quality(level: 30), .encode(codec: .hevc)]
    XCTAssertEqual(chain.film?.rate, .quality(30))
    XCTAssertEqual(chain.film?.encoder, .hevc)
    let before: [Forge.Operation] = [.quality(level: 30), .film(FilmSettings())]
    XCTAssertEqual(before.film?.rate, FilmSettings().rate)
  }

  func test_filtersOfOnesOwn_andNobodyElses() async throws {
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil, "ffmpeg is not here")
    var film = FilmSettings()
    film.filters = "negate"
    let source = path("a.mp4")
    try await Quarters.film(at: source)
    let made = try await run([], on: source, to: .mpeg4Movie, more: [.film(film)])[0]
    XCTAssertEqual(Quarters.read(try Quarters.frame(of: made)).last, .black, "white, turned inside out")
    let preset = RulePreset(name: "x", description: "", category: .video, actions: [.film(film)])
    XCTAssertFalse(PresetGallery.isRunnable(preset))
    XCTAssertNil(preset.withoutFilesOfItsOwn.actions.film?.filters)
  }

  func test_filmSettingsAreForFilms() async throws {
    let sound = try Fixture.audio(at: path("a.wav"), seconds: 1)
    let said = await reason { _ = try await self.run([], on: sound, to: .mpeg4Movie, more: [.film(FilmSettings())]) }
    XCTAssertTrue(said.contains("no picture"), said)
  }

  func test_theSoundDrawn() async throws {
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil, "ffmpeg is not here")
    let sound = try Fixture.audio(at: path("a.wav"), seconds: 2)
    let made = try await run(["wave", "trim0-1"], on: sound, mode: .moveTo)[0]
    XCTAssertTrue(exists(sound), "a drawing takes nothing's place")
    let tracks = try await AVURLAsset(url: made).trackCounts()
    XCTAssertEqual([tracks.video, tracks.audio], [1, 1])
    let length = try await seconds(made)
    XCTAssertEqual(length, 1, accuracy: 0.15)
  }

  func test_wordsInThePicture() async throws {
    let film = path("film.mp4")
    let black = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    black.setFillColor(CGColor(gray: 0, alpha: 1))
    black.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    try await MovieWriter.write((0..<40).map { _ in ImageFrame(image: black.makeImage()!, duration: 0.1) }, to: film, as: .mpeg4Movie) { _ in }
    let words = path("w.srt")
    try "1\n00:00:01,000 --> 00:00:02,000\nHONK HONK\n".write(to: words, atomically: true, encoding: .utf8)
    let files = [try ProcessableFile(url: film), try ProcessableFile(url: words)]
    XCTAssertTrue(Joiner.kinds(for: files).contains(.burned))
    let made = try await coordinator().join(files, as: .burned, into: path("out"))
    func bright(at seconds: Double) throws -> Int {
      let image = try Quarters.frame(of: made, at: seconds)
      var bytes = [UInt8](repeating: 0, count: image.width * image.height)
      let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let lower = bytes[(image.width * image.height * 3 / 4)...]
      return lower.filter { $0 > 180 }.count
    }
    XCTAssertGreaterThan(try bright(at: 1.5), 300, "said")
    XCTAssertEqual(try bright(at: 0.5), 0, "not yet")
    XCTAssertEqual(try bright(at: 2.5), 0, "no longer")
  }

  func test_aCollage() async throws {
    let files = try (0..<4).map { index -> ProcessableFile in
      let url = path("\(index).png")
      let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.setFillColor(Quarters.colours[index == 3 ? 0 : index])
      context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, context.makeImage()!, nil)
      CGImageDestinationFinalize(destination)
      return try ProcessableFile(url: url)
    }
    let made = try await coordinator().join(files, as: .collage, into: path("out"))
    XCTAssertEqual(try Quarters.read(made), [.red, .green, .blue, .red])
  }
}

@MainActor
final class GrowingBatchTests: ToolTestCase {
  private func model() -> AppModel {
    let model = AppModel(persistence: store)
    // There is no app here to be told by.
    model.settings.notifyWhenFinished = false
    model.settings.whenFinished = .nothing
    return model
  }

  func test_whatIsAddedWhileItWorksIsDone() async throws {
    let one = path("a.png"), two = path("b.png")
    try Fixture.noise(at: one, width: 2500, height: 2500)
    try Quarters.image(at: two)
    let batch = BatchViewModel(), model = model(), out = try folder("out")
    batch.add([one])
    let preset = RulePreset(name: "t", description: "", category: .image, actions: [.convertFormat(to: .heic)])
    let running = Task { await batch.convert(model: model, preset: preset, mode: .copyTo, destination: out) }
    try await Task.sleep(nanoseconds: 60_000_000)
    XCTAssertTrue(batch.isProcessing)
    batch.add([two])
    await running.value
    XCTAssertEqual(contents(of: out).count, 2)
  }

  func test_later_andStoppedBeforeItBegins() async throws {
    let one = path("a.png")
    try Quarters.image(at: one)
    let batch = BatchViewModel(), model = model(), out = try folder("out")
    batch.add([one])
    let preset = RulePreset(name: "t", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])
    batch.startsAt = Date().addingTimeInterval(1.2)
    let running = Task { await batch.convert(model: model, preset: preset, mode: .copyTo, destination: out) }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(contents(of: out), [])
    await running.value
    XCTAssertEqual(contents(of: out), ["a.jpeg"])
    batch.startsAt = Date().addingTimeInterval(3600)
    let never = Task { await batch.convert(model: model, preset: preset, mode: .copyTo, destination: out) }
    try await Task.sleep(nanoseconds: 200_000_000)
    batch.cancel(model: model)
    await never.value
    XCTAssertEqual(contents(of: out), ["a.jpeg"])
  }
}
