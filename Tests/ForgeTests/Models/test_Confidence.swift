import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// Which conversions are worth a question, and which are not.
///
/// The rule is five facts wide, so it is tested as a table: every column on its
/// own, and the two that argue with each other - a size ceiling the user typed
/// against one a preset brought along - side by side.
final class ConfidenceTests: BaseTestCase {

  // MARK: - The rule itself

  func test_plain_conversionAsksNothing() {
    XCTAssertEqual(ConfirmationLevel(for: ConversionPlan()), .silent)
  }

  /// The whole point: a size the user typed into the filename is their
  /// instruction, not a surprise to be confirmed back at them.
  func test_explicitMagic_isSilent() {
    let plan = ConversionPlan(isLossyOrMagic: true, magicWasExplicit: true)
    XCTAssertEqual(ConfirmationLevel(for: plan), .silent)
  }

  func test_inferredMagic_asksOnce() {
    let plan = ConversionPlan(isLossyOrMagic: true, magicWasExplicit: false)
    XCTAssertEqual(ConfirmationLevel(for: plan), .confirm)
    XCTAssertEqual(plan.reason, .inferredCeiling)
  }

  func test_undefinedParameters_ask() {
    let plan = ConversionPlan(hasUndefinedRequiredParams: true)
    XCTAssertEqual(ConfirmationLevel(for: plan), .confirm)
    XCTAssertEqual(plan.reason, .undefined)
  }

  func test_crossDomainOrExpanding_asks() {
    let plan = ConversionPlan(isCrossDomainOrExpanding: true)
    XCTAssertEqual(ConfirmationLevel(for: plan), .confirm)
    XCTAssertEqual(plan.reason, .crossDomain)
  }

  /// Replacing or moving the originals outranks everything, explicit or not.
  func test_touchingTheOriginals_blocks() {
    let plan = ConversionPlan(
      isLossyOrMagic: true, magicWasExplicit: true, touchesExistingFiles: true
    )
    XCTAssertEqual(ConfirmationLevel(for: plan), .block)
    XCTAssertEqual(plan.reason, .touchesOriginals)
  }

  // MARK: - A whole batch

  func test_batch_ofSettledFilesAsksNothing() {
    let settled = [ConversionPlan(), ConversionPlan(isLossyOrMagic: true, magicWasExplicit: true)]
    XCTAssertEqual(ConfirmationLevel.forBatch(settled), .silent)
  }

  /// One surprising file among a hundred settled ones is still one question.
  func test_batch_takesTheMostSeriousThingInIt() {
    let mixed = [
      ConversionPlan(),
      ConversionPlan(isCrossDomainOrExpanding: true),
      ConversionPlan(),
    ]
    XCTAssertEqual(ConfirmationLevel.forBatch(mixed), .confirm)

    let overwriting = mixed + [ConversionPlan(touchesExistingFiles: true)]
    XCTAssertEqual(ConfirmationLevel.forBatch(overwriting), .block)
  }

  func test_batch_ofNothingAsksNothing() {
    XCTAssertEqual(ConfirmationLevel.forBatch([]), .silent)
  }

  // MARK: - Read off real files

