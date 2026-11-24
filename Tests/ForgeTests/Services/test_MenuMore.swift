import AppKit
import XCTest
@testable import Forge

@MainActor
final class MenuMoreTests: ToolTestCase {
  private func session(_ word: NameTokens.Ask) throws -> AskSession {
    let url = path("a.png")
    try Quarters.image(at: url, width: 2400, height: 1600)
    return AskSession(request: AskRequest(word: word, over: nil), file: try ProcessableFile(url: url), convert: { _, _ in [] })
  }

  func test_theRestIsFolded_untilItIsWanted() throws {
    let session = try session(.everything)
    XCTAssertTrue(session.folds)
    XCTAssertTrue(session.shownQuestions.contains(.format))
    XCTAssertFalse(session.shownQuestions.contains(where: \.isSecondary))
    session.showsMore = true
    XCTAssertTrue(session.shownQuestions.contains(.tool))
    XCTAssertTrue(session.shownQuestions.contains(.privacy))
  }

  func test_oneQuestionIsAskedOutright() throws {
    let session = try session(.width)
    XCTAssertFalse(session.folds)
    XCTAssertEqual(session.shownQuestions, [.width])
  }

  func test_restingOnItOpensIt_andPassingDoesNot() async throws {
    let tiles = DropTiles(dwell: 80_000_000)
    var opened = 0
    tiles.openMore = { opened += 1 }
    tiles.more = CGRect(x: 10, y: 100, width: 80, height: 30)
    tiles.move(to: CGPoint(x: 20, y: 110))
    tiles.move(to: CGPoint(x: 20, y: 10))
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(opened, 0)
    tiles.move(to: CGPoint(x: 20, y: 110))
    tiles.move(to: CGPoint(x: 25, y: 112))
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(opened, 1)
  }

  /// Opened, the top stays where it was: a file is being held over it.
  func test_itOpensDownwards_onTheScreen() async throws {
    try XCTSkipIf(NSScreen.main == nil, "no screen")
    let session = try session(.everything)
    let panel = AskPanel(session: session, tiles: DropTiles()) {}
    panel.appear(takingKeys: false)
    defer { panel.close() }
    let before = panel.frame
    session.showsMore = true
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertGreaterThan(panel.frame.height, before.height + 50)
    XCTAssertEqual(panel.frame.maxY, before.maxY, accuracy: 1)
    let bottom = NSScreen.screens.map(\.visibleFrame.minY).min() ?? 0
    XCTAssertGreaterThanOrEqual(panel.frame.minY, bottom)
  }
}
