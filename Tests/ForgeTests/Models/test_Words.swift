import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// What a file in a watched folder is asking for, read from its name.
final class ArrivalTests: XCTestCase {
  private let web = RulePreset(name: "Web JPEG", description: "", category: .image, actions: [.convertFormat(to: .jpeg), .quality(level: 80)])

  private func preset(word: String, category: PresetCategory = .custom, asks: [PresetParameter] = []) -> RulePreset {
    var made = RulePreset(name: word, description: "", category: category, actions: [.convertFormat(to: .png)])
    made.nameTrigger = word
    made.parameters = asks
    return made
  }

  private func arrival(_ name: String, _ others: [RulePreset] = [], renamedOnly: Bool = false) -> Arrival {
    Arrival.of(URL(fileURLWithPath: "/tmp/\(name)"), folderPreset: web, presets: others + [web], onlyWhenRenamed: renamedOnly)
  }

  func test_anOrdinaryFileRunsTheFoldersPreset() {
    XCTAssertEqual(arrival("goose.heic"), .run(web))
  }

  /// A desk watched for renames leaves a new screenshot alone.
  func test_onlyWhenRenamedLeavesOrdinaryFilesAlone() {
    XCTAssertEqual(arrival("Screenshot 2026-11-24.png", renamedOnly: true), .leave)
    XCTAssertEqual(arrival("report_q3.pdf", renamedOnly: true), .leave, "a quarter is not an instruction")
  }

  func test_onlyWhenRenamedStillDoesWhatTheNameSays() {
    for name in ["goose_2MB.heic", "goose_privacy.heic", "goose_800px.heic", "goose_q80.heic"] {
      XCTAssertEqual(arrival(name, renamedOnly: true), .run(web), name)
    }
  }

  func test_aPresetsOwnWordRunsThatPreset() {
    let insta = preset(word: "igpost")
    XCTAssertEqual(arrival("goose_igpost.heic", [insta]), .run(insta))
    XCTAssertEqual(arrival("goose_igpost.heic", [insta], renamedOnly: true), .run(insta))
  }

  func test_aPresetThatIsOffDoesNotAnswerToItsWord() {
    var off = preset(word: "igpost")
    off.isEnabled = false
    XCTAssertEqual(arrival("goose_igpost.heic", [off], renamedOnly: true), .leave)
  }

  func test_aPresetThatTakesOtherFilesIsNotRun() {
    let sound = preset(word: "loud", category: .audio)
    XCTAssertEqual(arrival("goose_loud.heic", [sound]), .leave)
  }

  /// The word of a preset that asks something opens the question.
  func test_aWordWhosePresetAsksOpensTheQuestion() throws {
    let width = PresetParameter(key: "width", label: "Width", kind: .width)
    let asks = preset(word: "asksize", asks: [width])
    guard case .ask(let request) = arrival("goose_asksize.heic", [asks]) else { return XCTFail("it ran without asking") }
    XCTAssertEqual(request.preset, asks)
    XCTAssertEqual(request.questions, [.parameter(width)])
  }

  /// A question the file's own name answers is not put to anybody.
  func test_aQuestionAnsweredByTheNameIsNotAsked() {
    let fromName = preset(word: "small", asks: [PresetParameter(key: "maxsize", label: "", kind: .maxFileSize, source: .fileName)])
    XCTAssertEqual(arrival("goose_small.heic", [fromName]), .run(fromName))
  }

  func test_theBuiltInWordsAsk() throws {
    let expected: [String: [AskRequest.Question]] = [
      "goose_asksize.heic": [.size], "goose_askwidth.heic": [.width], "goose_askquality.heic": [.quality],
      "goose_askformat.heic": [.format], "goose_ask.heic": [.format, .size, .privacy],
    ]
    for (name, questions) in expected {
      guard case .ask(let request) = arrival(name, renamedOnly: true) else { XCTFail(name); continue }
      XCTAssertEqual(request.questions, questions, name)
    }
  }

  /// "How to ask" is a title. Where every file is converted anyway, the bare
  /// word is not read as an instruction.
  func test_theBareWordIsOnlyReadWhereNamesAreWhatCounts() {
    XCTAssertEqual(arrival("how_to_ask.heic"), .run(web))
  }

