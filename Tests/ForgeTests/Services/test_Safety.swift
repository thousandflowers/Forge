import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// What running every function of the released build turned up in the parts
/// that decide whether a file survives: each of these lost something, or left
/// something behind, and most of them said the conversion had gone well.
final class SafetyTests: BaseTestCase {

  private func everything(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  // MARK: - Move

  /// A preset that writes two files ran the conversion twice, and the first
  /// run, told to move, deleted the original. The second then had nothing to
  /// read: one output, an error, and no source.
  func test_aMoveWithTwoFormatsKeepsTheOriginalUntilBothAreWritten() async throws {
    let source = try Fixture.image(at: path("photo.jpg"))
    let destination = try folder("out")
    var preset = RulePreset.make(category: .image)
    preset.actions = [.convertFormat(to: .png), .convertFormat(to: .tiff)]

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .moveTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    XCTAssertEqual(contents(of: destination), ["photo.png", "photo.tiff"])
    XCTAssertFalse(exists(source), "a move takes the original away once both copies exist")
  }

  func test_aMoveThroughASplitKeepsTheOriginalUntilEveryCopyIsWritten() async throws {
    let source = try Fixture.image(at: path("photo.jpg"))
    let destination = try folder("out")
    var preset = RulePreset.make(category: .image)
    preset.actions = [.split([
      Branch(name: "web", actions: [.convertFormat(to: .jpeg)]),
      Branch(name: "arch", actions: [.convertFormat(to: .png)]),
    ])]

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .moveTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    XCTAssertEqual(contents(of: destination), ["photo_arch.png", "photo_web.jpeg"])
    XCTAssertFalse(exists(source))
  }

  // MARK: - History

  /// The record of a conversion is bookkeeping. With a History file that could
  /// not be read, every conversion wrote its output and was then reported as
  /// failed, for ever, because nothing ever repaired the file.
  func test_anUnreadableHistoryDoesNotTurnAConversionIntoAFailure() async throws {
    let source = try Fixture.image(at: path("photo.png"))
    let destination = try folder("out")
    let history = store.root.appendingPathComponent("History.json")
    try Data("not json at all".utf8).write(to: history)

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    XCTAssertEqual(contents(of: destination), ["photo.jpeg"])
    let recorded = try await store.loadHistory()
    XCTAssertEqual(recorded.count, 1, "history starts again, with this conversion in it")
    XCTAssertTrue(
      everything(in: store.root).contains { $0.hasPrefix("History.unreadable") },
      "what could not be read is set aside, not thrown away: \(everything(in: store.root))"
    )
  }

  // MARK: - Names

  /// A name template is text somebody else may have written - a preset from
  /// the gallery, a file a friend sent. `../../x` in one wrote outside the
  /// folder the user chose.
  func test_aNameTemplateCannotLeaveTheDestinationFolder() async throws {
    let source = try Fixture.image(at: path("photo.png"))
    let destination = try folder("deep/er/out")
    var preset = RulePreset.make(format: .jpeg, category: .image)
    preset.nameTemplate = "../../escaped_{name}"

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(
      output.deletingLastPathComponent().standardizedFileURL.path,
      destination.standardizedFileURL.path
    )
    XCTAssertEqual(everything(in: path("deep")), ["er"], "nothing was written above the destination")
  }

  func test_aNameIsOneNameNotAPath() {
    let context = NameTemplate.Static(name: "photo", ext: "jpeg")
    XCTAssertEqual(NameTemplate.resolve("a/b:{name}", with: context), "a-b-photo")
    XCTAssertEqual(NameTemplate.resolve("..{name}", with: context), "photo", "no hidden files, no way up")
    XCTAssertEqual(NameTemplate.resolve("{name}\nv2", with: context), "photo v2")
  }

  // MARK: - Leftovers

  /// ImageIO writes through a temporary file of its own, named after the one
  /// it was asked for with a dot in front. When the write failed that file
  /// stayed, hidden, in the user's folder - and the error named Forge's own
  /// scratch file instead of anything the user would recognise.
  func test_aWriteThatFailsLeavesNothingBehindAndNamesTheFile() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 300, height: 200)
    let destination = try folder("out")
    // Not square: ICNS only takes its own handful of square sizes.
    let icns = try XCTUnwrap(UTType("com.apple.icns"))

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: icns, category: .image),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      // If this Mac can write it after all, there is nothing to check.
    } catch {
      XCTAssertFalse(error.localizedDescription.contains(".forge-"), error.localizedDescription)
      XCTAssertTrue(error.localizedDescription.contains("photo.png"), error.localizedDescription)
    }
    XCTAssertEqual(
      everything(in: destination).filter { $0.hasPrefix(".") }, [],
      "hidden scratch files left in the destination"
    )
  }

  // MARK: - Duplicate

  /// Duplicate rebuilt the preset from the four fields the first version of
  /// Forge had, so the copy lost its name template, its questions, its test,
  /// its trigger word and every block that was not format, size, quality or
  /// filter - an If, a Split, a Merge, Remove metadata.
  func test_aDuplicateIsTheSamePresetUnderAnotherName() throws {
    var original = RulePreset.make(format: .jpeg, category: .image)
    original.name = "Web"
    original.actions += [
      .stripMetadata(policy: .stripAll),
      .split([Branch(name: "a", actions: [.resize(width: 800, height: nil, fitMode: .proportional)]), Branch(name: "b")]),
      .join,
    ]
    original.nameTemplate = "{name}_v{width}"
    original.nameTrigger = "web"
    original.inputFormats = ["png", "heic"]
    original.gate = try JSONDecoder().decode(
      Condition.self,
      from: Data(#"{"subject":"longestSide","comparison":"greaterThan","value":2000,"text":""}"#.utf8)
    )

    let copy = original.duplicate()

    XCTAssertNotEqual(copy.id, original.id)
    XCTAssertEqual(copy.name, "Web copy")
    XCTAssertEqual(copy.actions, original.actions)
    XCTAssertEqual(copy.nameTemplate, original.nameTemplate)
    XCTAssertEqual(copy.inputFormats, original.inputFormats)
    XCTAssertEqual(copy.gate, original.gate)
    XCTAssertEqual(copy.parameters, original.parameters)
    XCTAssertNil(copy.nameTrigger, "two presets answering to one word would fight over the file")
  }
}
