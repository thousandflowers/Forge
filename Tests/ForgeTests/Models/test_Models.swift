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

/// Files written by an older version have to keep loading.
///
/// The cleanup removed `icon`, `applicableFileTypes` and `targetSize` from
/// presets and turned several `let`s into `var`s with defaults; none of that is
/// allowed to strand data already sitting in Application Support.
final class StoredDataCompatibilityTests: BaseTestCase {

  func test_decodesAPresetWrittenByAnOlderVersion() throws {
    let json = """
    {
      "id": "9119C08A-FDC7-439F-A07A-FBAEF1DA5698",
      "name": "Audio to MP3",
      "description": "Convert audio tracks to MP3.",
      "filters": [],
      "category": "audio",
      "icon": "waveform",
      "targetSize": 5242880,
      "applicableFileTypes": [{ "identifier": "public.mp3" }],
      "targetFormat": { "identifier": "public.mp3", "constantIndex": 88 }
    }
    """
    let preset = try JSONDecoder().decode(RulePreset.self, from: Data(json.utf8))
    XCTAssertEqual(preset.id.uuidString, "9119C08A-FDC7-439F-A07A-FBAEF1DA5698")
    XCTAssertEqual(preset.name, "Audio to MP3")
    XCTAssertEqual(preset.category, .audio)
    XCTAssertEqual(preset.targetFormat?.identifier, "public.mp3")
    XCTAssertTrue(preset.filters.isEmpty)
    XCTAssertTrue(preset.ocrLanguages.isEmpty, "a field added later must default, not fail")
  }

  /// Adding a field to a preset must never strand the ones already saved. The
  /// synthesized decoder does not fall back to property defaults, so this is
  /// the guard that catches the next one.
  func test_aPresetMissingEveryOptionalFieldStillDecodes() throws {
    let json = """
    { "name": "Bare", "category": "image" }
    """
    let preset = try JSONDecoder().decode(RulePreset.self, from: Data(json.utf8))
    XCTAssertEqual(preset.name, "Bare")
    XCTAssertEqual(preset.category, .image)
    XCTAssertTrue(preset.filters.isEmpty)
    XCTAssertTrue(preset.ocrLanguages.isEmpty)
    XCTAssertNil(preset.targetFormat)
  }

  func test_decodesHistoryWrittenByAnOlderVersion() throws {
    let json = """
    [{
      "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
      "fileURL": "file:///tmp/photo.png",
      "timestamp": 750000000,
      "status": "completed",
      "duration": 0.25,
      "outputURL": "file:///tmp/photo.jpeg"
    }]
    """
    let history = try JSONDecoder().decode([ProcessingHistory].self, from: Data(json.utf8))
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].status, .completed)
    XCTAssertNil(history[0].ruleId)
    XCTAssertEqual(history[0].outputURL?.lastPathComponent, "photo.jpeg")
  }

  func test_decodesAMonitoredFolderWrittenByAnOlderVersion() throws {
    let json = """
    [{
      "id": "5874EC42-68BA-4690-BC59-EE992819D8B3",
      "url": "file:///tmp/watch/",
      "ruleId": "76164EB3-A7E5-4110-9F6D-FD8708259E6B",
      "destinationMode": "copy_to",
      "destinationURL": "file:///tmp/out/",
      "isActive": true,
      "includeSubfolders": false
    }]
    """
    let folders = try JSONDecoder().decode([MonitoredFolder].self, from: Data(json.utf8))
    XCTAssertEqual(folders.count, 1)
    XCTAssertEqual(folders[0].destinationMode, .copyTo)
    XCTAssertTrue(folders[0].isActive)
  }

  /// A round trip through the store has to survive, since that is what the app
  /// does on every launch.
  func test_presetSurvivesASaveAndLoad() async throws {
    let preset = RulePreset.make(
      format: .jpeg,
      resize: ResizeSpec(width: 800, height: nil, fitMode: .pad),
      quality: 64,
      filters: [.sepia, .invert],
      category: .image
    )
    try await store.savePreset(preset)

    let reopened = PersistenceManager(root: store.root)
    let loaded = try await reopened.loadAllPresets()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded[0], preset)
  }
}

/// A preset is a chain of actions now, and the ones already saved have to
/// become one without anybody noticing.
final class ActionChainTests: BaseTestCase {

  func test_theChainRunsInTheOrderItIsWritten() {
    let preset = RulePreset(
      name: "Chain",
      description: "",
      category: .image,
      actions: [
        .filter(type: .sepia),
        .resize(width: 100, height: 100, fitMode: .pad),
        .convertFormat(to: .png),
      ]
    )
    XCTAssertEqual(preset.toOperations().map(\.id), ["filter", "resize", "convert"])
  }

  /// Two filters were impossible when a preset was a form with one slot each.
  func test_aChainCanRepeatAnAction() {
    let preset = RulePreset(
      name: "Twice",
      description: "",
      category: .image,
      actions: [.filter(type: .grayscale), .filter(type: .blur)]
    )
    XCTAssertEqual(preset.filters, [.grayscale, .blur])
  }