  /// Asked over a folder's preset, everything else it says still holds.
  func test_askingKeepsTheRestOfTheFoldersPreset() {
    var mine = web
    mine.nameTemplate = "{name}-web"
    mine.outputExtension = "jpg"
    mine.gate = Condition()
    guard case .ask(let request) = Arrival.of(URL(fileURLWithPath: "/tmp/a_asksize.heic"), folderPreset: mine, presets: [], onlyWhenRenamed: false) else { return XCTFail() }
    XCTAssertEqual(request.preset.nameTemplate, "{name}-web")
    XCTAssertEqual(request.preset.outputExtension, "jpg")
    XCTAssertEqual(request.preset.gate, mine.gate)
    XCTAssertNotEqual(request.preset.id, mine.id, "a run of its own")
  }

  /// Your word beats Forge's.
  func test_aPresetWithABuiltInWordWins() {
    let mine = preset(word: "ask")
    XCTAssertEqual(arrival("goose_ask.heic", [mine]), .run(mine))
  }

  /// The word is an instruction, not part of the name that comes out.
  func test_theAskedWordIsDroppedFromTheOutputsName() {
    guard case .ask(let request) = arrival("goose_asksize.heic") else { return XCTFail() }
    XCTAssertEqual(request.preset.untriggered(stem: "goose_asksize"), "goose")
  }

  func test_aFolderPresetThatIsGoneLeavesEverythingAlone() {
    XCTAssertEqual(Arrival.of(URL(fileURLWithPath: "/tmp/a.png"), folderPreset: nil, presets: [], onlyWhenRenamed: false), .leave)
  }
}

/// What the little menu offers, and what each answer runs.
final class AskOptionsTests: BaseTestCase {
  private let blank = RulePreset(name: "Asked", description: "", category: .custom)

  private func photo(_ width: Int = 2000, _ height: Int = 1500, name: String = "a.png") throws -> ProcessableFile {
    try ProcessableFile(url: Fixture.image(at: path(name), width: width, height: height))
  }

  func test_sizesBiggerThanTheFileAreNotOffered() throws {
    let file = try photo(64, 64)
    let choices = AskOptions.choices(for: .size, files: [file])
    XCTAssertTrue(choices.allSatisfy { if case .bytes(let n) = $0.value { return n < file.fileSize } else { return false } })
  }

  func test_widthsWiderThanThePictureAreNotOffered() throws {
    let labels = AskOptions.choices(for: .width, files: [try photo(1200, 800)]).map(\.label)
    XCTAssertEqual(labels, ["800 px", "1080 px"])
  }

  func test_formatsAreTheUsualOnesWithoutItsOwn() throws {
    let labels = AskOptions.choices(for: .format, files: [try photo()]).map(\.label)
    XCTAssertEqual(labels.first, "JPEG")
    XCTAssertFalse(labels.contains("PNG"), "it is one already")
    XCTAssertTrue(labels.contains("PDF"))
  }

  func test_aDataFileHasNoSizeToChoose() throws {
    let csv = path("a.csv")
    try "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)
    XCTAssertTrue(AskOptions.choices(for: .size, files: [try ProcessableFile(url: csv)]).isEmpty)
  }

  /// A preset's default is the first thing offered, and said to be one.
  func test_aPresetsQuestionStartsWithItsDefault() throws {
    let asks = PresetParameter(key: "width", label: "", kind: .width, defaultValue: 640)
    let first = try XCTUnwrap(AskOptions.choices(for: .parameter(asks), files: [try photo()]).first)
    XCTAssertEqual(first.label, "640 px")
    XCTAssertTrue(first.isDefault)
  }

  func test_anAnswerBecomesTheStepItStandsFor() {
    let request = AskRequest(preset: blank, questions: [.format, .size, .privacy])
    let run = request.answered(with: [.format: .format(.png), .size: .bytes(100_000), .privacy: .flag(true)])
    XCTAssertEqual(run.actions, [.convertFormat(to: .png), .limitSize(bytes: 100_000), .stripMetadata(policy: .stripAll)])
  }

