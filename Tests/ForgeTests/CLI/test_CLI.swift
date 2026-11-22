import XCTest
import ArgumentParser
import UniformTypeIdentifiers
@testable import Forge

/// Which front end a launch is asking for.
///
/// Getting this wrong is not a small bug: mistake an app launch for a command
/// and the window never opens.
final class LaunchModeTests: BaseTestCase {

  func test_theSymlinkAlwaysMeansTheTool() {
    XCTAssertTrue(LaunchMode.isCommandLine(arguments: ["/usr/local/bin/forge"]))
    XCTAssertTrue(LaunchMode.isCommandLine(arguments: ["/Applications/Forge.app/Contents/MacOS/forge"]))
  }

  func test_aBareAppLaunchMeansTheWindow() {
    XCTAssertFalse(LaunchMode.isCommandLine(arguments: ["/Applications/Forge.app/Contents/MacOS/Forge"]))
  }

  /// macOS adds arguments of its own when launching a bundled app; they must
  /// never be mistaken for a command.
  func test_theSystemsOwnArgumentsAreNotCommands() {
    let launched = [
      "/Applications/Forge.app/Contents/MacOS/Forge",
      "-psn_0_123456",
      "-NSDocumentRevisionsDebugMode",
    ]
    XCTAssertFalse(LaunchMode.isCommandLine(arguments: launched))
    XCTAssertTrue(LaunchMode.userArguments(from: launched).isEmpty)
  }

  func test_argumentsMeanTheTool() {
    let invocation = ["/Applications/Forge.app/Contents/MacOS/Forge", "convert", "a.png"]
    XCTAssertTrue(LaunchMode.isCommandLine(arguments: invocation))
    XCTAssertEqual(LaunchMode.userArguments(from: invocation), ["convert", "a.png"])
  }
}

/// The options that decide what a command-line run actually does.
final class CommandParsingTests: BaseTestCase {

  private func convert(_ arguments: [String]) throws -> ForgeCommand.Convert {
    try ForgeCommand.Convert.parse(arguments)
  }

  func test_destinationRequiresSomewhereToPutTheOutput() throws {
    let command = try convert(["a.png", "--to", "jpeg"])
    XCTAssertThrowsError(try command.destination.resolve()) { error in
      XCTAssertTrue("\(error)".contains("--out"), "\(error)")
    }
  }

  func test_destinationModes() throws {
    let copy = try convert(["a.png", "--to", "jpeg", "--out", "/tmp/x"]).destination
    XCTAssertEqual(try copy.resolve().mode, .copyTo)

    let move = try convert(["a.png", "--to", "jpeg", "--out", "/tmp/x", "--move"]).destination
    XCTAssertEqual(try move.resolve().mode, .moveTo)

    let overwrite = try convert(["a.png", "--to", "jpeg", "--overwrite"]).destination
    XCTAssertEqual(try overwrite.resolve().mode, .overwrite)
    XCTAssertNil(try overwrite.resolve().url)
  }

  /// `--overwrite` keeps a backup unless told otherwise, matching the app.
  func test_backupIsKeptUnlessRefused() throws {
    let keeping = try convert(["a.png", "--to", "jpeg", "--overwrite"]).destination
    XCTAssertTrue(keeping.settings.createBackupBeforeOverwrite)

    let refusing = try convert(["a.png", "--to", "jpeg", "--overwrite", "--no-backup"]).destination
    XCTAssertFalse(refusing.settings.createBackupBeforeOverwrite)
  }

  func test_recipeFromFlags() throws {
    let recipe = try convert([
      "a.png", "--to", "jpeg", "--resize", "1280x720", "--quality", "70", "--filter", "sepia",
    ]).recipe
    let preset = try recipe.resolve(saved: [])

    XCTAssertEqual(preset.targetFormat, .jpeg)
    XCTAssertEqual(preset.resize?.width, 1280)
    XCTAssertEqual(preset.resize?.height, 720)
    XCTAssertEqual(preset.quality, 70)
    XCTAssertEqual(preset.filters, [.sepia])
  }

