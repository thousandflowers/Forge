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
    XCTAssertTrue(Lesson.answers(entry("First light_gray.png", "First light.png"), .word))
    XCTAssertFalse(Lesson.answers(entry("Ember_reverse.wav", "Ember.wav"), .word))
    XCTAssertTrue(Lesson.answers(entry("Letter.md", "Letter.pdf"), .kind))
    XCTAssertFalse(Lesson.answers(entry("First light.png", "First light.pdf"), .kind))
    XCTAssertTrue(Lesson.answers(entry("First light_ask.png", "First light.jpg"), .ask))
    XCTAssertTrue(Lesson.answers(entry("Ember_reverse.wav", "Ember.wav"), .sound))
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

  /// What it is tried on is made there and then, and is what it says it is.
  func test_theSamplesOfTheWelcomeAreRealFiles() throws {
    let files = try WelcomeSamples.make(in: try folder("welcome"))
    XCTAssertEqual(try ProcessableFile(url: files.picture).dimensions?.width, WelcomeSamples.width)
    XCTAssertEqual(WelcomeSamples.seconds(of: files.sound), 6, accuracy: 0.01)
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