  func test_nothingAnsweredChangesNothing() {
    let request = AskRequest(preset: blank, questions: [.format, .privacy])
    XCTAssertEqual(request.answered(with: [.privacy: .flag(false)]).actions, [])
  }

  /// Asked over a preset, the answer replaces what the preset said.
  func test_anAnswerBeatsThePreset() {
    let base = RulePreset(name: "x", description: "", category: .image, actions: [.convertFormat(to: .jpeg), .quality(level: 80)])
    let run = AskRequest(preset: base, questions: [.quality]).answered(with: [.quality: .number(60)])
    XCTAssertEqual(run.actions, [.convertFormat(to: .jpeg), .quality(level: 60)])
  }

  func test_aPresetsQuestionIsAnsweredByItsKey() {
    var preset = blank
    let width = PresetParameter(key: "w", label: "", kind: .width)
    preset.parameters = [width]
    let run = AskRequest(preset: preset, questions: [.parameter(width)]).answered(with: [.parameter(width): .number(640)])
    XCTAssertEqual(run.actions, [.resize(width: 640, height: nil, fitMode: .proportional)])
    XCTAssertEqual(run.parameterValues["w"], 640, "and the name can spend it")
  }

  /// Typed sizes: 300 is kilobytes when it has to be, and units are read.
  func test_anAbsurdSizeIsNotAnAnswerAndNotACrash() {
    for text in ["1e13", "inf", "99999999999999999999", "9999999999999 gb", "nan"] {
      XCTAssertNil(AskOptions.typed(text, for: .size), text)
    }
    XCTAssertNil(SizeInName.ceiling(in: "photo_99999999999999999gb.jpg"))
  }

  func test_typedSizesAreRead() {
    XCTAssertEqual(AskOptions.typed("300 kb", for: .size), .bytes(300_000))
    XCTAssertEqual(AskOptions.typed("1,5 MB", for: .size), .bytes(1_500_000))
    XCTAssertEqual(AskOptions.typed("2", for: .size), .bytes(2_000_000), "a bare number is megabytes")
    XCTAssertEqual(AskOptions.typed("640 px", for: .width), .number(640))
    XCTAssertEqual(AskOptions.typed("70%", for: .quality), .number(70))
    XCTAssertNil(AskOptions.typed("big", for: .size))
    XCTAssertNil(AskOptions.typed("0", for: .width))
    XCTAssertNil(AskOptions.typed("300", for: .quality), "over a hundred is not a quality")
  }
}

/// Files that ask the same thing at the same time are one question.
@MainActor
final class AskCenterTests: BaseTestCase {
  private func file(_ name: String) throws -> ProcessableFile { try ProcessableFile(url: Fixture.image(at: path(name))) }
  private let request = AskRequest(preset: RulePreset(name: "Asked", description: "", category: .custom), questions: [.size])

  func test_theSameQuestionForTwoFilesIsAskedOnce() throws {
    let center = AskCenter(shows: false)
    center.ask(request, about: try file("a.png")) { _, _ in [] }
    center.ask(request, about: try file("b.png")) { _, _ in [] }
    XCTAssertEqual(center.current?.files.count, 2)
    XCTAssertEqual(center.waiting, 0)
  }

  /// Two files renamed together, each read from its own name.
  func test_aBuiltInWordOnTwoFilesIsOneQuestion() throws {
    let center = AskCenter(shows: false)
    for name in ["a_askwidth.png", "b_askwidth.png"] {
      let file = try file(name)
      guard case .ask(let request) = Arrival.of(file.url, folderPreset: nil, presets: [], onlyWhenRenamed: true) else { return XCTFail() }
      center.ask(request, about: file) { _, _ in [] }
    }
    XCTAssertEqual(center.current?.files.count, 2)
    XCTAssertEqual(center.waiting, 0)
  }

