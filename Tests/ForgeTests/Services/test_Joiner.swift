import XCTest
import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
@testable import Forge

final class JoinerTests: ToolTestCase {
  private func files(_ urls: [URL]) throws -> [ProcessableFile] { try urls.map { try ProcessableFile(url: $0) } }

  private func join(_ urls: [URL], as kind: Joiner.Kind) async throws -> URL {
    try await coordinator().join(try files(urls), as: kind, into: path("out"))
  }

  func test_whatCanBeOne() throws {
    let a = try Fixture.image(at: path("a.png")), b = try Fixture.image(at: path("b.jpg"))
    let pdf = path("c.pdf")
    try Fixture.pdf(at: pdf, pages: 2)
    let wav = try Fixture.audio(at: path("d.wav"), seconds: 0.2)
    XCTAssertEqual(Joiner.kinds(for: try files([a, b])), [.pdf, .film])
    XCTAssertEqual(Joiner.kinds(for: try files([a, pdf])), [.pdf])
    XCTAssertEqual(Joiner.kinds(for: try files([wav, wav])), [.sound])
    XCTAssertEqual(Joiner.kinds(for: try files([a, wav])), [])
    XCTAssertEqual(Joiner.kinds(for: try files([a])), [])
  }

  func test_onePDF() async throws {
    let one = path("a.pdf"), two = path("b.pdf")
    try Fixture.pdf(at: one, pages: 2)
    try Fixture.pdf(at: two, pages: 3)
    let picture = try Fixture.image(at: path("c.png"))
    let made = try await join([one, picture, two], as: .pdf)
    XCTAssertEqual(made.lastPathComponent, "a joined.pdf")
    XCTAssertEqual(PDFDocument(url: made)?.pageCount, 6)
    let again = try await join([one, two], as: .pdf)
    XCTAssertEqual(again.lastPathComponent, "a joined 2.pdf", "nothing is written over")
    let history = try await store.loadHistory()
    XCTAssertEqual(history.count, 2)
  }

  /// Of different shapes: the first says which, and the second is whole in it.
  func test_oneFilm() async throws {
    let one = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    let two = path("b.mov")
    try await Quarters.film(at: two, width: 200, height: 200, seconds: 2)
    let made = try await join([one, two], as: .film)
    let length = try await seconds(made)
    XCTAssertEqual(length, 3, accuracy: 0.2)
    let frame = try Quarters.frame(of: made, at: 2)
    XCTAssertEqual(CGSize(width: frame.width, height: frame.height), CGSize(width: 640, height: 360))
    let middle = try XCTUnwrap(frame.cropping(to: CGRect(x: 140, y: 0, width: 360, height: 360)))
    XCTAssertEqual(Quarters.read(middle), [.red, .green, .blue, .white])
    let tracks = try await AVURLAsset(url: made).trackCounts()
    XCTAssertEqual(tracks.audio, 1)
  }

  func test_aFilmOfPictures() async throws {
    let one = path("a.png"), two = path("b.png")
    try Quarters.image(at: one, width: 320, height: 200)
    try Quarters.image(at: two, width: 100, height: 100)
    let made = try await join([one, two], as: .film)
    let length = try await seconds(made)
    XCTAssertEqual(length, 6, accuracy: 0.3)
    XCTAssertEqual(Quarters.read(try Quarters.frame(of: made, at: 1)), [.red, .green, .blue, .white])
    let second = try Quarters.frame(of: made, at: 5)
    XCTAssertEqual(second.width, 320)
    XCTAssertEqual(Quarters.read(try XCTUnwrap(second.cropping(to: CGRect(x: 60, y: 0, width: 200, height: 200)))), [.red, .green, .blue, .white])
  }

  func test_oneRecording() async throws {
    let one = try Fixture.audio(at: path("a.wav"), seconds: 1)
    let two = try Fixture.audio(at: path("b.wav"), seconds: 2, sampleRate: 44_100, channels: 2)
    let made = try await join([one, two], as: .sound)
    XCTAssertEqual(made.pathExtension, "wav")
    let length = try await seconds(made)
    XCTAssertEqual(length, 3, accuracy: 0.05)
  }

  func test_nothingIsLeftWhenItFails() async throws {
    let one = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    let two = path("b.mp4")
    try Data("not a film".utf8).write(to: two)
    let said = await reason { _ = try await self.join([one, two], as: .film) }
    XCTAssertTrue(said.contains("b.mp4"), said)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: path("out").path)) ?? []
    XCTAssertEqual(left, [])
  }
}

