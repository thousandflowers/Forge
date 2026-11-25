import XCTest
import UniformTypeIdentifiers
@testable import Forge

final class PremiumTests: BaseTestCase {
  /// What is asked for is what is listened for, and nothing else is.
  @MainActor
  func test_theLessonKnowsWhatWasDone() {
    func entry(_ from: String, _ to: String) -> ProcessingHistory {
      ProcessingHistory(fileURL: path(from), status: .completed, duration: 0, outputURL: path(to))
    }
    XCTAssertTrue(Lesson.answers(entry("Letter.md", "Letter.pdf"), .kind))
    XCTAssertFalse(Lesson.answers(entry("First light.png", "First light.pdf"), .kind))
    XCTAssertTrue(Lesson.answers(entry("Ember_reverse.wav", "Ember.wav"), .word))
    XCTAssertFalse(Lesson.answers(entry("First light_gray.png", "First light.png"), .word))
    XCTAssertTrue(Lesson.answers(entry("First light.png", "First light.jpg"), .drag))
    XCTAssertFalse(Lesson.answers(entry("Ember_reverse.wav", "Ember.wav"), .drag))
    XCTAssertFalse(Lesson.answers(entry("Letter.md", "Letter.docx"), .drag))
    XCTAssertTrue(Lesson.answers(entry("Recipe_scan.jpg", "Recipe.jpg"), .scan))
    XCTAssertFalse(Lesson.answers(entry("Recipe.jpg", "Recipe.png"), .scan))
    // Said in its name, it was not dragged.
    XCTAssertFalse(Lesson.answers(entry("First light_gray.png", "First light.png"), .drag))
    XCTAssertTrue(Lesson.isIn(path("a"), path("a/b.png")))
    XCTAssertFalse(Lesson.isIn(path("a"), path("b.png")))
  }

  /// Watched while it lasts; never written down.
  @MainActor
  func test_theLessonsFolderIsForgotten() async throws {
    let model = AppModel(persistence: store)
    model.startLesson(in: try folder("Try Forge"))
    XCTAssertEqual(model.folders.map(\.onlyWhenRenamed), [true])
    model.endLesson()
    XCTAssertTrue(model.folders.isEmpty)
  }

  /// The window is opened while it lasts, and gets everything ready again: what
  /// is being watched for the lesson is not swept away with it.
  @MainActor
  func test_gettingReadyTwiceKeepsTheLesson() async throws {
    let model = AppModel(persistence: store)
    await model.bootstrap()
    model.startLesson(in: try folder("Try Forge"))
    await model.bootstrap()
    XCTAssertEqual(model.folders.map(\.onlyWhenRenamed), [true])
    model.endLesson()
    XCTAssertTrue(model.folders.isEmpty)
  }

  /// The window and the lesson both ask at once, the first time there is.
  @MainActor
  func test_gettingReadyAtOnceWritesThePresetsOnce() async throws {
    let model = AppModel(persistence: store)
    async let one: Void = model.bootstrap()
    async let other: Void = model.bootstrap()
    _ = await (one, other)
    let saved = try await store.loadAllPresets().count
    XCTAssertEqual(saved, model.presets.count)
  }

  /// What it is tried on is made there and then, and is what it says it is.
  func test_theSamplesOfTheWelcomeAreRealFiles() throws {
    let files = try WelcomeSamples.make(in: try folder("welcome"))
    XCTAssertEqual(try ProcessableFile(url: files.picture).dimensions?.width, WelcomeSamples.width)
    XCTAssertEqual(WelcomeSamples.seconds(of: files.sound), WelcomeTune.seconds, accuracy: 0.01)
    let shape = WelcomeSamples.shape(of: files.sound, bars: 20)
    XCTAssertEqual(shape.count, 20)
    XCTAssertEqual(shape.max() ?? 0, 1, accuracy: 0.001)
    for sound in WelcomeScore.Sound.allCases {
      let buffer = try XCTUnwrap(WelcomeScore.make(sound))
      let left = try XCTUnwrap(buffer.floatChannelData)[0]
      let peak = (0..<Int(buffer.frameLength)).map { abs(left[$0]) }.max() ?? 0
      XCTAssertGreaterThan(peak, 0.02, "\(sound) is silent")
      XCTAssertLessThan(peak, 0.6, "\(sound) is loud")
    }
  }

  /// What a tile says it can be, the file it stands for really can.
  func test_whatTheTilesBecomeCanBeMade() throws {
    let files = try WelcomeSamples.make(in: try folder("welcome"))
    for (sample, formats) in zip(WelcomeSamples.each, WelcomeSamples.formats()) {
      let before = "\(sample.name).\(sample.from)", was = files.folder.appendingPathComponent(before)
      XCTAssertTrue(FileManager.default.fileExists(atPath: was.path), before)
      XCTAssertGreaterThan(formats.count, 2, before)
      XCTAssertFalse(formats.contains(sample.from), before)
      for format in formats {
        let now = files.folder.appendingPathComponent("\(sample.name).\(format)")
        try FileManager.default.moveItem(at: was, to: now)
        XCTAssertNotNil(Retype.wanted(of: now, before: before), "\(before) to \(format)")
        try FileManager.default.moveItem(at: now, to: was)
      }
    }
  }