  func test_theFormConvenienceBuildsASensibleOrder() {
    let preset = RulePreset.make(
      format: .jpeg,
      resize: ResizeSpec(width: 800, height: 600, fitMode: .proportional),
      quality: 70,
      filters: [.sepia]
    )
    XCTAssertEqual(preset.toOperations().map(\.id), ["convert", "resize", "quality", "filter"])
  }

  /// A preset written before actions existed carries separate fields; it has
  /// to arrive as the equivalent chain.
  func test_aPresetSavedBeforeActionsBecomesAChain() throws {
    let json = """
    {
      "id": "3E47AB3D-74A6-4B5D-9AE1-1A47C25CFDC2",
      "name": "Instagram Square",
      "description": "1080x1080 JPEG, center-cropped.",
      "category": "image",
      "quality": 85,
      "filters": ["sepia"],
      "resize": { "width": 1080, "height": 1080, "fitMode": "cropCenter" },
      "targetFormat": { "identifier": "public.jpeg", "constantIndex": 57 }
    }
    """
    let preset = try JSONDecoder().decode(RulePreset.self, from: Data(json.utf8))

    XCTAssertEqual(preset.name, "Instagram Square")
    XCTAssertEqual(preset.toOperations().map(\.id), ["convert", "resize", "quality", "filter"])
    XCTAssertEqual(preset.targetFormat, .jpeg)
    XCTAssertEqual(preset.resize?.width, 1080)
    XCTAssertEqual(preset.resize?.fitMode, .cropCenter)
    XCTAssertEqual(preset.quality, 85)
    XCTAssertEqual(preset.filters, [.sepia])
  }

  func test_aChainSurvivesASaveAndLoad() async throws {
    let preset = RulePreset(
      name: "Round trip",
      description: "",
      category: .custom,
      actions: [
        .convertFormat(to: .plainText),
        .recognizeText(languages: ["it-IT"]),
        .quality(level: 42),
      ]
    )
    try await store.savePreset(preset)

    let reopened = PersistenceManager(root: store.root)
    let loaded = try await reopened.loadAllPresets()
    XCTAssertEqual(loaded, [preset])
    XCTAssertEqual(loaded.first?.ocrLanguages, ["it-IT"])
  }
}

/// Naming, where it says something the user needs.
final class OutputNamingTests: BaseTestCase {

  /// Converting one picture to three sizes used to give photo.jpg, photo 2.jpg
  /// and photo 3.jpg, which says nothing about which is which.
  func test_aResizePutsItsSizeInTheName() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 800, height: 600)
    let destination = try folder("out")
    let coordinator = coordinator()

    for width in [1280, 640, 320] {
      _ = try await coordinator.processFile(
        try ProcessableFile(url: source),
        with: .make(
          format: .jpeg,
          resize: ResizeSpec(width: width, height: width, fitMode: .proportional),
          quality: 80,
          category: .image
        ),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
    }

    XCTAssertEqual(contents(of: destination), ["photo-1280.jpeg", "photo-320.jpeg", "photo-640.jpeg"])
  }

  func test_noResizeMeansNoSuffix() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 100, height: 100)
    let destination = try folder("out")

    _ = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 80, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(contents(of: destination), ["photo.jpeg"])
  }

  /// Converting in place means the file stays where it is, under the name it
  /// has, resize or not.
  func test_convertingInPlaceKeepsTheName() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 400, height: 400)

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .png, resize: ResizeSpec(width: 200, height: 200, fitMode: .proportional), category: .image),
      destinationMode: .overwrite
    ) { _ in }

    XCTAssertEqual(try XCTUnwrap(entry.outputURL).lastPathComponent, "photo.png")
  }
}

/// Icon files carry several resolutions.
final class IconTests: BaseTestCase {

  func test_anIconGetsTheWholeLadder() async throws {
    let source = try Fixture.image(at: path("mark.png"), width: 512, height: 512)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "ico")), category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let icon = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(entry.outputURL) as CFURL, nil))
    XCTAssertGreaterThan(CGImageSourceGetCount(icon), 1, "one picture in an .ico is not an icon")
  }

  /// The encoder refuses anything that is not square, and most pictures are
  /// not. A wide source used to fail outright.
  func test_aWideSourceStillMakesAnIcon() async throws {
    let source = try Fixture.image(at: path("wide.png"), width: 800, height: 600)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "ico")), category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let icon = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(entry.outputURL) as CFURL, nil))
    XCTAssertGreaterThan(CGImageSourceGetCount(icon), 1)

    for index in 0..<CGImageSourceGetCount(icon) {
      let properties = CGImageSourceCopyPropertiesAtIndex(icon, index, nil) as? [CFString: Any]
      let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
      let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
      XCTAssertEqual(width, height, "an icon image has to be square")
      XCTAssertLessThanOrEqual(width, 256, "the encoder refuses anything larger")
    }
  }

  /// A small source must not be enlarged to fill the ladder.
  func test_aSmallSourceIsNotBlownUp() async throws {
    let source = try Fixture.image(at: path("tiny.png"), width: 24, height: 24)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "ico")), category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let icon = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(entry.outputURL) as CFURL, nil))
    for index in 0..<CGImageSourceGetCount(icon) {
      let properties = CGImageSourceCopyPropertiesAtIndex(icon, index, nil) as? [CFString: Any]
      let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
      XCTAssertLessThanOrEqual(width, 24, "the source was enlarged")
    }
  }
}

