import XCTest
import UniformTypeIdentifiers
@testable import Forge

final class After41Tests: BaseTestCase {
  /// The word that asks is spent once it has been answered: it came out as
  /// `photo_ask.jpg`, to be asked about again.
  func test_theWordThatAskedIsNotInWhatComesOut() async throws {
    XCTAssertEqual(NameTokens.answered("photo_ask", ext: "png"), "photo")
    XCTAssertEqual(NameTokens.answered("photo_asksize_2MB", ext: "png"), "photo_2MB")
    XCTAssertEqual(NameTokens.answered("how_to_ask_for_it", ext: "pdf"), "how_to_ask_for_it")
    XCTAssertEqual(NameTokens.answered("ask", ext: "png"), "ask")

    let file = path("photo_ask.png")
    try Fixture.image(at: file, width: 20, height: 20)
    var preset = RulePreset(name: "x", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])
    func made() async throws -> String {
      let entry = try await coordinator().processFile(try ProcessableFile(url: file), with: preset, destinationMode: .copyTo, destinationURL: try folder("out\(preset.isAnswered)")) { _ in }
      return try XCTUnwrap(entry.outputURL).deletingPathExtension().lastPathComponent
    }
    let kept = try await made()
    XCTAssertEqual(kept, "photo_ask", "a name is a name, where nobody asked")
    preset.isAnswered = true
    let spent = try await made()
    XCTAssertEqual(spent, "photo")
  }

  /// A talk written down is not 99% smaller.
  func test_wordsAreNotLessOfWhatWasHeard() throws {
    func isElse(_ to: String, _ from: UTType) -> Bool { ProcessingHistory.isSomethingElse(path("a.\(to)"), than: from) }
    XCTAssertTrue(isElse("txt", .wav))
    XCTAssertTrue(isElse("srt", .quickTimeMovie))
    XCTAssertTrue(isElse("txt", .png))
    XCTAssertFalse(isElse("mp3", .wav))
    XCTAssertFalse(isElse("gif", .quickTimeMovie))
    XCTAssertFalse(isElse("svg", .png))
    XCTAssertFalse(isElse("pdf", .png))
    XCTAssertFalse(isElse("txt", .rtf))
    XCTAssertFalse(ProcessingHistory.isSomethingElse(nil, than: .wav))
  }

  /// A film shows a frame of itself, and not the icon of a film.
  func test_aFilmIsSeen() async throws {
    let film = try await Fixture.video(at: path("a.mov"), seconds: 1, size: CGSize(width: 320, height: 180))
    let seen = await PreviewImage.seen(film, maxPixels: 200)
    XCTAssertEqual(seen.size.width / seen.size.height, 16.0 / 9, accuracy: 0.1)
    let nothing = path("a.zzz")
    try Data([1]).write(to: nothing)
    let stand = await PreviewImage.seen(nothing, maxPixels: 64)
    XCTAssertGreaterThan(stand.size.width, 0)
  }

  func test_whatIsHeardIsDrawn() async throws {
    let sound = try Fixture.audio(at: path("a.wav"), seconds: 2)
    let wave = await CutPlayer.wave(of: sound, length: 2, bars: 40)
    XCTAssertEqual(wave.count, 40)
    XCTAssertEqual(wave.max() ?? 0, 1, accuracy: 0.001)
    XCTAssertGreaterThan(wave.filter { $0 > 0.5 }.count, 30)
    let silent = await CutPlayer.wave(of: path("none.wav"), length: 2, bars: 40)
    XCTAssertEqual(silent, [])
  }
}