  /// The menu measures with everything chosen so far, not each choice alone.
  func test_measuringCountsWhatIsAlreadyChosen() async throws {
    let center = AskCenter(shows: false)
    var tried: [[Forge.Operation]] = []
    center.preview = { file, preset, _ in
      tried.append(preset.actions)
      return ProcessingResult(outputURL: file.url, outputSize: 1, outputDimensions: nil, duration: 0)
    }
    let asks = AskRequest(preset: request.preset, questions: [.format, .width])
    let source = try ProcessableFile(url: Fixture.image(at: path("wide.png"), width: 1200, height: 800))
    center.ask(asks, about: source) { _, _ in [] }
    let session = try XCTUnwrap(center.current)
    session.choose(.number(800), for: .width)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertTrue(tried.contains { $0.contains(.convertFormat(to: .jpeg)) && $0.contains(.resize(width: 800, height: nil, fitMode: .proportional)) })
  }

  func test_anotherQuestionWaitsItsTurn() throws {
    let center = AskCenter(shows: false)
    center.ask(request, about: try file("a.png")) { _, _ in [] }
    center.ask(AskRequest(preset: request.preset, questions: [.width]), about: try file("b.png")) { _, _ in [] }
    XCTAssertEqual(center.current?.files.count, 1)
    XCTAssertEqual(center.waiting, 1)
    center.dismiss()
    XCTAssertEqual(center.current?.request.questions, [.width])
    center.dismiss()
    XCTAssertNil(center.current)
  }

  /// Two folders send their files to different places, and one of them may
  /// replace originals: their questions are never one.
  func test_twoFoldersAreNeverOneQuestion() throws {
    let center = AskCenter(shows: false)
    center.ask(request, from: UUID(), about: try file("a.png")) { _, _ in [] }
    center.ask(request, from: UUID(), about: try file("b.png")) { _, _ in [] }
    XCTAssertEqual(center.current?.files.count, 1)
    XCTAssertEqual(center.waiting, 1)
  }

  func test_theSameFileIsNotAskedAboutTwice() throws {
    let center = AskCenter(shows: false), folder = UUID(), one = try file("a.png")
    center.ask(request, from: folder, about: one) { _, _ in [] }
    center.ask(request, from: folder, about: try ProcessableFile(url: one.url)) { _, _ in [] }
    XCTAssertEqual(center.current?.files.count, 1)
  }

  /// One file that fails does not take the others with it.
  func test_aFailureDoesNotStopTheRest() async throws {
    let center = AskCenter(shows: false)
    var ran: [String] = []
    for name in ["a.png", "b.png", "c.png"] {
      center.ask(request, about: try file(name)) { file, _ in
        ran.append(file.fileName)
        if file.fileName == "a.png" { throw ProcessingError.conversionFailed(reason: "too big") }
        return [file.url]
      }
    }
    let session = try XCTUnwrap(center.current)
    session.choose(.bytes(50_000), for: .size)
    await session.run()
    XCTAssertEqual(ran, ["a.png", "b.png", "c.png"])
    guard case .failed(let reason) = session.state else { return XCTFail() }
    XCTAssertTrue(reason.contains("1 of 3"), reason)
  }

  /// Stopped from the main window: the panel says so instead of waiting for
  /// ever with every later question behind it.
  func test_aStoppedConversionIsSaid() async throws {
    let center = AskCenter(shows: false)
    center.ask(request, about: try file("a.png")) { _, _ in throw CancellationError() }
    let session = try XCTUnwrap(center.current)
    session.choose(.bytes(50_000), for: .size)
    await session.run()
    guard case .failed = session.state else { return XCTFail("\(session.state)") }
  }

  /// Closing the panel while it works stops the work.
  func test_closingWhileWorkingStopsIt() async throws {
    let center = AskCenter(shows: false)
    var finished = false, cancelled = false
    center.ask(request, about: try file("a.png")) { file, _ in
      do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { cancelled = true; throw error }
      finished = true
      return [file.url]
    }
    let session = try XCTUnwrap(center.current)
    session.choose(.bytes(50_000), for: .size)
    session.start()
    try await Task.sleep(nanoseconds: 200_000_000)
    center.dismiss()
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertTrue(cancelled)
    XCTAssertFalse(finished)
  }