/// Presets travel between machines.
final class PresetSharingTests: BaseTestCase {

  func test_presetsSurviveARoundTripThroughAFile() async throws {
    let presets = [
      RulePreset(name: "One", description: "", category: .image,
                 actions: [.convertFormat(to: .jpeg), .quality(level: 64)]),
      RulePreset(name: "Two", description: "", category: .audio,
                 actions: [.encode(codec: .aac)]),
    ]
    let file = path("presets.json")

    try await store.export(presets, to: file)
    let read = try await store.importPresets(from: file)

    XCTAssertEqual(read, presets)
  }

  /// People share one preset as often as a set, so both shapes are accepted.
  func test_asinglePresetInAFileIsAccepted() async throws {
    let file = path("one.json")
    let json = """
    { "name": "Solo", "description": "", "category": "image",
      "actions": [ { "kind": "quality", "level": 50 } ] }
    """
    try json.write(to: file, atomically: true, encoding: .utf8)

    let read = try await store.importPresets(from: file)
    XCTAssertEqual(read.count, 1)
    XCTAssertEqual(read.first?.name, "Solo")
    XCTAssertEqual(read.first?.quality, 50)
  }

  func test_theFinishedMessageCountsBoth() {
    XCTAssertEqual(Notifier.summary(converted: 1, failed: 0), "1 file converted.")
    XCTAssertEqual(Notifier.summary(converted: 4, failed: 0), "4 files converted.")
    XCTAssertEqual(Notifier.summary(converted: 3, failed: 1), "3 files converted, 1 failed.")
  }
}

/// Adjusting a preset for one batch, without editing the saved one.
final class PresetAdjustmentTests: BaseTestCase {

  func test_replacingSwapsTheActionOfThatKind() {
    let preset = RulePreset(
      name: "Base", description: "", category: .image,
      actions: [.convertFormat(to: .jpeg), .quality(level: 80)]
    )
    let adjusted = preset.replacing(.quality(level: 40))

    XCTAssertEqual(adjusted.quality, 40)
    XCTAssertEqual(adjusted.actions.count, 2, "it replaced rather than piling one on")
    XCTAssertEqual(preset.quality, 80, "the original is untouched")
  }

  func test_replacingAddsWhenThereIsNoneOfThatKind() {
    let preset = RulePreset(name: "Base", description: "", category: .image,
                            actions: [.convertFormat(to: .jpeg)])
    let adjusted = preset.replacing(.resize(width: 640, height: nil, fitMode: .proportional))

    XCTAssertEqual(adjusted.resize?.width, 640)
    XCTAssertEqual(adjusted.actions.count, 2)
  }

  /// The order the chain runs in must survive an adjustment.
  func test_replacingKeepsThePosition() {
    let preset = RulePreset(
      name: "Base", description: "", category: .image,
      actions: [.quality(level: 80), .convertFormat(to: .jpeg), .filter(type: .sepia)]
    )
    let adjusted = preset.replacing(.quality(level: 30))
    XCTAssertEqual(adjusted.actions.map(\.id), ["quality", "convert", "filter"])
  }

  func test_removingTakesTheActionOut() {
    let preset = RulePreset(name: "Base", description: "", category: .image,
                            actions: [.convertFormat(to: .jpeg), .quality(level: 80)])
    XCTAssertNil(preset.removing("quality").quality)
  }
}

/// The order presets appear in, which is the order somebody put them in.
final class PresetOrderTests: BaseTestCase {

  private func presets(_ names: [String]) -> [RulePreset] {
    names.enumerated().map { index, name in
      RulePreset(name: name, description: "", category: .image, position: index)
    }
  }

  func test_positionDecidesTheOrder() {
    let out = AppModel.ordered([
      RulePreset(name: "Zebra", description: "", category: .image, position: 0),
      RulePreset(name: "Apple", description: "", category: .image, position: 1),
    ])
    XCTAssertEqual(out.map(\.name), ["Zebra", "Apple"], "position beats the alphabet")
  }

  /// Until somebody moves something, every preset shares position zero, and
  /// the alphabet is the sensible tie-break.
  func test_namesBreakTheTie() {
    let out = AppModel.ordered([
      RulePreset(name: "Zebra", description: "", category: .image),
      RulePreset(name: "Apple", description: "", category: .image),
    ])
    XCTAssertEqual(out.map(\.name), ["Apple", "Zebra"])
  }

  @MainActor
  func test_movingRewritesEveryPosition() {
    let model = AppModel(persistence: store)
    model.presets = presets(["One", "Two", "Three"])

    model.movePreset(model.presets[2], by: -1)

    XCTAssertEqual(model.presets.map(\.name), ["One", "Three", "Two"])
    XCTAssertEqual(model.presets.map(\.position), [0, 1, 2], "positions must stay dense")
  }

  @MainActor
  func test_movingPastTheEndDoesNothing() {
    let model = AppModel(persistence: store)
    model.presets = presets(["One", "Two"])

    model.movePreset(model.presets[0], by: -1)
    model.movePreset(model.presets[1], by: 1)

    XCTAssertEqual(model.presets.map(\.name), ["One", "Two"])
  }

