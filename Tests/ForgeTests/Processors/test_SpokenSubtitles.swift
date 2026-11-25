import XCTest
import Speech
import UniformTypeIdentifiers
@testable import Forge

/// Subtitles made from what was said.
final class SpokenSubtitleTests: BaseTestCase {
  private func words(_ text: String, every step: Double = 0.4, from start: Double = 0) -> [Transcription.Word] {
    text.split(separator: " ").enumerated().map { .init(text: String($1), start: start + Double($0) * step, duration: step * 0.9) }
  }

  func test_aPauseStartsANewCue() {
    let cues = Subtitles.cues(from: words("Hello there goose") + words("Goodbye now duck", from: 5))
    XCTAssertEqual(cues.map(\.text), ["Hello there goose", "Goodbye now duck"])
    XCTAssertEqual(cues[0].start, 0, accuracy: 0.001)
    XCTAssertEqual(cues[1].start, 5, accuracy: 0.001)
  }

  func test_theEndOfASentenceStartsANewCue() {
    XCTAssertEqual(Subtitles.cues(from: words("One goose. Two ducks.")).map(\.text), ["One goose.", "Two ducks."])
  }

  func test_noCueIsTooLongToRead() {
    let cues = Subtitles.cues(from: words(Array(repeating: "wandering", count: 120).joined(separator: " ")))
    XCTAssertGreaterThan(cues.count, 5)
    for cue in cues {
      XCTAssertLessThanOrEqual(cue.end - cue.start, Subtitles.longestCue + 0.5)
      for line in cue.text.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, Subtitles.longestLine) }
      XCTAssertLessThanOrEqual(cue.text.split(separator: "\n").count, 2)
    }
  }

  /// A sentence a word too long for one cue is two halves, not one cue and a
  /// word left over.
  func test_noWordIsLeftOnItsOwn() {
    let cues = Subtitles.cues(from: words("This is sentence number one the goose walked to the lake and said hello to the dock.", every: 0.28))
    XCTAssertEqual(cues.count, 2)
    for cue in cues { XCTAssertGreaterThan(cue.text.count, 25, cue.text) }
  }

  func test_cuesDoNotOverlap() {
    let cues = Subtitles.cues(from: words(Array(repeating: "goose", count: 90).joined(separator: " ")))
    for (one, next) in zip(cues, cues.dropFirst()) { XCTAssertLessThanOrEqual(one.end, next.start + 0.0001) }
  }

  func test_everyWordIsKeptInOrder() {
    let said = words("The goose walked to the lake and said hello to the duck and went home again")
    XCTAssertEqual(Subtitles.cues(from: said).flatMap { $0.text.split { $0 == " " || $0 == "\n" } }.map(String.init), said.map(\.text))
  }

  func test_nothingSaidIsNoCues() { XCTAssertTrue(Subtitles.cues(from: []).isEmpty) }

  /// The whole way: a recording in, a subtitle file with times out.
  func test_aRecordingBecomesASubtitleFile() async throws {
    try XCTSkipUnless(SFSpeechRecognizer.authorizationStatus() == .authorized, "speech recognition not authorised on this machine")
    let spoken = path("spoken.aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Samantha", "-o", spoken.path, "The goose walked to the lake. [[slnc 1500]] Then it went home again."]
    try say.run()
    say.waitUntilExit()

    let srt = try XCTUnwrap(OutputFormat.subtitles.first { $0.label == "SRT" }?.type)
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: spoken),
      with: RulePreset(name: "t", description: "", category: .audio, actions: [.convertFormat(to: srt), .recognizeText(languages: ["en-US"])]),
      destinationMode: .copyTo, destinationURL: try folder("out")
    ) { _ in }

    let cues = try Subtitles.read(XCTUnwrap(entry.outputURL))
    XCTAssertGreaterThanOrEqual(cues.count, 2, "the silence between them is where one ends")
    XCTAssertTrue(cues[0].text.lowercased().contains("goose"), cues[0].text)
    XCTAssertGreaterThan(cues[1].start, cues[0].end - 0.01)
  }

  /// A recording and a film can become subtitles, with no tool installed.
  func test_subtitlesAreOfferedForSoundAndFilm() {
    for kind in [ConvertKind.audio, .video] {
      XCTAssertTrue(kind.outputGroups.flatMap(\.formats).contains { $0.label == "SRT" }, kind.title)
    }
  }

  func test_aRecordingCanBecomeASubtitle() throws {
    let sound = path("a.wav")
    try Fixture.audio(at: sound, seconds: 1)
    let srt = try XCTUnwrap(OutputFormat.subtitles.first { $0.label == "SRT" }?.type)
    XCTAssertTrue(Conversions.can(try ProcessableFile(url: sound), become: srt))
  }
}
