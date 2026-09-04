import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import Forge

/// Choosing the encoder, where the container holds more than one.
final class CodecTests: BaseTestCase {

  func test_theMachineReportsWhatItCanEncode() {
    XCTAssertFalse(Codec.available.isEmpty)
    XCTAssertTrue(Codec.available.contains(.h264), "H.264 is what every sized preset produces")
    XCTAssertTrue(Codec.available.contains(.aac))
  }

  /// Apple Lossless shares the .m4a container with AAC, which is exactly why
  /// it was unreachable before: the container alone could not say which.
  func test_appleLosslessFitsInM4A() async throws {
    try XCTSkipUnless(Codec.available.contains(.appleLossless), "no Apple Lossless encoder")

    let source = try Fixture.audio(at: path("tone.wav"), seconds: 2)
    let destination = try folder("out")
    let m4a = try XCTUnwrap(UTType("com.apple.m4a-audio"))

    var preset = RulePreset.make(format: m4a, category: .audio)
    preset.actions.append(.encode(codec: .appleLossless))

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let output = try XCTUnwrap(entry.outputURL)

    // Lossless of a two-second tone is far larger than the AAC of the same.
    var lossy = RulePreset.make(format: m4a, category: .audio)
    lossy.actions.append(.encode(codec: .aac))
    let aac = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: lossy,
      destinationMode: .copyTo,
      destinationURL: try folder("aac")
    ) { _ in }

    XCTAssertGreaterThan(size(of: output), size(of: try XCTUnwrap(aac.outputURL)))
  }

  /// A codec the container cannot hold has to say so, not write something else.
  func test_aCodecThatDoesNotFitIsRefused() async throws {
    let source = try Fixture.audio(at: path("tone.wav"), seconds: 1)
    let destination = try folder("out")

    var preset = RulePreset.make(format: .wav, category: .audio)
    preset.actions.append(.encode(codec: .aac))

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: preset,
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      XCTFail("AAC does not go in a WAV")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("AAC"), error.localizedDescription)
    }
  }

  /// Asking for ProRes must not be overruled by a size, which is how the
  /// preset was chosen before.
  func test_aNamedVideoCodecBeatsTheSizedPresets() async throws {
    try XCTSkipUnless(Codec.available.contains(.proRes422), "no ProRes encoder")

    let source = try await Fixture.video(
      at: path("clip.mov"),
      seconds: 1,
      size: CGSize(width: 320, height: 240),
      withAudio: false
    )
    let destination = try folder("out")

    var preset = RulePreset.make(
      format: .quickTimeMovie,
      resize: ResizeSpec(width: 320, height: 240, fitMode: .proportional),
      category: .video
    )
    preset.actions.append(.encode(codec: .proRes422))

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let track = try await AVURLAsset(url: try XCTUnwrap(entry.outputURL))
      .loadTracks(withMediaType: .video).first
    let descriptions = try await XCTUnwrap(track).load(.formatDescriptions)
    let subtype = try XCTUnwrap(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) })

    // ProRes 422 is 'apcn'; H.264 is 'avc1'.
    XCTAssertNotEqual(subtype, kCMVideoCodecType_H264, "the size preset overruled the codec")
  }

  func test_theChosenCodecPicksTheExportPreset() {
    XCTAssertEqual(Codec.hevc.exportPreset, AVAssetExportPresetHEVCHighestQuality)
    XCTAssertNil(Codec.h264.exportPreset, "H.264 is chosen by dimensions, not by name")
  }
}