  /// A preset saved before order existed has no position, and must not be
  /// stranded by one appearing.
  func test_aPresetWithoutAPositionStillDecodes() throws {
    let json = """
    { "name": "Old", "category": "image", "actions": [] }
    """
    let preset = try JSONDecoder().decode(RulePreset.self, from: Data(json.utf8))
    XCTAssertEqual(preset.position, 0)
  }
}

/// What a batch cost, measured rather than guessed.
final class SavingReportTests: BaseTestCase {

  private func file(_ name: String, bytes: Int) throws -> ProcessableFile {
    let url = path(name)
    try Data(repeating: 0, count: bytes).write(to: url)
    // A .png that is not a PNG is fine here: only the size is read.
    return ProcessableFile(
      url: url, fileType: .png, fileName: name, fileSize: Int64(bytes), dimensions: nil
    )
  }

  func test_reportsHowMuchSmaller() throws {
    let source = try file("in.png", bytes: 1000)
    let output = path("out.jpeg")
    try Data(repeating: 0, count: 250).write(to: output)

    let saving = try XCTUnwrap(BatchViewModel.saving(from: [output], sources: [source]))
    XCTAssertTrue(saving.contains("75%"), saving)
    XCTAssertTrue(saving.contains("smaller"), saving)
  }

  /// A conversion can make a file bigger - PNG from JPEG, or lossless audio -
  /// and saying "0% smaller" would be a lie of omission.
  func test_reportsWhenItGotBigger() throws {
    let source = try file("in.jpeg", bytes: 100)
    let output = path("out.png")
    try Data(repeating: 0, count: 300).write(to: output)

    let saving = try XCTUnwrap(BatchViewModel.saving(from: [output], sources: [source]))
    XCTAssertTrue(saving.contains("larger"), saving)
  }

  func test_nothingConvertedMeansNothingToReport() throws {
    let source = try file("in.png", bytes: 100)
    XCTAssertNil(BatchViewModel.saving(from: [], sources: [source]))
  }
}

/// Nothing in the suite may write into the folder the app keeps for the person
/// using it. A test once left nine presets called One, Two and Three in it.
final class TestIsolationTests: BaseTestCase {

  @MainActor
  func test_theModelWritesWhereItIsTold() async throws {
    let model = AppModel(persistence: store)
    model.savePreset(RulePreset(name: "Scratch only", description: "", category: .image))

    // Give the write a moment to land, then look in both places.
    try await Task.sleep(nanoseconds: 300_000_000)

    let inScratch = try await store.loadAllPresets()
    XCTAssertTrue(inScratch.contains { $0.name == "Scratch only" })

    let real = try await PersistenceManager.shared.loadAllPresets()
    XCTAssertFalse(
      real.contains { $0.name == "Scratch only" },
      "a test wrote into the real Application Support folder"
    )
  }
}

/// Turning a preset off, which used to mean deleting it.
final class PresetEnablingTests: BaseTestCase {

  @MainActor
  func test_anOffPresetIsNotOffered() {
    let model = AppModel(persistence: store)
    model.presets = [
      RulePreset(name: "On", description: "", category: .image),
      RulePreset(name: "Off", description: "", category: .image, isEnabled: false),
    ]
    XCTAssertEqual(model.usablePresets.map(\.name), ["On"])
  }

  @MainActor
  func test_turningOneOffKeepsItInTheList() {
    let model = AppModel(persistence: store)
    model.presets = [RulePreset(name: "Kept", description: "", category: .image)]

    model.setPreset(model.presets[0], enabled: false)

    XCTAssertEqual(model.presets.count, 1, "it is off, not gone")
    XCTAssertFalse(model.presets[0].isEnabled)
    XCTAssertTrue(model.usablePresets.isEmpty)

    model.setPreset(model.presets[0], enabled: true)
    XCTAssertEqual(model.usablePresets.count, 1)
  }

  /// A preset written before the switch existed is on, not off.
  func test_aPresetWithoutTheFlagIsOn() throws {
    let json = """
    { "name": "Old", "category": "image", "actions": [] }
    """
    let preset = try JSONDecoder().decode(RulePreset.self, from: Data(json.utf8))
    XCTAssertTrue(preset.isEnabled)
  }

  func test_theFlagSurvivesASaveAndLoad() async throws {
    let preset = RulePreset(name: "Off", description: "", category: .image, isEnabled: false)
    try await store.savePreset(preset)

    let reopened = PersistenceManager(root: store.root)
    let loaded = try await reopened.loadAllPresets()
    XCTAssertEqual(loaded.first?.isEnabled, false)
  }
}

/// Which kind of work a dropped file is in for. This decides what the Convert
/// screen offers for it, so a wrong answer means being offered a conversion
/// that cannot happen.
final class FileCategoryTests: XCTestCase {

  func test_eachKindOfFileFindsItsCategory() {
    XCTAssertEqual(PresetCategory(fileType: .png), .image)
    XCTAssertEqual(PresetCategory(fileType: .jpeg), .image)
    XCTAssertEqual(PresetCategory(fileType: .mpeg4Movie), .video)
    XCTAssertEqual(PresetCategory(fileType: .quickTimeMovie), .video)
    XCTAssertEqual(PresetCategory(fileType: .mp3), .audio)
    XCTAssertEqual(PresetCategory(fileType: .wav), .audio)
    XCTAssertEqual(PresetCategory(fileType: .pdf), .document)
    XCTAssertEqual(PresetCategory(fileType: .plainText), .document)
  }

