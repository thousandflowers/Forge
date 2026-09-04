import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import Forge

/// Where output goes, and what happens to the file the user already had.
final class OutputHandlingTests: BaseTestCase {

  /// Converting in place read and wrote the same URL, which truncated the
  /// source mid-read: a 100 KB PNG came back as 27 KB of JPEG bytes still
  /// called `.png`, and the original was gone.
  func test_overwrite_doesNotDestroyTheOriginal() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 600, height: 400)
    let originalBytes = try Data(contentsOf: source)

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 70, category: .image),
      destinationMode: .overwrite
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    // The format changed, so the name must change with it.
    XCTAssertEqual(output.pathExtension, "jpeg")
    XCTAssertTrue(exists(output))

    let written = try Data(contentsOf: output)
    XCTAssertEqual(Array(written.prefix(2)), [0xFF, 0xD8], "the output is not a JPEG")
    XCTAssertNotEqual(written, originalBytes)
    XCTAssertFalse(exists(source), "the .png should have been replaced, not left behind broken")
  }

  /// A PNG converted to PNG stays exactly where it was, and stays valid.
  func test_overwrite_inPlaceKeepsAValidFile() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 300, height: 300)

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .png, resize: ResizeSpec(width: 150, height: 150, fitMode: .proportional), category: .image),
      destinationMode: .overwrite
    ) { _ in }

    XCTAssertEqual(try XCTUnwrap(entry.outputURL).path, source.path)
    let bytes = try Data(contentsOf: source)
    XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "the file is no longer a PNG")
    XCTAssertEqual(try ProcessableFile(url: source).dimensions?.width, 150)
  }

  /// The backup toggle was on by default and read by nobody.
  func test_overwrite_writesABackupWhenAsked() async throws {
    let source = try Fixture.image(at: path("keepme.png"), width: 120, height: 120)
    let originalBytes = try Data(contentsOf: source)

    var settings = AppSettings()
    settings.createBackupBeforeOverwrite = true

    _ = try await coordinator(settings: settings).processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 60, category: .image),
      destinationMode: .overwrite
    ) { _ in }

    let backups = store.backupsDirectory
    let saved = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
      .filter { $0.hasPrefix("keepme-") }
    XCTAssertFalse(saved.isEmpty, "no backup was written")

    let restored = try Data(contentsOf: backups.appendingPathComponent(try XCTUnwrap(saved.first)))
    XCTAssertEqual(restored, originalBytes, "the backup is not the original file")
  }

  /// Two sources converging on one output name left a single file behind, with
  /// both files reported as converted.
  func test_collidingNames_produceSeparateFiles() async throws {
    let first = try Fixture.image(at: try folder("a").appendingPathComponent("photo.png"), width: 100, height: 100)
    let second = try Fixture.image(at: try folder("b").appendingPathComponent("photo.tiff"), width: 120, height: 120)
    let destination = try folder("out")

    let coordinator = coordinator()
    for source in [first, second] {
      _ = try await coordinator.processFile(
        try ProcessableFile(url: source),
        with: .make(format: .jpeg, quality: 80, category: .image),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
    }

    XCTAssertEqual(contents(of: destination).count, 2, "one conversion overwrote the other")
  }

  /// "Move to" ran the same code as "Copy to" and left every original in place.
  func test_moveTo_removesTheOriginal() async throws {
    let source = try Fixture.image(at: path("moving.png"), width: 100, height: 100)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 80, category: .image),
      destinationMode: .moveTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertTrue(exists(try XCTUnwrap(entry.outputURL)))
    XCTAssertFalse(exists(source), "the original is still there after a move")
  }

  func test_copyTo_keepsTheOriginal() async throws {
    let source = try Fixture.image(at: path("staying.png"), width: 100, height: 100)
    let destination = try folder("out")

    _ = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 80, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertTrue(exists(source), "a copy should not remove the original")
  }

  /// A failed conversion must not leave scratch or zero-byte files behind.
  func test_failedConversion_leavesNothingBehind() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 100, height: 100)
    let destination = try folder("out")

    // ICNS cannot hold an arbitrary bitmap, so this fails inside the encoder.
    let unwritable = try XCTUnwrap(UTType("com.apple.icns"))
    _ = try? await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: unwritable, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertTrue(exists(source), "the source must survive a failed conversion")
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
    XCTAssertTrue(
      leftovers.allSatisfy { !$0.hasPrefix(".forge-") },
      "scratch files survived the failure: \(leftovers)"
    )
  }

  func test_missingDestinationFolder_reportsAClearError() async throws {
    let source = try Fixture.image(at: path("photo.png"))

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: .jpeg, category: .image),
        destinationMode: .copyTo,
        destinationURL: nil
      ) { _ in }
      XCTFail("a copy with no destination should fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.lowercased().contains("destination"))
    }
  }
}