  func test_recipeAcceptsASingleSide() throws {
    let preset = try convert(["a.png", "--resize", "1280x"]).recipe.resolve(saved: [])
    XCTAssertEqual(preset.resize?.width, 1280)
    XCTAssertNil(preset.resize?.height)
  }

  func test_recipeRejectsNonsense() throws {
    XCTAssertThrowsError(try convert(["a.png", "--resize", "big"]).recipe.resolve(saved: []))
    XCTAssertThrowsError(try convert(["a.png", "--quality", "500"]).recipe.resolve(saved: []))
    XCTAssertThrowsError(try convert(["a.png", "--to", "zzzz"]).recipe.resolve(saved: []))
  }

  func test_recipeNeedsSomethingToDo() throws {
    XCTAssertThrowsError(try convert(["a.png"]).recipe.resolve(saved: [])) { error in
      XCTAssertTrue("\(error)".contains("--preset"), "\(error)")
    }
  }

  /// A preset is found by name, case-insensitively, from the same store the
  /// app writes to.
  func test_recipeFindsASavedPreset() throws {
    let other = RulePreset.make(format: .png, quality: 50, category: .image)
    let named = RulePreset(
      name: "Web JPEG",
      description: "",
      targetFormat: .jpeg,
      quality: 80,
      category: .image
    )
    let resolved = try convert(["a.png", "--preset", "web jpeg"]).recipe.resolve(saved: [other, named])
    XCTAssertEqual(resolved.id, named.id)
  }

  func test_unknownPresetNamesTheOnesThatExist() throws {
    let saved = [RulePreset(name: "Web JPEG", description: "", category: .image)]
    XCTAssertThrowsError(try convert(["a.png", "--preset", "nope"]).recipe.resolve(saved: saved)) { error in
      XCTAssertTrue("\(error)".contains("Web JPEG"), "\(error)")
    }
  }

  // MARK: - What the options used to let through

  private func resolving(_ arguments: [String], saved: [RulePreset] = []) throws -> RulePreset {
    try convert(arguments).recipe.resolve(saved: saved)
  }

  /// `--overwrite --out folder` replaced the original and ignored the folder;
  /// `--move --overwrite` and `--no-backup` on its own were taken in silence.
  func test_destinationsThatContradictEachOtherAreRefused() throws {
    for arguments in [
      ["a.png", "--to", "jpeg", "--overwrite", "--out", "x"],
      ["a.png", "--to", "jpeg", "--move", "--overwrite"],
      ["a.png", "--to", "jpeg", "--out", "x", "--no-backup"],
    ] {
      XCTAssertThrowsError(try convert(arguments).destination.resolve(), "\(arguments)")
    }
  }

  /// `1.5x2` was read as `x2`, `0x0` did nothing and named the file `-0`, and
  /// 999999x999999 ran until it was stopped.
  func test_aSizeIsWholeNumbersWithinReason() throws {
    for size in ["1.5x2", "0x0", "0x100", "-5x10", "999999x999999", "x", "12", "axb"] {
      XCTAssertThrowsError(try resolving(["a.png", "--resize", size]), size)
    }
    XCTAssertNoThrow(try resolving(["a.png", "--resize", "1280x"]))
    XCTAssertNoThrow(try resolving(["a.png", "--resize", "x720"]))
  }

  func test_aFitWithNoSizeToFitIsRefused() throws {
    XCTAssertThrowsError(try resolving(["a.png", "--to", "jpeg", "--fit", "pad"])) { error in
      XCTAssertTrue("\(error)".contains("--resize"), "\(error)")
    }
  }

  /// The second `--filter` replaced the first.
  func test_everyFilterAskedForIsApplied() throws {
    let preset = try resolving(["a.png", "--filter", "grayscale", "--filter", "blur"])
    XCTAssertEqual(preset.filters, [.grayscale, .blur])
  }