@MainActor
final class HandyToolTests: ToolTestCase {
  func test_theMenuOffersWhatSuits() throws {
    let film = try ProcessableFile(url: try makeFile("a.mp4"))
    let words = AskOptions.choices(for: .tool, files: [film]).map(\.value)
    XCTAssertTrue(words.contains(.tool(.mute)))
    let doc = try ProcessableFile(url: try makeFile("a.txt"))
    XCTAssertEqual(AskOptions.choices(for: .tool, files: [doc]), [], "a text has no pages to turn")
  }

  private func makeFile(_ name: String) throws -> URL {
    try Data("x".utf8).write(to: path(name))
    return path(name)
  }

  func test_everyHandyToolSuitsItsKind() {
    let types: [ConvertKind: UTType] = [.image: .png, .video: .mpeg4Movie, .audio: .wav, .document: .pdf]
    for (kind, type) in types {
      XCTAssertFalse(Tool.handy(for: kind).isEmpty)
      for tool in Tool.handy(for: kind) { XCTAssertTrue(tool.suits(type), "\(tool.word) on \(kind)") }
    }
  }

  func test_aToolPickedIsAStep() {
    let request = AskRequest(word: .everything, over: nil)
    XCTAssertEqual(request.answered(with: [.tool: .tool(.mute)]).actions, [.tool(.mute)])
  }

  /// All of them together is instead of each of them by itself.
  func test_joining() async throws {
    let a = try Fixture.image(at: path("a.png")), b = try Fixture.image(at: path("b.png"))
    var joined: [String] = []
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: try ProcessableFile(url: a), convert: { _, _ in XCTFail("not one by one"); return [] })
    session.files = [try ProcessableFile(url: a), try ProcessableFile(url: b)]
    XCTAssertFalse(session.questions.contains(.join), "nobody to join them")
    session.join = { files, kind in joined = files.map(\.fileName) + [kind.rawValue]; return a }
    XCTAssertTrue(session.questions.contains(.join))
    session.choose(.format(.jpeg), for: .format)
    session.choose(.join(.pdf), for: .join)
    XCTAssertEqual(session.answers, [.join: .join(.pdf)])
    await session.run()
    XCTAssertEqual(joined, ["a.png", "b.png", "pdf"])
  }
}

@MainActor
final class ResultHandTests: BaseTestCase {
  func test_neverOverWhatIsThere() throws {
    let file = path("a.txt"), home = try folder("home")
    try Data("new".utf8).write(to: file)
    try Data("old".utf8).write(to: home.appendingPathComponent("a.txt"))
    try ResultHand.place([file], in: home, moving: false)
    XCTAssertEqual(contents(of: home), ["a 2.txt", "a.txt"])
    XCTAssertTrue(exists(file))
    try ResultHand.place([file], in: home, moving: true)
    XCTAssertEqual(contents(of: home), ["a 2.txt", "a 3.txt", "a.txt"])
    XCTAssertFalse(exists(file))
    XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("a.txt"), encoding: .utf8), "old")
  }

  func test_copying() {
    let pasteboard = NSPasteboard(name: .init("forge-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    ResultHand.copyPaths([URL(fileURLWithPath: "/tmp/a b.txt"), URL(fileURLWithPath: "/tmp/c.txt")], to: pasteboard)
    XCTAssertEqual(pasteboard.string(forType: .string), "/tmp/a b.txt\n/tmp/c.txt")
    ResultHand.copy([URL(fileURLWithPath: "/tmp/a b.txt")], to: pasteboard)
    XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self])?.count, 1)
  }
}

@MainActor
final class CutFromTheMenuTests: ToolTestCase {
  func test_cuttingOpensAWindowAndLeavesTheMenu() async throws {
    let a = try Fixture.image(at: path("a.png"))
    var opened: [String] = [], closed = 0
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: try ProcessableFile(url: a), convert: { _, _ in XCTFail("nothing was chosen"); return [] })
    XCTAssertFalse(session.questions.contains(.cut))
    session.cut = { opened.append($0.fileName) }
    session.onClose = { closed += 1 }
    XCTAssertTrue(session.questions.contains(.cut))
    session.choose(.cut, for: .cut)
    XCTAssertEqual(opened, ["a.png"])
    XCTAssertEqual(closed, 1)
    XCTAssertTrue(session.answers.isEmpty)
    let two = try Fixture.image(at: path("b.png"))
    session.files.append(try ProcessableFile(url: two))
    XCTAssertFalse(session.questions.contains(.cut), "one at a time")
  }
}
