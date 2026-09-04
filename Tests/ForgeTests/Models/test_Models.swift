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
    let model = AppModel()
    model.presets = presets(["One", "Two", "Three"])

    model.movePreset(model.presets[2], by: -1)

    XCTAssertEqual(model.presets.map(\.name), ["One", "Three", "Two"])
    XCTAssertEqual(model.presets.map(\.position), [0, 1, 2], "positions must stay dense")
  }

  @MainActor
  func test_movingPastTheEndDoesNothing() {
    let model = AppModel()
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
