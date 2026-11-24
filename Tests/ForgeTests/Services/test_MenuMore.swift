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
    XCTAssertTrue(tiles.isResting)
    tiles.move(to: CGPoint(x: 20, y: 10))
    XCTAssertFalse(tiles.isResting)
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(opened, 0)
    tiles.move(to: CGPoint(x: 20, y: 110))
    tiles.move(to: CGPoint(x: 25, y: 112))
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(opened, 1)
  }

  /// It used to come open all at once, under a file being held.
  func test_itOpensByDegrees() async throws {
    try XCTSkipIf(NSScreen.main == nil, "no screen")
    let session = try session(.everything)
    let panel = AskPanel(session: session, tiles: DropTiles()) {}
    panel.appear(takingKeys: false)
    defer { panel.close() }
    try await Task.sleep(nanoseconds: 400_000_000)
    var heights = [panel.frame.height]
    session.showsMore = true
    for _ in 0..<40 {
      try await Task.sleep(nanoseconds: 16_000_000)
      if panel.frame.height != heights.last { heights.append(panel.frame.height) }
    }
    XCTAssertGreaterThan(heights.count, 5, "\(heights)")
    let total = try XCTUnwrap(heights.max()) - heights[0]
    XCTAssertGreaterThan(total, 50)
    XCTAssertEqual(heights, heights.sorted(), "never back")
    XCTAssertLessThan(zip(heights, heights.dropFirst()).map { $1 - $0 }.max() ?? 0, total / 2, "\(heights)")
  }

  func test_oneSectionAfterAnother() {
    XCTAssertEqual(Unfold.progress(after: 0, step: 0), 0)
    XCTAssertEqual(Unfold.progress(after: Unfold.length(of: 3), step: 2), 1)
    let early = (0..<3).map { Unfold.progress(after: 0.15, step: $0) }
    XCTAssertGreaterThan(early[0], early[1])
    XCTAssertGreaterThan(early[1], early[2])
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