  /// Audio in an MPEG-4 container must not read as video: the check order is
  /// what keeps an M4A out of the video presets.
  func test_audioInAnMPEG4ContainerIsStillAudio() {
    XCTAssertEqual(PresetCategory(fileType: .mpeg4Audio), .audio)
  }

  /// No category is the signal to offer everything, so it has to stay nil
  /// rather than fall into one of the four by accident.
  func test_aTypeNoCategoryDescribesIsNil() {
    XCTAssertNil(PresetCategory(fileType: .zip))
  }
}

/// What a file is decides which controls the Convert sheet puts in front of
/// somebody. A wrong answer here offers a setting the processor will ignore.
final class ConvertKindTests: XCTestCase {

  func test_eachFileFindsTheProcessorThatWillTakeIt() {
    XCTAssertEqual(ConvertKind(fileType: .png), .image)
    XCTAssertEqual(ConvertKind(fileType: .jpeg), .image)
    XCTAssertEqual(ConvertKind(fileType: .mpeg4Movie), .video)
    XCTAssertEqual(ConvertKind(fileType: .quickTimeMovie), .video)
    XCTAssertEqual(ConvertKind(fileType: .mp3), .audio)
    XCTAssertEqual(ConvertKind(fileType: .wav), .audio)
    XCTAssertEqual(ConvertKind(fileType: .pdf), .document)
  }

  /// JSON and CSV are plain text to the system, and the document reader would
  /// happily take them. `DataProcessor` is asked first, so they must land on
  /// data — the only kind that offers nothing but a change of format.
  func test_structuredTextIsDataNotDocument() {
    XCTAssertEqual(ConvertKind(fileType: .json), .data)
    if let csv = DataProcessor.csv {
      XCTAssertEqual(ConvertKind(fileType: csv), .data)
    }
  }

  func test_aTypeNothingReadsIsNil() {
    XCTAssertNil(ConvertKind(fileType: .zip))
  }

  /// The controls each kind admits to, taken from what the processors read.
  func test_onlyTheControlsTheProcessorHonoursAreOffered() {
    XCTAssertTrue(ConvertKind.image.supportsFilter)
    XCTAssertFalse(ConvertKind.image.supportsCodec)

    XCTAssertTrue(ConvertKind.video.supportsCodec)
    XCTAssertTrue(ConvertKind.video.supportsResize)
    XCTAssertFalse(ConvertKind.video.supportsFilter)

    XCTAssertTrue(ConvertKind.audio.supportsCodec)
    XCTAssertFalse(ConvertKind.audio.supportsResize)
    XCTAssertFalse(ConvertKind.audio.supportsQuality)

    // A data file can only change format: everything else is refused outright.
    for kind in [ConvertKind.data] {
      XCTAssertFalse(kind.supportsResize)
      XCTAssertFalse(kind.supportsQuality)
      XCTAssertFalse(kind.supportsFilter)
      XCTAssertFalse(kind.supportsCodec)
      XCTAssertFalse(kind.supportsTextExtraction)
    }
  }

  /// A PDF and a video are asked different questions. That difference is the
  /// whole point of the sheet.
  func test_aDocumentAndAVideoAreOfferedDifferentOutputs() {
    let documentGroups = Set(ConvertKind.document.outputGroups.map(\.title))
    let videoGroups = Set(ConvertKind.video.outputGroups.map(\.title))
    XCTAssertTrue(documentGroups.contains("Read aloud"))
    XCTAssertFalse(videoGroups.contains("Read aloud"))
    XCTAssertTrue(videoGroups.contains("Video"))
    XCTAssertFalse(documentGroups.contains("Video"))
  }
}

/// What the sheet hands the coordinator.
final class ConvertChoiceTests: XCTestCase {

  /// Nothing chosen is nothing to run: Convert stays off rather than writing a
  /// copy of the file under a new name.
  func test_anEmptyChoiceResolvesToNothing() {
    XCTAssertNil(ConvertChoice().resolved(against: []))
  }

  func test_theFieldsBecomeAChainInTheOrderTheyRun() throws {
    var choice = ConvertChoice()
    choice.format = OutputFormat(type: .jpeg)
    choice.width = 1280
    choice.quality = 80

    let preset = try XCTUnwrap(choice.resolved(against: []))
    let actions = preset.actions
    XCTAssertEqual(actions.count, 3)
    if case .convertFormat(let to) = actions[0] { XCTAssertEqual(to, UTType.jpeg) } else { XCTFail("format first") }
    if case .resize(let width, _, _) = actions[1] { XCTAssertEqual(width, 1280) } else { XCTFail("resize second") }
    if case .quality(let level) = actions[2] { XCTAssertEqual(level, 80) } else { XCTFail("quality third") }
  }