  /// PNG to JPEG at a preset's quality: one file in, one of the same kind out.
  func test_plan_readsAnOrdinaryConversionAsSilent() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("holiday.png")))
    let plan = ConversionPlan(
      file: file,
      preset: .make(format: .jpeg, quality: 80, category: .image),
      destinationMode: .copyTo
    )

    XCTAssertFalse(plan.isLossyOrMagic, "a quality setting is not magic; it is what was asked for")
    XCTAssertFalse(plan.isCrossDomainOrExpanding)
    XCTAssertEqual(plan.confirmationLevel, .silent)
  }

  /// The headline case: the size is in the name the user typed.
  func test_plan_readsTheCeilingOutOfTheFilename() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("holiday_10MB.png")))
    let plan = ConversionPlan(
      file: file,
      preset: .make(format: .jpeg, category: .image),
      destinationMode: .copyTo
    )

    XCTAssertTrue(plan.isLossyOrMagic)
    XCTAssertTrue(plan.magicWasExplicit)
    XCTAssertEqual(
      plan.confirmationLevel, .silent,
      "they typed it; do not ask them to confirm their own typing"
    )
  }

  /// The same ceiling, arriving from a preset the user did not set just now.
  func test_plan_readsACeilingFromThePresetAsWorthAsking() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("holiday.png")))
    var preset = RulePreset.make(format: .jpeg, category: .image)
    preset.actions.append(.limitSize(bytes: 10_000_000))

    let plan = ConversionPlan(file: file, preset: preset, destinationMode: .copyTo)

    XCTAssertTrue(plan.isLossyOrMagic)
    XCTAssertFalse(plan.magicWasExplicit)
    XCTAssertEqual(plan.confirmationLevel, .confirm)
  }

  func test_plan_readsNoPresetAsUndefined() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("holiday.png")))
    let plan = ConversionPlan(file: file, preset: nil, destinationMode: .copyTo)

    XCTAssertTrue(plan.hasUndefinedRequiredParams)
    XCTAssertEqual(plan.confirmationLevel, .confirm)
  }

  /// An image asked for text is a reading job, not a conversion of the same
  /// kind, and it is worth showing what comes out.
  func test_plan_readsImageToTextAsCrossDomain() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("scan.png")))
    let plan = ConversionPlan(
      file: file,
      preset: .make(format: .plainText, category: .image),
      destinationMode: .copyTo
    )

    XCTAssertTrue(plan.isCrossDomainOrExpanding)
    XCTAssertEqual(plan.confirmationLevel, .confirm)
  }

  /// One file in, two out.
  func test_plan_readsAPresetWithTwoFormatsAsExpanding() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("holiday.png")))
    var preset = RulePreset.make(format: .jpeg, category: .image)
    preset.actions.append(.convertFormat(to: .png))

    let plan = ConversionPlan(file: file, preset: preset, destinationMode: .copyTo)

    XCTAssertTrue(plan.isCrossDomainOrExpanding)
    XCTAssertEqual(plan.confirmationLevel, .confirm)
  }

  func test_plan_readsOverwriteAsBlocking() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("holiday_10MB.png")))
    for mode in [DestinationMode.overwrite, .moveTo] {
      let plan = ConversionPlan(
        file: file,
        preset: .make(format: .jpeg, category: .image),
        destinationMode: mode
      )
      XCTAssertEqual(plan.confirmationLevel, .block, "\(mode) changes what is already on disk")
    }
  }

  // MARK: - The preview behind the popup

  /// The popup shows the real thing, so it runs the real chain - into scratch,
  /// and without becoming an event in anybody's history.
  func test_preview_convertsForRealAndRecordsNothing() async throws {
    let source = try Fixture.image(at: path("holiday.png"))
    let scratch = try folder("preview")

    let result = try await coordinator().preview(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 60, category: .image),
      into: scratch
    )

    XCTAssertEqual(result.outputURL.pathExtension, "jpeg")
    XCTAssertGreaterThan(result.outputSize, 0)
    XCTAssertEqual(result.appliedQuality, 60, "the sheet says what the quality was")
    XCTAssertTrue(exists(result.outputURL))
    XCTAssertEqual(
      result.outputURL.deletingLastPathComponent().standardizedFileURL,
      scratch.standardizedFileURL,
      "a preview writes into scratch, never beside the user's file"
    )

    let history = try await store.loadHistory()
    XCTAssertTrue(history.isEmpty, "a preview somebody cancelled did not happen")
  }

  /// A ceiling is kept by writing the file again lower until it fits, so the
  /// quality is a result. The sheet's "@ q72" comes from here.
  func test_preview_reportsTheQualityACeilingSettledOn() async throws {
    let source = try Fixture.image(at: path("big.png"), width: 1400, height: 1000)
    let scratch = try folder("preview")

    var preset = RulePreset.make(format: .jpeg, quality: 95, category: .image)
    preset.actions.append(.limitSize(bytes: 20_000))

    let result = try await coordinator().preview(
      try ProcessableFile(url: source), with: preset, into: scratch
    )

    XCTAssertLessThanOrEqual(result.outputSize, 20_000)
    let quality = try XCTUnwrap(result.appliedQuality)
    XCTAssertLessThan(quality, 95, "getting under the ceiling cost quality, and the number says how much")
  }
}