  /// The sheet is really found in the photo, and comes out upright.
  func test_theRecipeCanBeScanned() async throws {
    let url = path("Recipe.jpg")
    try WelcomeRecipe.write(to: url)
    let preset = RulePreset(name: "Scan", description: "", category: .image, actions: [.tool(.scan)])
    let entry = try await coordinator().processFile(try ProcessableFile(url: url), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
    let size = try XCTUnwrap(ProcessableFile(url: try XCTUnwrap(entry.outputURL)).dimensions)
    XCTAssertGreaterThan(size.height, size.width)
  }

  /// Each is a word Forge knows, or an extension it makes of that file.
  func test_theNamesAtTheEndMeanSomething() throws {
    let files = try WelcomeSamples.make(in: try folder("welcome"))
    for extra in WelcomeSamples.extras {
      let all = try FileManager.default.contentsOfDirectory(atPath: files.folder.path)
      let old = try XCTUnwrap(all.first { ($0 as NSString).deletingPathExtension == extra.name }, extra.name)
      let was = files.folder.appendingPathComponent(old), now = files.folder.appendingPathComponent(extra.name(from: old))
      guard extra.word.hasPrefix(".") else {
        XCTAssertFalse(NameTokens.read(now.lastPathComponent).tools.isEmpty, extra.word)
        continue
      }
      try FileManager.default.moveItem(at: was, to: now)
      XCTAssertNotNil(Retype.wanted(of: now, before: old), extra.word)
      try FileManager.default.moveItem(at: now, to: was)
    }
  }

  /// What came of one name is given another the moment it is there.
  @MainActor
  func test_aFileIsGivenOneNameAfterAnother() async throws {
    let files = try WelcomeSamples.make(in: try folder("welcome"))
    let model = AppModel(persistence: store)
    await model.bootstrap()
    model.startLesson(in: files.folder)
    defer { model.endLesson() }
    try await Task.sleep(nanoseconds: 1_500_000_000)
    for word in ["gray", "crop1x1", "round90"] {
      let before = model.history.count
      try FileManager.default.moveItem(at: files.picture, to: files.folder.appendingPathComponent("First light_\(word).png"))
      for _ in 0..<100 where model.history.count == before { try await Task.sleep(nanoseconds: 100_000_000) }
      XCTAssertEqual(model.history.count, before + 1, word)
      XCTAssertTrue(exists(files.picture), "\(word): \((try? FileManager.default.contentsOfDirectory(atPath: files.folder.path)) ?? [])")
    }
  }

  func test_historyIsByDay_theLatestFirst() throws {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10))!
    func entry(_ hoursAgo: Double, _ name: String) -> ProcessingHistory {
      ProcessingHistory(fileURL: path(name), timestamp: now.addingTimeInterval(-hoursAgo * 3600), status: .completed, duration: 0)
    }
    let days = HistoryDay.days(of: [entry(26, "c"), entry(1, "a"), entry(2, "b"), entry(24 * 9, "d")], now: now)
    XCTAssertEqual(days.map { $0.entries.map(\.fileURL.lastPathComponent) }, [["a", "b"], ["c"], ["d"]])
    XCTAssertEqual(days.prefix(2).map(\.title), ["Today", "Yesterday"])
    XCTAssertTrue(days[2].title.contains("2026"))
  }

  /// In the library, what is for one kind of file is with its own.
  func test_theToolsAreWithWhatTheyAreFor() {
    XCTAssertEqual(Tool.Kind.layers.libraryGroup, .pictures)
    XCTAssertEqual(Tool.Kind.numbers.libraryGroup, .pages)
    XCTAssertEqual(Tool.Kind.voice.libraryGroup, Tool.Kind.voice.kinds.count == 1 ? .sound : .transform)
    let groups = Set(Tool.Kind.allCases.map(\.libraryGroup))
    XCTAssertGreaterThan(groups.count, 3)
  }

  /// What a preset needs is asked for with it, unless it is here already.
  func test_filmSettingsWantFfmpeg() {
    let preset = RulePreset(name: "x", description: "", category: .video, actions: [.film(FilmSettings())])
    let tool = PresetGallery.toolNeeded(by: preset)
    XCTAssertEqual(tool?.binary, ExternalTools.locate("ffmpeg") == nil ? "ffmpeg" : nil)
    XCTAssertEqual(PresetOffer(isInstalled: false, tool: tool).installTitle, tool == nil ? "Install" : "Install with ffmpeg")
    XCTAssertNil(PresetGallery.toolNeeded(by: RulePreset(name: "y", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])))
  }
}
