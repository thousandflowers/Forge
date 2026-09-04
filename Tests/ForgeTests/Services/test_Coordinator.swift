import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import Forge

/// Cancelling, and the bookkeeping around a conversion.
final class CoordinatorTests: BaseTestCase {

  /// Cancelling has to reach the work in flight, and whatever it was writing
  /// must not be left lying in the destination.
  func test_cancel_leavesNoScratchBehind() async throws {
    let source = try await Fixture.video(
      at: path("long.mp4"),
      seconds: 4,
      size: CGSize(width: 1280, height: 720)
    )
    let destination = try folder("out")
    let coordinator = coordinator()

    let work = Task {
      try await coordinator.processFile(
        try ProcessableFile(url: source),
        with: .make(format: .mov, category: .video),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
    }

    try await Task.sleep(nanoseconds: 150_000_000)
    await coordinator.cancelAll()

    // Either outcome is fair - it may have finished first - but the folder must
    // never be left holding a half-written scratch file.
    _ = try? await work.value

    let leftovers = contents(of: destination)
    XCTAssertTrue(
      leftovers.allSatisfy { !$0.hasPrefix(".forge-") },
      "scratch files survived the cancel: \(leftovers)"
    )
    XCTAssertTrue(exists(source), "the source must survive a cancel")
  }

  /// Overwrite replaces the file it was handed. Another file that happens to
  /// hold the converted name is not part of that promise: it used to be
  /// replaced without a word, and without a backup, since the backup is taken
  /// of the source.
  func test_overwrite_leavesADifferentFileHoldingTheTargetNameAlone() async throws {
    let source = try Fixture.image(at: path("doc.png"), width: 64, height: 64)
    let bystander = try Fixture.image(at: path("doc.jpeg"), width: 400, height: 250)
    let before = try Data(contentsOf: bystander)

    let result = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, category: .image),
      destinationMode: .overwrite,
      destinationURL: nil
    ) { _ in }

    XCTAssertEqual(
      try Data(contentsOf: bystander), before,
      "a file nobody asked about was overwritten"
    )
    let output = try XCTUnwrap(result.outputURL)
    XCTAssertNotEqual(output, bystander)
    XCTAssertTrue(exists(output), "the conversion still has to land somewhere")
  }

  /// History is held in memory now; a reload has to agree with what was written.
  func test_history_survivesAppendAndReload() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 64, height: 64)
    let destination = try folder("out")
    let coordinator = coordinator()

    for _ in 0..<3 {
      _ = try await coordinator.processFile(
        try ProcessableFile(url: source),
        with: .make(format: .jpeg, quality: 80, category: .image),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
    }

    let cached = try await store.loadHistory()
    XCTAssertEqual(cached.count, 3)

    // A separate store reading the same directory must see the same log, which
    // is what proves the cache was written out and not just kept in memory.
    let reopened = PersistenceManager(root: store.root)
    let reloaded = try await reopened.loadHistory()
    XCTAssertEqual(reloaded.count, 3)
    XCTAssertEqual(reloaded.map(\.id), cached.map(\.id))
  }

  /// A watched folder receives whatever is dropped in it, so the message for a
  /// file the preset cannot handle has to name both ends of the conversion.
  func test_mismatchedConversion_saysWhatItCouldNotDo() async throws {
    let source = try Fixture.audio(at: path("tone.wav"), seconds: 1)
    let destination = try folder("out")

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: .jpeg, category: .image),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      XCTFail("an audio file cannot become a JPEG")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Forge cannot convert WAV to JPEG.")
    }
  }

  /// One unreadable file in the presets folder used to take every preset with
  /// it, leaving the app looking freshly installed.
  func test_presets_surviveAStrayFile() async throws {
    let preset = RulePreset.make(format: .jpeg, quality: 70, category: .image)
    try await store.savePreset(preset)
    try "not json".write(
      to: store.root.appendingPathComponent("Presets/broken.json"),
      atomically: true,
      encoding: .utf8
    )
    try Data("binary".utf8).write(to: store.root.appendingPathComponent("Presets/stray.txt"))

    let loaded = try await store.loadAllPresets()
    XCTAssertEqual(loaded.map(\.id), [preset.id])
  }
}

/// What the preset editor is allowed to offer.
final class OutputFormatTests: BaseTestCase {

  /// The picker used to offer MP3, which AVFoundation cannot encode, so saving
  /// that preset produced one that could never run.
  func test_neverOffersAFormatTheMachineCannotWrite() throws {
    let offered = OutputFormat.images + OutputFormat.audio + OutputFormat.video
    XCTAssertFalse(offered.isEmpty)

    for format in offered {
      let type = try XCTUnwrap(format.type)
      let writable = FormatCatalog.isWritableImage(type)
        || FormatCatalog.audioFormatID(for: type) != nil
        || FormatCatalog.isWritableVideo(type)
      XCTAssertTrue(writable, "\(format.label) is offered but cannot be written")
    }

    let mp3 = try XCTUnwrap(UTType(filenameExtension: "mp3"))
    XCTAssertFalse(offered.contains { $0.type == mp3 }, "MP3 is still on offer")
  }

  func test_offersTheObviousTargets() throws {
    XCTAssertTrue(OutputFormat.images.contains { $0.type == .jpeg })
    XCTAssertTrue(OutputFormat.audio.contains { $0.type == UTType("com.apple.m4a-audio") })
    XCTAssertTrue(OutputFormat.video.contains { $0.type == .mpeg4Movie })
  }
}

/// Reading a file's size must not be expensive at the moment it is added.
final class ProcessableFileTests: BaseTestCase {

  func test_imageDimensionsAreReadImmediately() throws {
    let url = try Fixture.image(at: path("photo.png"), width: 321, height: 123)
    let file = try ProcessableFile(url: url)
    XCTAssertEqual(file.dimensions, Dimensions(width: 321, height: 123))
  }

  /// Video sizes need the asset opened, so they arrive after the fact rather
  /// than freezing the window while a large batch is dropped in.
  func test_videoDimensionsArriveAsynchronously() async throws {
    let url = try await Fixture.video(
      at: path("clip.mp4"),
      seconds: 1,
      size: CGSize(width: 640, height: 360),
      withAudio: false
    )
    let file = try ProcessableFile(url: url)
    XCTAssertNil(file.dimensions, "opening the asset during init is what froze the window")

    let size = await ProcessableFile.videoDimensions(url: url, type: file.fileType)
    XCTAssertEqual(size, Dimensions(width: 640, height: 360))
  }

  func test_rejectsUnknownExtensions() throws {
    let url = path("mystery.zzzz")
    try Data("x".utf8).write(to: url)
    XCTAssertThrowsError(try ProcessableFile(url: url))
  }

  func test_rejectsMissingFiles() {
    XCTAssertThrowsError(try ProcessableFile(url: path("nope.png")))
  }
}