  /// `--ocr-language it-IT scan.png` took the file for a second language.
  func test_aLanguageDoesNotSwallowTheFileAfterIt() throws {
    let command = try convert(["--to", "txt", "--ocr-language", "it-IT", "scan.png", "--out", "x"])
    XCTAssertEqual(command.files, ["scan.png"])
    XCTAssertEqual(command.recipe.languages, ["it-IT"])

    let two = try convert(["scan.png", "--to", "txt", "--ocr-language", "it-IT,en-US", "--out", "x"])
    XCTAssertEqual(two.recipe.languages, ["it-IT", "en-US"])
  }

  /// Options given beside `--preset` were dropped without a word.
  func test_aPresetIsNotMixedWithOptionsItWouldIgnore() throws {
    let saved = [RulePreset(name: "Web JPEG", description: "", targetFormat: .jpeg, category: .image)]
    XCTAssertThrowsError(try resolving(["a.png", "--preset", "Web JPEG", "--quality", "20"], saved: saved)) { error in
      XCTAssertTrue("\(error)".contains("--quality"), "\(error)")
    }
  }

  /// With two presets of one name, one was picked and nobody was told which.
  func test_twoPresetsOfOneNameAreNotChosenBetween() throws {
    let saved = [
      RulePreset(name: "Web", description: "", targetFormat: .jpeg, category: .image),
      RulePreset(name: "web", description: "", targetFormat: .png, category: .image),
    ]
    XCTAssertThrowsError(try resolving(["a.png", "--preset", "Web"], saved: saved)) { error in
      XCTAssertTrue("\(error)".contains("2"), "\(error)")
    }
  }

  /// A preset that asks a question was run as if it asked nothing, while the
  /// file name said the answer had been applied: `photo_320px.jpeg`, 1600 wide.
  func test_aPresetThatAsksIsAnsweredWithItsDefaultOrWithAnAnswer() throws {
    var asks = RulePreset(name: "Ask", description: "", targetFormat: .jpeg, category: .image)
    asks.parameters = [PresetParameter(key: "width", label: "Width", kind: .width, defaultValue: 320)]

    let byDefault = try resolving(["a.png", "--preset", "Ask"], saved: [asks])
    XCTAssertEqual(byDefault.resize?.width, 320)

    let answered = try resolving(["a.png", "--preset", "Ask", "--answer", "width=640"], saved: [asks])
    XCTAssertEqual(answered.resize?.width, 640)
    XCTAssertEqual(answered.parameterValues["width"], 640)

    XCTAssertThrowsError(try resolving(["a.png", "--preset", "Ask", "--answer", "height=640"], saved: [asks]))
  }

  /// A preset that does nothing copied the file and called it converted.
  func test_aPresetThatDoesNothingIsRefused() throws {
    let empty = RulePreset(name: "Empty", description: "", category: .custom)
    XCTAssertThrowsError(try resolving(["a.png", "--preset", "Empty"], saved: [empty]))
  }