  /// A chosen preset is run as it stands, because it can hold things the sheet
  /// has no control for.
  func test_aChosenPresetIsRunWhole() {
    let preset = RulePreset(
      name: "Two filters",
      description: "",
      category: .image,
      actions: [.filter(type: .grayscale), .filter(type: .sepia)]
    )
    var choice = ConvertChoice()
    choice.presetID = preset.id

    XCTAssertEqual(choice.resolved(against: [preset])?.actions.count, 2)
  }

  /// Asking for text asks for the language too, even when it is left open.
  func test_askingForTextAddsRecognition() {
    var choice = ConvertChoice()
    choice.format = OutputFormat(type: .plainText)
    XCTAssertTrue(choice.wantsText)
    XCTAssertTrue(choice.customActions.contains { if case .recognizeText = $0 { return true } else { return false } })
  }
}

/// Somewhere for a batch's callback to leave what it saw, since it is called
/// from whatever thread the conversion finished on.
private final class OutputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [URL] = []

  func add(_ urls: [URL]) {
    lock.lock(); defer { lock.unlock() }
    seen.append(contentsOf: urls)
  }

  var written: [URL] {
    lock.lock(); defer { lock.unlock() }
    return seen
  }
}

/// The app's own bookkeeping: what it remembers writing, and what it does
/// when the thing a watched folder depends on is taken away.
@MainActor
final class AppModelTests: BaseTestCase {

  /// The set of files Forge wrote used to be emptied wholesale when it filled
  /// up, so a file written a moment earlier stopped being recognised as its
  /// own - and a watched folder would convert it again, and again.
  func test_theOldestFileIsForgottenRatherThanAllOfThem() {
    let model = AppModel(persistence: store)
    let recent = URL(fileURLWithPath: "/tmp/scritto-recente.png")

    for index in 0..<600 {
      model.remember(URL(fileURLWithPath: "/tmp/scritto-\(index).png"))
    }
    model.remember(recent)

    XCTAssertTrue(model.wroteThis(recent), "the file just written was already forgotten")
    XCTAssertTrue(
      model.wroteThis(URL(fileURLWithPath: "/tmp/scritto-599.png")),
      "the most recent of the batch was forgotten"
    )
    XCTAssertFalse(
      model.wroteThis(URL(fileURLWithPath: "/tmp/scritto-0.png")),
      "the oldest should have been dropped to make room"
    )
  }

  /// Files Forge cannot open were dropped on the floor: drop ten, see seven,
  /// with nothing to say which three were missing or what was wrong with them.
  func test_theFilesThatWereTurnedAwayAreNamed() {
    let refused = [
      URL(fileURLWithPath: "/tmp/archivio.zzz"),
      URL(fileURLWithPath: "/tmp/altro.qqq"),
    ]
    let said = BatchViewModel.describe(refused) ?? ""
    XCTAssertTrue(said.contains("2 files"), said)
    XCTAssertTrue(said.contains(".zzz"), said)
    XCTAssertTrue(said.contains(".qqq"), said)

    let one = BatchViewModel.describe([URL(fileURLWithPath: "/tmp/solo.zzz")])
    XCTAssertEqual(one?.contains("solo.zzz"), true, one ?? "")
    XCTAssertNil(BatchViewModel.describe([]), "nothing turned away, nothing to say")
  }

  /// The menu bar said nothing when it took some of what it was given.
  func test_theMenuBarSaysWhenItTookOnlySome() async throws {
    let model = AppModel(persistence: store)
    let preset = RulePreset.make(format: .jpeg, category: .image)
    model.savePreset(preset)

    let good = try Fixture.image(at: path("buona.png"), width: 60, height: 60)
    let bad = path("rifiutata.zzz")
    try Data("not a picture".utf8).write(to: bad)

    model.convertFromMenuBar([good, bad], with: preset, into: try folder("out"))

    let said = try XCTUnwrap(model.lastError, "nothing was said about the file it could not open")
    XCTAssertTrue(said.contains(".zzz"), said)
  }

  /// The same folder could be added twice, which put two watchers on it and
  /// converted everything twice - the second copy arriving as "photo 2.jpeg"
  /// with nothing to say where it came from.
  func test_aFolderIsNotWatchedTwice() async throws {
    let model = AppModel(persistence: store)
    let preset = RulePreset.make(format: .jpeg, category: .image)
    model.savePreset(preset)
    let watched = try folder("watched")
    let out = try folder("out")

    model.addFolder(url: watched, presetID: preset.id, mode: .copyTo, destination: out, includeSubfolders: false)
    model.addFolder(url: watched, presetID: preset.id, mode: .copyTo, destination: out, includeSubfolders: false)

    XCTAssertEqual(model.folders.count, 1, "the same folder is being watched twice")
    XCTAssertEqual(model.lastError?.contains("already being watched"), true, model.lastError ?? "")
  }

  /// A folder inside one that already watches its subfolders is the same
  /// double conversion wearing a different hat.
  func test_aFolderInsideAWatchedTreeIsRefused() async throws {
    let model = AppModel(persistence: store)
    let preset = RulePreset.make(format: .jpeg, category: .image)
    model.savePreset(preset)
    let parent = try folder("parent")
    let child = parent.appendingPathComponent("inside")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let out = try folder("out")

    model.addFolder(url: parent, presetID: preset.id, mode: .copyTo, destination: out, includeSubfolders: true)
    model.addFolder(url: child, presetID: preset.id, mode: .copyTo, destination: out, includeSubfolders: false)

    XCTAssertEqual(model.folders.count, 1)
    XCTAssertEqual(model.lastError?.contains("twice"), true, model.lastError ?? "")
  }

