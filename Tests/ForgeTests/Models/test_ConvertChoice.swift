import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// What the Convert sheet and the maker hand the coordinator.
final class ConvertChoiceTests: XCTestCase {
  private let webJPEG = RulePreset(
    name: "Web JPEG", description: "", category: .image,
    actions: [.convertFormat(to: .jpeg), .quality(level: 80)]
  )

  /// Nothing chosen is nothing to run: Convert stays off rather than writing a
  /// copy of the file under a new name.
  func test_anEmptyChoiceResolvesToNothing() {
    XCTAssertNil(ConvertChoice().resolved(against: []))
  }

  func test_aFormatAloneIsAConversion() throws {
    let preset = try XCTUnwrap(ConvertChoice().choosing(.png).resolved(against: []))
    XCTAssertEqual(preset.actions, [.convertFormat(to: .png)])
  }

  /// A chosen preset is run as it stands.
  func test_aChosenPresetIsRunWhole() {
    let preset = RulePreset(
      name: "Two filters", description: "", category: .image,
      actions: [.filter(type: .grayscale), .filter(type: .sepia)]
    )
    let choice = ConvertChoice().adopting(preset)
    XCTAssertEqual(choice.resolved(against: [preset]), preset)
  }

  /// Another format keeps the steps, which the sheet lists, and lets go of
  /// everything it does not show.
  func test_changingTheFormatLetsThePresetGoAndKeepsItsSteps() throws {
    var preset = webJPEG
    preset.nameTemplate = "{name}_web"
    preset.gate = Condition()
    preset.nameTrigger = "web"
    preset.outputExtension = "jpg"
    preset.parameters = [PresetParameter(key: "width", label: "Width", kind: .width)]

    let choice = ConvertChoice().adopting(preset).choosing(.png)

    XCTAssertNil(choice.presetID)
    let run = try XCTUnwrap(choice.resolved(against: [preset]))
    XCTAssertEqual(run.actions, [.convertFormat(to: .png), .quality(level: 80)])
    XCTAssertNotEqual(run.id, preset.id, "a run of its own, not a run of the preset")
    XCTAssertNil(run.nameTemplate)
    XCTAssertNil(run.gate)
    XCTAssertNil(run.nameTrigger)
    XCTAssertNil(run.outputExtension)
    XCTAssertTrue(run.parameters.isEmpty)
  }

  func test_aSecondFormatReplacesTheFirst() {
    XCTAssertEqual(ConvertChoice().choosing(.png).choosing(.tiff).formats, [.tiff])
  }

  /// Asking for text reads it, and asking for a picture after that does not.
  func test_textReadsTheWordsAndAnotherFormatStops() {
    let text = ConvertChoice().choosing(.plainText)
    XCTAssertEqual(text.draft.actions, [.convertFormat(to: .plainText), .recognizeText(languages: [])])
    XCTAssertEqual(text.choosing(.png).draft.actions, [.convertFormat(to: .png)])
  }

  /// Looking in the maker and changing nothing is not a change.
  func test_backFromTheMakerUntouchedIsStillThePreset() {
    let choice = ConvertChoice().adopting(webJPEG)
    var same = webJPEG
    same.id = UUID()
    same.name = ""
    XCTAssertEqual(choice.edited(same).presetID, webJPEG.id)
  }

  /// What was built in the maker runs, rules included: they were on screen.
  func test_backFromTheMakerChangedRunsWhatTheMakerSays() throws {
    var changed = webJPEG
    changed.actions.append(.resize(width: 1080, height: nil, fitMode: .proportional))
    changed.gate = Condition()

    let choice = ConvertChoice().adopting(webJPEG).edited(changed)

    XCTAssertNil(choice.presetID)
    let run = try XCTUnwrap(choice.resolved(against: [webJPEG]))
    XCTAssertEqual(run.actions, changed.actions)
    XCTAssertEqual(run.gate, changed.gate)
    XCTAssertNotEqual(run.id, webJPEG.id)
  }

  /// Answers given in the sheet are the defaults the maker shows, so nothing
  /// is asked that was already answered.
  func test_theMakerStartsFromTheAnswersGiven() {
    var preset = webJPEG
    preset.parameters = [PresetParameter(key: "width", label: "Width", kind: .width)]
    var choice = ConvertChoice().adopting(preset)
    choice.answers["width"] = 640
    XCTAssertEqual(choice.draftForMaker.parameters.first?.defaultValue, 640)
  }