/// What Forge claims it can handle has to match what the machine can do.
final class FormatCatalogTests: BaseTestCase {

  /// These were declared with invented UTI strings that resolve to nil, so the
  /// formats were silently unsupported.
  func test_wavAndFlacAreRecognised() throws {
    let wav = try XCTUnwrap(UTType(filenameExtension: "wav"))
    let flac = try XCTUnwrap(UTType(filenameExtension: "flac"))
    // The old code asked for "public.wav" and "public.flac", which are not
    // the real identifiers, so both resolved to nil and every such file was
    // rejected before it reached a processor.
    XCTAssertEqual(wav.identifier, "com.microsoft.waveform-audio")
    XCTAssertEqual(flac.identifier, "org.xiph.flac")
    XCTAssertTrue(FormatCatalog.isReadableMedia(wav))
    XCTAssertTrue(FormatCatalog.isReadableMedia(flac))
  }

  func test_wavIsAcceptedByAProcessor() throws {
    let source = try Fixture.audio(at: path("tone.wav"), seconds: 1)
    let file = try ProcessableFile(url: source)
    XCTAssertTrue(MediaProcessor().canProcess(file), "WAV was rejected outright")
  }

  /// Nothing may claim a format the host cannot encode.
  func test_writableImageTypesComeFromImageIO() {
    XCTAssertFalse(FormatCatalog.writableImageTypes.isEmpty)
    XCTAssertTrue(FormatCatalog.writableImageTypes.contains(.jpeg))
    XCTAssertFalse(FormatCatalog.writableImageTypes.contains(UTType("org.webmproject.webp")!))
  }

  /// Every audio container offered is verified against the running system, so
  /// the list cannot contain something that fails at write time.
  func test_writableAudioTypesAreAllUsable() throws {
    XCTAssertFalse(FormatCatalog.writableAudioTypes.isEmpty)
    for (type, _) in FormatCatalog.writableAudioTypes {
      XCTAssertNotNil(FormatCatalog.audioFormatID(for: type), "\(type.identifier) has no codec")
    }
  }

  /// AVFoundation has no MP3 encoder; the default preset used to promise one
  /// and produce AAC in a file named `.mp3`.
  func test_mp3IsNotOfferedAsOutput() throws {
    let mp3 = try XCTUnwrap(UTType(filenameExtension: "mp3"))
    XCTAssertNil(FormatCatalog.audioFormatID(for: mp3))
  }

  func test_defaultPresetsOnlyTargetWritableFormats() async {
    for preset in await AppModel.defaultPresets {
      guard let format = preset.targetFormat else { continue }
      let writable = FormatCatalog.isWritableImage(format)
        || FormatCatalog.audioFormatID(for: format) != nil
        || FormatCatalog.isWritableVideo(format)
      XCTAssertTrue(writable, "“\(preset.name)” targets \(format.identifier), which cannot be written")
    }
  }
}

/// Presets turn into the operations the processors read.
final class RulePresetTests: BaseTestCase {

  func test_toOperations_isEmptyWhenNothingIsAsked() {
    XCTAssertTrue(RulePreset.make().toOperations().isEmpty)
  }

  func test_toOperations_producesConvertResizeQualityAndFilters() {
    let operations = RulePreset.make(
      format: .jpeg,
      resize: ResizeSpec(width: 100, height: 50, fitMode: .stretch),
      quality: 70,
      filters: [.grayscale]
    ).toOperations()

    XCTAssertEqual(operations.map(\.id), ["convert", "resize", "quality", "filter"])
  }
}
