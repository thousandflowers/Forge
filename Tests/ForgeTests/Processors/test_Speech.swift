import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import Forge

/// Turning text into speech, with the voices already installed.
final class SpeechSynthesisTests: BaseTestCase {

  func test_textBecomesAudio() async throws {
    let source = path("notes.txt")
    try "Forge converts files without any dependencies at all."
      .write(to: source, atomically: true, encoding: .utf8)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType("com.apple.m4a-audio")), category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertGreaterThan(size(of: output), 0)

    let asset = AVURLAsset(url: output)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(tracks.count, 1)

    // Long enough to be the sentence rather than a click.
    let duration = try await asset.load(.duration).seconds
    XCTAssertGreaterThan(duration, 1.0)
  }

  func test_anEmptyDocumentSaysSoRatherThanWritingSilence() async throws {
    let source = path("empty.txt")
    try "   \n  ".write(to: source, atomically: true, encoding: .utf8)
    let destination = try folder("out")

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: try XCTUnwrap(UTType("com.apple.m4a-audio")), category: .document),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      XCTFail("there is nothing to speak")
    } catch {
      XCTAssertTrue(error.localizedDescription.lowercased().contains("no text"), error.localizedDescription)
    }
  }

  func test_theInstalledVoicesAreReported() {
    XCTAssertFalse(SpeechSynthesis.voices.isEmpty)
    XCTAssertFalse(SpeechSynthesis.languages.isEmpty)
  }

  /// A language without a region should still find a voice.
  func test_aLanguageWithoutARegionFindsAVoice() throws {
    let italian = try XCTUnwrap(SpeechSynthesis.voice(for: "it"))
    XCTAssertTrue(italian.language.hasPrefix("it"), italian.language)
  }
}
