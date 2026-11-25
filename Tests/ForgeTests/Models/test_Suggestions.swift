import XCTest
import UniformTypeIdentifiers
@testable import Forge

final class SuggestionsTests: BaseTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func preset(_ name: String, _ category: PresetCategory = .image) -> RulePreset {
    RulePreset(name: name, description: "", category: category, actions: [.quality(level: 80)])
  }
  private func used(_ preset: RulePreset, on file: String, daysAgo: Double, _ status: ProcessingStatus = .completed) -> ProcessingHistory {
    ProcessingHistory(fileURL: URL(fileURLWithPath: "/tmp/\(file)"), ruleId: preset.id, timestamp: now.addingTimeInterval(-daysAgo * 86_400), status: status, duration: 1)
  }
  private func names(_ presets: [RulePreset], _ history: [ProcessingHistory] = [], chosen: [UUID] = []) throws -> [String] {
    let url = try Fixture.image(at: path("a.png"))
    return Suggestions.presets(for: [try ProcessableFile(url: url)], from: presets, chosen: chosen, history: history, now: now).map(\.name)
  }

  func test_withNothingLearnt_theUsersOrder_andTheKindsOwnFirst() throws {
    XCTAssertEqual(try names([preset("Any", .custom), preset("A"), preset("B")]), ["A", "B", "Any"])
  }

  func test_whatIsUsedOnFilesLikeIt() throws {
    let a = preset("A"), b = preset("B"), c = preset("C")
    XCTAssertEqual(try names([a, b, c], [used(c, on: "x.png", daysAgo: 1), used(b, on: "x.jpg", daysAgo: 1)]), ["C", "B", "A"], "the same format, then the same kind")
    XCTAssertEqual(try names([a, b, c], [used(c, on: "x.mp4", daysAgo: 1)]), ["A", "B", "C"], "what is done to films says nothing of pictures")
  }

  func test_recentBeatsOld() throws {
    let a = preset("A"), b = preset("B")
    let history = [used(a, on: "x.png", daysAgo: 90), used(a, on: "x.png", daysAgo: 91), used(a, on: "x.png", daysAgo: 92), used(b, on: "x.png", daysAgo: 1)]
    XCTAssertEqual(try names([a, b], history), ["B", "A"])
  }

  func test_aBigBatchIsOneVote() throws {
    let a = preset("A"), b = preset("B")
    let batch = (0..<200).map { used(a, on: "x\($0).png", daysAgo: 3) }
    XCTAssertEqual(try names([a, b], batch + [used(b, on: "x.png", daysAgo: 3), used(b, on: "x.png", daysAgo: 5)]), ["B", "A"])
  }

  func test_whatFailedOrWasUndoneIsNotLiked() throws {
    let a = preset("A"), b = preset("B")
    var undone = used(b, on: "x.png", daysAgo: 1)
    undone.undoneAt = now
    XCTAssertEqual(try names([a, b], [undone, used(b, on: "x.png", daysAgo: 2, .failed)]), ["A", "B"])
  }

  func test_chosenOnesAreTheOnes_whereTheySuit() throws {
    let a = preset("A"), b = preset("B"), film = preset("Film", .video)
    XCTAssertEqual(try names([a, b, film], [used(a, on: "x.png", daysAgo: 1)], chosen: [film.id, b.id]), ["B"])
  }

  func test_offAndUnsuitableAreLeftOut_andThereIsALimit() throws {
    var off = preset("Off")
    off.isEnabled = false
    XCTAssertEqual(try names([off, preset("Film", .video)] + (0..<9).map { preset("P\($0)") }).count, Suggestions.most)
    XCTAssertFalse(try names([off, preset("A")]).contains("Off"))
  }

  func test_settings() throws {
    var settings = AppSettings()
    settings.menuPresets = [UUID()]
    XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
  }
}

@MainActor
final class ForYouMenuTests: ToolTestCase {
  func test_inTheMenu() async throws {
    let url = path("a.png")
    try Quarters.image(at: url)
    let web = RulePreset(name: "Web", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])
    var ran: RulePreset?
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: try ProcessableFile(url: url), convert: { _, preset in ran = preset; return [] })
    XCTAssertFalse(session.questions.contains(.forYou))
    session.suggest = { _ in [web] }
    XCTAssertEqual(session.questions.first, .forYou)
    XCTAssertEqual(session.choices(for: .forYou).map(\.label), ["Make lighter", "Web"])
    session.choose(.format(.heic), for: .format)
    session.choose(.preset(web), for: .forYou)
    XCTAssertEqual(session.answers.count, 1, "a preset is the whole recipe")
    await session.run()
    XCTAssertEqual(ran?.id, web.id, "or it would not be remembered")
    XCTAssertEqual(ran?.actions, web.actions)
  }

  func test_lighter() {
    let made = AskRequest(word: .everything, over: nil).answered(with: [.forYou: .tool(.lighter)])
    XCTAssertEqual(made.actions, [.tool(.lighter)])
  }
}
