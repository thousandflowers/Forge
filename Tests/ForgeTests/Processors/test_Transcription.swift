import XCTest
import Speech
import UniformTypeIdentifiers
@testable import Forge

/// Turning a recording into text, on device.
final class TranscriptionTests: BaseTestCase {

  func test_theRecognisersLocalesAreReported() {
    XCTAssertFalse(Transcription.supportedLocales.isEmpty)
    XCTAssertTrue(Transcription.supports("en-US"))
  }

  /// A language without a region should still match.
  func test_aLanguageWithoutARegionMatches() {
    XCTAssertTrue(Transcription.supports("it"))
  }

  /// The language is checked before permission is asked, so a typo is answered
  /// straight away rather than after a prompt.
  func test_anUnknownLocaleIsRefusedWithoutAskingForPermission() async throws {
    let source = try Fixture.audio(at: path("tone.wav"), seconds: 1)

    do {
      _ = try await Transcription.text(of: source, locale: "zz-ZZ") { _ in }
      XCTFail("there is no zz-ZZ recogniser")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("zz-ZZ"), error.localizedDescription)
    }
  }

  /// The pipeline itself is not exercised here. Recognition is permission
  /// gated and slow - ninety seconds on a recording with no words in it - so
  /// running it in the suite would trade a great deal of time for very little.
  /// What is checked is everything around it that can go wrong quickly.
  func test_recognitionIsBounded() async throws {
    try XCTSkipUnless(
      SFSpeechRecognizer.authorizationStatus() == .authorized,
      "speech recognition not authorised on this machine"
    )

    let source = try Fixture.audio(at: path("tone.wav"), seconds: 1)
    let started = Date()

    // A pure tone has no words. Whatever comes back, it has to come back.
    _ = try? await Transcription.text(of: source, locale: "en-US") { _ in }

    XCTAssertLessThan(
      Date().timeIntervalSince(started),
      120,
      "recognition ran past its own deadline"
    )
  }

  /// A batch hands the recogniser several recordings at once, and it answered
  /// some of them "No speech detected" - which ones depended on the timing.
  /// Measured on 22 formats of one spoken sentence, four at a time: 12 refused,
  /// all of which transcribe when asked alone.
  func test_severalRecordingsAtOnceAreAllTranscribed() async throws {
    try XCTSkipUnless(
      SFSpeechRecognizer.authorizationStatus() == .authorized,
      "speech recognition not authorised on this machine"
    )
    let spoken = path("spoken.aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Samantha", "-o", spoken.path, "The quick brown fox jumps over the lazy dog."]
    try say.run()
    say.waitUntilExit()
    let copies = try (0..<6).map { index -> URL in
      let copy = path("spoken-\(index).aiff")
      try FileManager.default.copyItem(at: spoken, to: copy)
      return copy
    }

    let answers = await withTaskGroup(of: Result<String, Error>.self) { group in
      for copy in copies {
        group.addTask {
          do { return .success(try await Transcription.text(of: copy, locale: "en-US") { _ in }) }
          catch { return .failure(error) }
        }
      }
      var all: [Result<String, Error>] = []
      for await answer in group { all.append(answer) }
      return all
    }

    for answer in answers {
      switch answer {
      case .success(let text): XCTAssertTrue(text.lowercased().contains("fox"), text)
      case .failure(let error): XCTFail("one of six said: \(error.localizedDescription)")
      }
    }
  }
}