  /// A new batch starts with nothing but where its files go.
  func test_clearedKeepsOnlyWhereFilesGo() {
    var choice = ConvertChoice().adopting(webJPEG)
    choice.answers["width"] = 640
    choice.destinationURL = URL(fileURLWithPath: "/tmp/out")
    choice.destinationMode = .moveTo
    let next = choice.cleared()
    XCTAssertNil(next.resolved(against: []))
    XCTAssertTrue(next.answers.isEmpty)
    XCTAssertEqual(next.destinationMode, .moveTo)
    XCTAssertEqual(next.destinationURL, choice.destinationURL)
  }
}

/// The formats shown first, and the rest behind "All formats…".
final class CommonFormatTests: BaseTestCase {
  func test_aPictureIsOfferedTheUsualFormatsFirst() throws {
    let file = try ProcessableFile(url: Fixture.image(at: path("a.png")))
    let all = ConvertKind.image.outputGroups(for: [file]).flatMap(\.formats)
    let first = ConvertKind.image.leading(of: all)
    XCTAssertEqual(first.first?.label, "JPEG")
    XCTAssertLessThan(first.count, all.count)
    XCTAssertTrue(Set(first).isSubset(of: Set(all)), "nothing is offered that cannot be written")
  }

  /// A kind with few formats has nothing to hide.
  func test_aKindWithNoShortListShowsEverything() {
    let all = OutputFormat.data
    XCTAssertEqual(ConvertKind.data.leading(of: all), all)
  }

  /// A short list none of which can be written is not an empty sheet.
  func test_aShortListThatDoesNotApplyShowsEverything() {
    let all = [OutputFormat(type: .json)]
    XCTAssertEqual(ConvertKind.image.leading(of: all), all)
  }
}

/// The + between two blocks puts a block exactly there.
final class InsertPointTests: XCTestCase {
  func test_beforeAStepInsideAnArmOffersAFormatOfItsOwn() {
    let inner = Action(.quality(level: 80))
    var fork = Action(.split([Branch(name: "A"), Branch(name: "B")]))
    fork.branches[0].actions = [inner]
    let steps = [Action(.filter(type: .sepia)), fork]

    func kinds(_ id: UUID) -> [String] { InsertPoint.step(id).offers(for: .image, in: steps).map(\.title) }

    XCTAssertTrue(kinds(inner.id).contains("Comes out as"))
    XCTAssertFalse(kinds(fork.id).contains("Comes out as"), "the main line has its own block for that")
    XCTAssertFalse(kinds(fork.id).contains("Ask for width"), "questions come before every step")
    XCTAssertTrue(kinds(steps[0].id).contains("Ask for width"))
    XCTAssertTrue(kinds(fork.id).contains("Resize"))
  }

  func test_betweenQuestionsOnlyAnotherQuestionFits() {
    let titles = InsertPoint.question(0).offers(for: .image, in: []).map(\.title)
    XCTAssertEqual(titles, ["Ask for max file size", "Ask for width", "Ask for quality"])
  }
}

/// What the maker offers for the files it was opened with.
final class EditorConversionTests: BaseTestCase {
  private func conversion(_ urls: [URL]) throws -> EditorConversion {
    EditorConversion(
      sources: try urls.map { try ProcessableFile(url: $0) }, fitMode: .proportional,
      mode: .copyTo, destination: nil, onBack: { _ in }, onConvert: { _ in }
    )
  }

  func test_aPictureIsOfferedWhatPicturesBecome() throws {
    let one = try conversion([Fixture.image(at: path("a.png"))])
    XCTAssertTrue(one.formats.contains(OutputFormat(type: .jpeg)))
    XCTAssertEqual(one.category, .image)
    XCTAssertEqual(one.title, "a.png")
  }

  /// A CSV cannot become a JPEG, so the two together are not offered one.
  func test_filesWithNothingInCommonAreOfferedNoFormat() throws {
    let csv = path("b.csv")
    try "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)
    let mixed = try conversion([Fixture.image(at: path("a.png")), csv])
    XCTAssertTrue(mixed.formats.isEmpty)
    XCTAssertEqual(mixed.category, .custom)
    XCTAssertEqual(mixed.title, "2 files")
  }

  func test_mixedKindsKeepWhatTheyShare() throws {
    let sound = path("c.wav")
    try Fixture.audio(at: sound, seconds: 1)
    let mixed = try conversion([Fixture.image(at: path("a.png")), sound])
    XCTAssertEqual(mixed.formats, [OutputFormat(type: .plainText)], "both can be read into text")
  }
}
