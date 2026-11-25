import XCTest
import UniformTypeIdentifiers
@testable import Forge

final class PremiumTests: BaseTestCase {
  /// The welcome must not teach a word that does nothing.
  func test_theWordsOfTheWelcomeAreWords() {
    for word in WelcomeName.words { XCTAssertNotNil(Tool(word: word), word) }
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