  /// A file converted into its own format changed its extension: `keep.jpg`
  /// replaced in place came back as `keep.jpeg`.
  func test_aFileThatKeepsItsFormatKeepsItsExtension() async throws {
    let source = try Fixture.image(at: path("keep.jpg"), width: 40, height: 30)
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 60, category: .image),
      destinationMode: .copyTo, destinationURL: try folder("out")
    ) { _ in }
    XCTAssertEqual(entry.outputURL?.lastPathComponent, "keep.jpg")

    let other = try Fixture.image(at: path("photo.png"), width: 40, height: 30)
    let changed = try await coordinator().processFile(
      try ProcessableFile(url: other),
      with: .make(format: .jpeg, category: .image),
      destinationMode: .copyTo, destinationURL: try folder("out2")
    ) { _ in }
    XCTAssertEqual(changed.outputURL?.lastPathComponent, "photo.jpeg", "a new format takes the format's own name")
  }

  /// `--to jpg` wrote `.jpeg`, and `--to tif` `.tiff`.
  func test_theExtensionTypedIsTheExtensionWritten() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 40, height: 30)
    for (typed, expected) in [("jpg", "photo.jpg"), ("jpeg", "photo.jpeg"), ("tif", "photo.tif")] {
      let preset = try resolving(["photo.png", "--to", typed])
      let entry = try await coordinator().processFile(
        try ProcessableFile(url: source), with: preset,
        destinationMode: .copyTo, destinationURL: try folder("out-\(typed)")
      ) { _ in }
      XCTAssertEqual(entry.outputURL?.lastPathComponent, expected)
    }
  }

  /// Markdown was written as `.markdown`, which nothing else calls it.
  func test_markdownIsCalledMd() throws {
    let markdown = try XCTUnwrap(UTType(filenameExtension: "md"))
    XCTAssertEqual(FormatCatalog.fileExtension(for: markdown), "md")
    XCTAssertEqual(FormatCatalog.fileExtension(for: .jpeg), "jpeg")
    if let toml = UTType("public.toml") { XCTAssertEqual(FormatCatalog.fileExtension(for: toml), "toml") }
  }

  /// "Keep all metadata" was listed as "no metadata".
  func test_thePresetListSaysWhatEachLevelKeeps() {
    XCTAssertEqual(ForgeCommand.Presets.describe(.stripMetadata(policy: .keepAll)), "keeps all metadata")
    XCTAssertEqual(ForgeCommand.Presets.describe(.stripMetadata(policy: .stripLocation)), "no location")
    XCTAssertEqual(ForgeCommand.Presets.describe(.stripMetadata(policy: .stripAll)), "no identifying metadata")
  }
}

/// The tool and the window share one engine, so a batch behaves the same on
/// both sides.
final class BatchTests: BaseTestCase {

  func test_convertsEveryFileAndReportsEachOne() async throws {
    let files = try (1...5).map { index in
      try ProcessableFile(url: Fixture.image(at: path("photo\(index).png"), width: 64, height: 64))
    }
    let destination = try folder("out")

    let events = EventLog()
    let report = await Batch.run(
      files,
      preset: .make(format: .jpeg, quality: 70, category: .image),
      mode: .copyTo,
      destination: destination,
      limit: 2,
      coordinator: coordinator()
    ) { events.append($0) }

    XCTAssertEqual(report.converted, 5)
    XCTAssertEqual(report.failed, 0)
    XCTAssertEqual(contents(of: destination).count, 5)
    XCTAssertEqual(events.startedCount, 5)
    XCTAssertEqual(events.finishedCount, 5)
  }

  /// Refusing to continue stops the queue, not just the files already running.
  func test_stopsStartingNewFilesWhenAsked() async throws {
    let files = try (1...6).map { index in
      try ProcessableFile(url: Fixture.image(at: path("photo\(index).png"), width: 64, height: 64))
    }
    let destination = try folder("out")

    let report = await Batch.run(
      files,
      preset: .make(format: .jpeg, quality: 70, category: .image),
      mode: .copyTo,
      destination: destination,
      limit: 1,
      coordinator: coordinator(),
      shouldContinue: { false }
    ) { _ in }

    XCTAssertEqual(report.converted, 0)
    XCTAssertEqual(contents(of: destination).count, 0)
  }

  func test_countsFailuresSeparately() async throws {
    let good = try ProcessableFile(url: Fixture.image(at: path("photo.png"), width: 32, height: 32))
    let bad = try ProcessableFile(url: Fixture.audio(at: path("tone.wav"), seconds: 1))
    let destination = try folder("out")

    let report = await Batch.run(
      [good, bad],
      preset: .make(format: .jpeg, category: .image),
      mode: .copyTo,
      destination: destination,
      limit: 2,
      coordinator: coordinator()
    ) { _ in }

    XCTAssertEqual(report.converted, 1)
    XCTAssertEqual(report.failed, 1)
  }
}

/// Collects batch events from whichever thread reports them.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [Batch.Event] = []

  func append(_ event: Batch.Event) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  var startedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return events.filter { if case .started = $0 { return true } else { return false } }.count
  }

  var finishedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return events.filter { if case .finished = $0 { return true } else { return false } }.count
  }
}
