import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import Forge

/// Turning text into speech, with the voices already installed.
final class SpeechSynthesisTests: BaseTestCase {

  /// A machine with no speech voices cannot be asked to speak; that is a skip
  /// rather than a failure, and CI runners are such machines.
  private func requireVoices() throws {
    try XCTSkipIf(SpeechSynthesis.voices.isEmpty, "no speech voices installed")
  }

  func test_textBecomesAudio() async throws {
    try requireVoices()
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
    try requireVoices()
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

  func test_theInstalledVoicesAreReported() throws {
    try requireVoices()
    XCTAssertFalse(SpeechSynthesis.languages.isEmpty)
  }

  /// A language without a region should still find a voice.
  func test_aLanguageWithoutARegionFindsAVoice() throws {
    try requireVoices()
    let italian = try XCTUnwrap(SpeechSynthesis.voice(for: "it"))
    XCTAssertTrue(italian.language.hasPrefix("it"), italian.language)
  }
}