  /// A question nobody answers converts nothing.
  func test_dismissingLeavesTheFileAlone() throws {
    let center = AskCenter(shows: false)
    var ran = 0
    center.ask(request, about: try file("a.png")) { _, _ in ran += 1; return [] }
    center.dismiss()
    XCTAssertEqual(ran, 0)
  }

  func test_answeringRunsEveryFileWithTheAnswer() async throws {
    let center = AskCenter(shows: false)
    var seen: [(String, [Forge.Operation])] = []
    for name in ["a.png", "b.png"] {
      center.ask(request, about: try file(name)) { file, preset in seen.append((file.fileName, preset.actions)); return [file.url] }
    }
    let session = try XCTUnwrap(center.current)
    session.choose(.bytes(50_000), for: .size)
    await session.run()
    XCTAssertEqual(seen.map(\.0).sorted(), ["a.png", "b.png"])
    XCTAssertTrue(seen.allSatisfy { $0.1 == [.limitSize(bytes: 50_000)] })
    guard case .done(let outputs) = session.state else { return XCTFail("not done: \(session.state)") }
    XCTAssertEqual(outputs.count, 2)
  }

  func test_aFailureIsSaidInThePanel() async throws {
    let center = AskCenter(shows: false)
    center.ask(request, about: try file("a.png")) { _, _ in throw ProcessingError.conversionFailed(reason: "too big") }
    let session = try XCTUnwrap(center.current)
    session.choose(.bytes(50_000), for: .size)
    await session.run()
    guard case .failed(let reason) = session.state else { return XCTFail() }
    XCTAssertTrue(reason.contains("too big"))
  }
}

/// A watched folder saved by an older version still loads, and the new
/// setting survives a save.
final class MonitoredFolderStorageTests: XCTestCase {
  func test_aFolderSavedBeforeTheSettingExisted() throws {
    let json = #"{"id":"7144E204-662E-4E7A-A990-3DCEF7916560","url":"file:///tmp/in","ruleId":"7144E204-662E-4E7A-A990-3DCEF7916561","destinationMode":"copy_to","isActive":true,"includeSubfolders":true}"#
    let folder = try JSONDecoder().decode(MonitoredFolder.self, from: Data(json.utf8))
    XCTAssertFalse(folder.onlyWhenRenamed)
    XCTAssertTrue(folder.includeSubfolders)
  }

  func test_itIsKept() throws {
    var folder = MonitoredFolder(url: URL(fileURLWithPath: "/tmp/in"), ruleId: UUID(), destinationMode: .overwrite)
    folder.onlyWhenRenamed = true
    XCTAssertEqual(try JSONDecoder().decode(MonitoredFolder.self, from: JSONEncoder().encode(folder)), folder)
    XCTAssertEqual(folder.arrivalSentence, "When files are renamed in /tmp/in")
  }
}

/// A question nobody was there to answer takes its default.
final class SettledDefaultTests: BaseTestCase {
  func test_aQuestionWithNobodyToAnswerTakesItsDefault() async throws {
    let source = try Fixture.image(at: path("a.png"), width: 800, height: 600)
    var preset = RulePreset(name: "Ask", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])
    preset.parameters = [PresetParameter(key: "width", label: "", kind: .width, defaultValue: 200)]

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")
    ) { _ in }

    let written = try ProcessableFile(url: XCTUnwrap(entry.outputURL))
    XCTAssertEqual(written.dimensions?.width, 200, "the question used to be dropped, default and all")
    XCTAssertEqual(entry.actions?.contains(.resize(width: 200, height: nil, fitMode: .proportional)), true, "and History says what was done")
  }

  func test_anAnswerGivenIsNotReplacedByTheDefault() async throws {
    let source = try Fixture.image(at: path("a.png"), width: 800, height: 600)
    var preset = RulePreset(name: "Ask", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])
    preset.parameters = [PresetParameter(key: "width", label: "", kind: .width, defaultValue: 200)]
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source), with: preset.answered(with: ["width": 400]), destinationMode: .copyTo, destinationURL: try folder("out")
    ) { _ in }
    XCTAssertEqual(try ProcessableFile(url: XCTUnwrap(entry.outputURL)).dimensions?.width, 400)
  }
}