  /// Deleting a preset left every folder watching with it looking active and
  /// doing nothing whatsoever with what landed in them.
  func test_deletingAPresetSwitchesOffTheFoldersUsingIt() async throws {
    let model = AppModel(persistence: store)
    let preset = RulePreset.make(format: .jpeg, category: .image)
    model.savePreset(preset)

    let watched = try folder("watched")
    model.addFolder(
      url: watched, presetID: preset.id, mode: .copyTo,
      destination: try folder("out"), includeSubfolders: false
    )
    XCTAssertEqual(model.folders.first?.isActive, true)

    model.deletePreset(preset)

    XCTAssertEqual(model.folders.first?.isActive, false, "the folder is still claiming to watch")
    let said = try XCTUnwrap(model.lastError)
    XCTAssertTrue(said.contains(preset.name), said)
  }
}

/// What history records, and whether a row leads anywhere.
final class HistoryTests: BaseTestCase {

  /// A batch reported one output per file, so a watched folder heard about
  /// the first file of a two-format conversion and converted the second.
  func test_aBatchReportsEveryFileItWrote() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 100, height: 100)
    var preset = RulePreset.make(format: .jpeg, category: .image)
    preset.actions.append(.convertFormat(to: .tiff))

    let box = OutputBox()
    _ = await Batch.run(
      [try ProcessableFile(url: source)],
      preset: preset,
      mode: .copyTo,
      destination: try folder("out"),
      limit: 1,
      coordinator: coordinator()
    ) { event in
      if case .finished(_, _, _, let written, _) = event { box.add(written) }
    }

    XCTAssertEqual(box.written.count, 2, "the batch reported \(box.written.count) of the files it wrote")
  }

  /// A preset asking for two formats writes two files. History kept the first
  /// and forgot the second: both were on disk, and only one was accounted for.
  func test_everyOutputIsRecorded() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 120, height: 120)
    var preset = RulePreset.make(format: .jpeg, quality: 80, category: .image)
    preset.actions.append(.convertFormat(to: .tiff))

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: try folder("out")
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    XCTAssertEqual(entry.outputs.count, 2, "history kept \(entry.outputs.count) of the files written")
    for output in entry.outputs {
      XCTAssertTrue(exists(output), "\(output.lastPathComponent) is recorded and not on disk")
    }
  }

  /// A failure recorded a duration of zero, so a conversion that gave up after
  /// two minutes and one that failed at once read the same.
  func test_aFailureRecordsHowLongItTookAndWhy() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 100, height: 100)
    let icns = try XCTUnwrap(UTType("com.apple.icns"))

    _ = try? await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: icns, category: .image),
      destinationMode: .copyTo,
      destinationURL: try folder("out")
    ) { _ in }

    let written = try await store.loadHistory()
    let entry = try XCTUnwrap(written.first { $0.status == .failed })
    XCTAssertGreaterThan(entry.duration, 0, "the failure was recorded as taking no time")
    XCTAssertNotNil(entry.errorMessage, "the reason was not recorded")
    XCTAssertNotNil(entry.destinationFolder, "nothing says where it was meant to go, so it cannot be retried")
  }

  /// "0.0s" reads like nothing happened.
  func test_aShortConversionIsNotShownAsZero() {
    func entry(_ seconds: TimeInterval) -> ProcessingHistory {
      ProcessingHistory(fileURL: URL(fileURLWithPath: "/tmp/a.png"), status: .completed, duration: seconds)
    }
    XCTAssertEqual(entry(0.04).durationText, "40 ms")
    XCTAssertEqual(entry(0.996).durationText, "996 ms")
    XCTAssertEqual(entry(1.42).durationText, "1.4 s")
    XCTAssertNil(entry(0).durationText, "a conversion with no measured time says nothing rather than zero")
  }

  /// History written before these fields existed still has to load: it is the
  /// user's own record, and dropping it to add a column would be a poor trade.
  func test_anOlderHistoryStillDecodes() throws {
    let json = """
      [{"id":"6E2E1F1A-0000-4000-8000-00000000ABCD",
        "fileURL":"file:///tmp/old.png",
        "timestamp":749000000,
        "status":"completed",
        "duration":1.5,
        "outputURL":"file:///tmp/old.jpeg"}]
      """
    let decoded = try JSONDecoder().decode([ProcessingHistory].self, from: Data(json.utf8))
    XCTAssertEqual(decoded.count, 1)
    XCTAssertEqual(decoded.first?.outputs.count, 1)
    XCTAssertNil(decoded.first?.destinationFolder)
  }
}

/// What the window offers for a file, which is a different question from what
/// the engine can do with it - and was a different answer, for a while.
final class ConvertKindOfferingTests: XCTestCase {

  private func kind(of ext: String) throws -> ConvertKind {
    let plain = try XCTUnwrap(UTType(filenameExtension: ext))
    let type = plain.isDynamic
      ? try XCTUnwrap(UTType(filenameExtension: ext, conformingTo: .plainText))
      : plain
    return try XCTUnwrap(ConvertKind(fileType: type), "\(ext) is filed under nothing")
  }

