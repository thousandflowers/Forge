import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import Forge

/// What two people who had not written it found in it.
final class ToolAnswerTests: XCTestCase {
  /// A damaged film makes ffmpeg complain for longer than a pipe holds.
  func test_complaintsDoNotStopIt() {
    let said = ExternalTools.answer(of: URL(fileURLWithPath: "/bin/sh"), ["-c", "yes complaint | head -c 400000 >&2; echo done"])
    XCTAssertEqual(said, "done\n")
  }

  func test_aLongAnswerIsAllOfIt() {
    let said = ExternalTools.answer(of: URL(fileURLWithPath: "/bin/sh"), ["-c", "yes a | head -c 400000"])
    XCTAssertEqual(said.utf8.count, 400_000)
  }

  func test_itStopsWhenItsAskerDoes() async {
    let started = Date()
    let task = Task.detached { ExternalTools.answer(of: URL(fileURLWithPath: "/bin/sleep"), ["20"]) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    _ = await task.value
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }
}

final class FilmSettingsReviewTests: ToolTestCase {
  /// Read from a preset as they are, adding two of them up is a crash.
  func test_numbersNoFilmHas() {
    var film = FilmSettings()
    film.crop = .edges(top: .max, bottom: .max, left: .max, right: 5)
    film.from = -5
    film.to = .max
    XCTAssertFalse(film.outputArguments(for: "mp4", bars: nil).isEmpty)
    XCTAssertEqual(film.inputArguments, ["-ss", "0", "-t", "10000000"])
    film.from = .max
    XCTAssertFalse(film.inputArguments.isEmpty)
    XCTAssertGreaterThanOrEqual(film.kept(of: 10), 0)
  }

  private func requireTools() throws {
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil || ExternalTools.locate("ffprobe") == nil, "ffmpeg is not here")
  }

  private func probe(_ url: URL, _ what: [String]) throws -> String {
    ExternalTools.answer(of: try XCTUnwrap(ExternalTools.locate("ffprobe")), ["-v", "error"] + what + ["-of", "csv=p=0", url.path])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func test_aPartAfterTheEnd() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 2)
    var film = FilmSettings()
    film.from = 100
    let said = await reason { _ = try await self.run([], on: source, to: .mpeg4Movie, more: [.film(film)]) }
    XCTAssertTrue(said.contains("a.mp4 is 0:02"), said)
  }

  func test_aSoundtrackThereIsNot() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    var film = FilmSettings()
    film.track = 3
    let said = await reason { _ = try await self.run([], on: source, to: .mpeg4Movie, more: [.film(film)]) }
    XCTAssertEqual(said, "a.mp4 has one soundtrack, and track 3 was asked for.")
  }

  /// The part is of the film, and what is done to it is done to the part.
  func test_aPartSpedUp() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 5)
    var film = FilmSettings()
    film.from = 1
    film.to = 4
    let made = try await run(["speed2x"], on: source, to: .mpeg4Movie, more: [.film(film)])[0]
    let length = try await seconds(made)
    XCTAssertEqual(length, 1.5, accuracy: 0.15)
  }

  func test_aPartBegunInTheMiddleOfASentence() async throws {
    try requireTools()
    let film = try await Fixture.video(at: path("film.mp4"), seconds: 5)
    let words = path("w.srt"), source = path("in.mkv")
    try "1\n00:00:00,000 --> 00:00:02,000\nHonk\n\n2\n00:00:03,000 --> 00:00:03,500\nTwo\n".write(to: words, atomically: true, encoding: .utf8)
    try ExternalTools.run(try XCTUnwrap(ExternalTools.locate("ffmpeg")), [
      "-v", "error", "-y", "-i", film.path, "-i", words.path, "-map", "0", "-map", "1", "-c", "copy", "-c:s", "srt", source.path,
    ])
    let made = try await run(["trim1-4"], on: source)[0]
    XCTAssertEqual(try XCTUnwrap(Double(try probe(made, ["-select_streams", "v", "-show_entries", "stream=start_time"]))), 0, accuracy: 0.05)
    XCTAssertEqual(try probe(made, ["-select_streams", "s", "-show_entries", "stream=codec_name"]), "subrip")
  }

  func test_twoPassesOfHEVCInAFolderWithAColon() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    var film = FilmSettings()
    film.encoder = .hevc
    film.rate = .kilobits(300)
    film.isTwoPass = true
    let out = try folder("two: passes")
    let preset = RulePreset(name: "t", description: "", category: .video, actions: [.convertFormat(to: .mpeg4Movie), .film(film)])
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: out
    ) { _ in }
    XCTAssertEqual(contents(of: out), [try XCTUnwrap(entry.outputURL).lastPathComponent])
    let left = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("forge-pass-") }
    XCTAssertEqual(left, [])
  }

  func test_matroskaKeepsItsSound() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    let mkv = try XCTUnwrap(UTType(filenameExtension: "mkv"))
    for more in [[Forge.Operation](), [.film(FilmSettings())]] {
      let made = try await run([], on: source, to: mkv, more: more)[0]
      XCTAssertEqual(try probe(made, ["-select_streams", "a", "-show_entries", "stream=codec_name"]), "aac")
    }
  }

  func test_hevcIsWhatQuickTimeTakes() async throws {
    try requireTools()
    let source = path("a.mkv")
    try ExternalTools.run(try XCTUnwrap(ExternalTools.locate("ffmpeg")), [
      "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=1:s=320x240", "-c:v", "libx264", "-pix_fmt", "yuv444p", source.path,
    ])
    var film = FilmSettings()
    film.encoder = .hevc
    let made = try await run([], on: source, to: .mpeg4Movie, more: [.film(film)])[0]
    XCTAssertEqual(try probe(made, ["-show_entries", "stream=pix_fmt"]), "yuv420p")
  }

  /// A film with few whole pictures in it, and black round all of them.
  func test_blackBarsOfAFilmWithTwoKeyframes() async throws {
    try requireTools()
    let source = path("a.mp4")
    try ExternalTools.run(try XCTUnwrap(ExternalTools.locate("ffmpeg")), [
      "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=2:s=320x160:r=25", "-vf", "pad=320:240:0:40", "-g", "25", "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path,
    ])
    let bars = ExternalBridge.blackBars(of: source, ffmpeg: try XCTUnwrap(ExternalTools.locate("ffmpeg")))
    XCTAssertEqual(bars, "crop=320:160:0:40")
  }
}

@MainActor
final class AskSessionReviewTests: ToolTestCase {
  private func session(_ convert: @escaping AskCenter.Convert) throws -> AskSession {
    let file = try Fixture.image(at: path("a.png"))
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: try ProcessableFile(url: file), convert: convert)
    session.choose(.format(.jpeg), for: .format)
    return session
  }

  func test_startedTwiceItRunsOnce() async throws {
    var runs = 0
    let session = try session { _, _ in runs += 1; return [] }
    session.start()
    session.start()
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(runs, 1)
  }

  func test_theBarFollows() async throws {
    var seen: [Double] = []
    var held: AskSession?
    let session = try session { _, _ in
      AskSession.progress?(0.5)
      try await Task.sleep(nanoseconds: 200_000_000)
      if case .working(let share) = held?.state { seen.append(share) }
      return []
    }
    held = session
    await session.run()
    XCTAssertEqual(seen, [0.5])
  }
}
