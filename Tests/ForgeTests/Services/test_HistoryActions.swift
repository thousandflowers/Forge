import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// A past run, made into something that can be run again.
///
/// A history entry and a preset are the same thing said twice - a name and a
/// list of actions - so most of this is about that mapping being a rename
/// rather than a translation, and about what happens when the file a row
/// describes is no longer there.
@MainActor
final class HistoryActionTests: BaseTestCase {

  // MARK: - The mapping

  func test_savedPreset_carriesTheWholeChain() throws {
    let entry = Self.entry(actions: [
      .convertFormat(to: .jpeg),
      .resize(width: 1080, height: 1080, fitMode: .cropCenter),
      .quality(level: 82),
      .filter(type: .sepia),
      .limitSize(bytes: 2_000_000),
    ])

    let preset = try XCTUnwrap(entry.savedPreset)

    XCTAssertEqual(preset.actions, entry.actions, "the chain is what happened; it goes across unchanged")
    XCTAssertEqual(preset.category, .image, "filed by what was converted, so it is offered for that again")
    XCTAssertTrue(preset.name.contains("Web JPEG"), "named after the run it came from")
    XCTAssertTrue(preset.doesSomething)
  }

  /// The whole point of saving one: it has to be a preset like any other.
  func test_savedPreset_isSavedThroughTheOrdinaryPath() async throws {
    let model = AppModel(persistence: store)
    let entry = Self.entry(actions: [.convertFormat(to: .png), .quality(level: 70)])

    model.savePreset(from: entry)

    let saved = try XCTUnwrap(model.presets.first)
    XCTAssertEqual(saved.actions, entry.actions)

    // Give the write a turn to land, then read it back off disk.
    try await Task.sleep(nanoseconds: 300_000_000)
    let onDisk = try await store.loadAllPresets()
    XCTAssertEqual(onDisk.map(\.name), [saved.name])
  }

  /// History written before the chain was recorded describes a conversion it
  /// cannot reproduce, and says so rather than offering a preset that does
  /// nothing.
  func test_anOldEntry_cannotBeSavedOrRepeated() {
    let model = AppModel(persistence: store)
    let entry = Self.entry(actions: nil)

    XCTAssertFalse(entry.isRepeatable)
    XCTAssertNil(entry.savedPreset)
    XCTAssertNil(entry.rerunPreset)

    model.savePreset(from: entry)
    XCTAssertTrue(model.presets.isEmpty)
    XCTAssertNotNil(model.lastError, "and it says why, rather than doing nothing in silence")
  }

  // MARK: - Running it again

  func test_rerun_putsTheSameChainOnTheConvertScreen() throws {
    let source = try Fixture.image(at: path("holiday.png"))
    let destination = try folder("out")
    let model = AppModel(persistence: store)
    let entry = Self.entry(
      file: source,
      actions: [.convertFormat(to: .jpeg), .quality(level: 70)],
      destination: destination
    )

    model.rerun(entry)

    let pending = try XCTUnwrap(model.pending)
    XCTAssertEqual(pending.files, [source])
    XCTAssertEqual(pending.preset.actions, entry.actions)
    XCTAssertEqual(pending.destination, destination)
    XCTAssertEqual(pending.mode, .copyTo, "a copy is repeated as a copy, never as a move")
    XCTAssertNil(model.lastError)
  }

  /// The delicate one. A file that has been renamed, moved, or replaced in
  /// place by this very conversion is named out loud, and whatever is still
  /// there goes ahead.
  func test_rerun_saysWhichFilesAreGoneAndCarriesOn() throws {
    let here = try Fixture.image(at: path("still-here.png"))
    let gone = path("moved-away.png")

    let split = AppModel.split([here, gone])
    XCTAssertEqual(split.here, [here])
    XCTAssertEqual(split.missing, [gone])

    let said = try XCTUnwrap(AppModel.describeMissing(split.missing))
    XCTAssertTrue(said.contains("moved-away.png"), "named, not counted: “1 file was skipped” is not actionable")

    let model = AppModel(persistence: store)
    model.rerun(Self.entry(file: gone, actions: [.convertFormat(to: .jpeg)]))

    XCTAssertNil(model.pending, "nothing left to run")
    XCTAssertNotNil(model.lastError)
    XCTAssertTrue(try XCTUnwrap(model.lastError).contains("moved-away.png"))
  }

  /// A run recorded with no destination folder replaced its original, so doing
  /// it again replaces again - and that is the existing confirmation, reached
  /// through the ordinary gate rather than around it.
  func test_rerunInPlace_stillGoesThroughTheReplaceConfirmation() throws {
    let source = try Fixture.image(at: path("holiday.png"))
    let model = AppModel(persistence: store)

    model.rerun(Self.entry(file: source, actions: [.convertFormat(to: .jpeg)], destination: nil))

    let pending = try XCTUnwrap(model.pending)
    XCTAssertEqual(pending.mode, .overwrite)

    let plan = ConversionPlan(
      file: try ProcessableFile(url: source),
      preset: pending.preset,
      destinationMode: pending.mode
    )
    XCTAssertEqual(plan.confirmationLevel, .block, "replacing the original is asked about, every time")
  }

  /// Files chosen now cannot be stale, so there is nothing to warn about.
  func test_reapply_runsTheSameChainOnFilesChosenNow() throws {
    let first = try Fixture.image(at: path("one.png"))
    let second = try Fixture.image(at: path("two.png"))
    let model = AppModel(persistence: store)
    let entry = Self.entry(actions: [.convertFormat(to: .jpeg), .quality(level: 60)])

    model.reapply(entry, to: [first, second])

    let pending = try XCTUnwrap(model.pending)
    XCTAssertEqual(pending.files, [first, second])
    XCTAssertEqual(pending.preset.actions, entry.actions)
    XCTAssertEqual(pending.mode, .copyTo)
    XCTAssertNil(model.lastError)
  }

  // MARK: - Fixtures

  private static func entry(
    file: URL = URL(fileURLWithPath: "/tmp/holiday.png"),
    actions: [Forge.Operation]?,
    destination: URL? = nil
  ) -> ProcessingHistory {
    ProcessingHistory(
      fileURL: file,
      ruleId: UUID(),
      status: .completed,
      duration: 0.2,
      outputURL: destination?.appendingPathComponent("holiday.jpeg"),
      destinationFolder: destination,
      actions: actions,
      presetName: "Web JPEG"
    )
  }
}