  private func offered(_ kind: ConvertKind) -> [String] {
    kind.outputGroups.flatMap { group in
      group.formats.compactMap { $0.type.flatMap(FormatCatalog.fileExtension(for:)) }
    }
  }

  /// A subtitle is its own kind. It used to be filed as a document, which
  /// offered PDF and DOCX and no way at all to write another subtitle - the
  /// conversion existed and the window did not know about it.
  func test_aSubtitleIsOfferedSubtitles() throws {
    for ext in ["srt", "sbv"] {
      let kind = try kind(of: ext)
      XCTAssertEqual(kind, .subtitle, ext)
      let formats = offered(kind)
      XCTAssertTrue(formats.contains("srt"), "\(ext): \(formats)")
      XCTAssertTrue(formats.contains("vtt"), "\(ext): \(formats)")
      XCTAssertTrue(formats.contains("txt"), "\(ext): \(formats)")
    }
  }

  /// WebVTT is the one macOS has a type for, and AVFoundation lists it among
  /// the types it opens - so the window called a subtitle a video, showed it
  /// video controls, and failed with "contains no audio or video tracks".
  func test_webVTTIsASubtitleRatherThanAVideo() throws {
    XCTAssertEqual(try kind(of: "vtt"), .subtitle)
  }

  /// A font used to be filed as a document, which offered to turn it into a
  /// PDF and could not.
  func test_aFontIsOfferedFonts() throws {
    let kind = try kind(of: "ttf")
    XCTAssertEqual(kind, .font)
    // The formats themselves depend on fonttools being installed, which is
    // the honest answer: nothing writes a font without it.
    if ExternalTools.locate("fonttools") != nil {
      XCTAssertTrue(offered(kind).contains("woff2"), "\(offered(kind))")
    } else {
      XCTAssertTrue(offered(kind).isEmpty)
    }
  }

  /// The track inside a film is reachable from the window, not only from the
  /// command line - where there is an ffmpeg to pull it out with.
  func test_aFilmOffersItsSubtitlesWhenTheToolIsHere() throws {
    let kind = try kind(of: "mp4")
    XCTAssertEqual(kind, .video)
    XCTAssertEqual(
      offered(kind).contains("srt"),
      ExternalTools.locate("ffmpeg") != nil,
      "\(offered(kind))"
    )
  }

  /// The formats that were already right, kept that way.
  func test_theOtherKindsAreUnchanged() throws {
    XCTAssertEqual(try kind(of: "png"), .image)
    XCTAssertEqual(try kind(of: "mp4"), .video)
    XCTAssertEqual(try kind(of: "json"), .data)
    if FormatCatalog.isRasterizableVector(.svg) {
      XCTAssertEqual(try kind(of: "svg"), .image)
    }
  }

  /// A preset was offered by the shelf it was filed on rather than by what it
  /// writes, so one that makes JPEGs and happens to be filed under Video was
  /// not offered for a picture - and nothing anywhere said why. The roadmap
  /// had this as a known trap; it is a trap no longer.
  func test_aPresetIsOfferedForWhatItWritesNotForItsLabel() {
    let mislabelled = RulePreset.make(format: .jpeg, category: .video)
    XCTAssertTrue(mislabelled.suits([.image]), "a JPEG preset was withheld from pictures")

    let film = RulePreset.make(format: .quickTimeMovie, category: .image)
    XCTAssertTrue(film.suits([.video]), "a movie preset was withheld from films")
    XCTAssertFalse(film.suits([.data]), "a movie preset has no business with a JSON file")
  }

  /// A preset with no format of its own resizes, filters or reads text out,
  /// which suits anything that honours those.
  func test_aPresetWithNoFormatSuitsAnything() {
    let resizeOnly = RulePreset.make(
      resize: ResizeSpec(width: 800, height: nil, fitMode: .proportional), category: .custom
    )
    XCTAssertNil(resizeOnly.targetFormat)
    XCTAssertTrue(resizeOnly.suits([.image]))
    XCTAssertTrue(resizeOnly.suits([.video]))
  }

  /// The kinds answer for themselves what they can be asked for, out of the
  /// same list the sheet offers rather than a second one kept beside it.
  func test_aKindKnowsWhatItCanBeAskedFor() {
    XCTAssertTrue(ConvertKind.image.offers(.jpeg))
    XCTAssertFalse(ConvertKind.image.offers(.quickTimeMovie))
    XCTAssertTrue(ConvertKind.video.offers(.jpeg), "a film can give up a frame")
    XCTAssertTrue(ConvertKind.data.offers(.json))
    XCTAssertFalse(ConvertKind.data.offers(.jpeg), "a JSON file is not a picture")
  }

  /// `public.toml` prefers the extension `cfg`, so the menu used to list TOML
  /// as CFG - a format nobody would look for.
  func test_theMenuNamesAFormatWhatPeopleCallIt() throws {
    guard let toml = UTType("public.toml") else { throw XCTSkip("no TOML type on this macOS") }
    XCTAssertEqual(OutputFormat(type: toml).label, "TOML")
    XCTAssertEqual(OutputFormat(type: .jpeg).label, "JPEG")
  }
}
