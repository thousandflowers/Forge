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
