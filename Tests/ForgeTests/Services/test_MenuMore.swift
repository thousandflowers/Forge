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

  /// Dropped on, it closes on where the file is, a little at a time, and stays
  /// that size from the progress to the result.
  func test_itClosesOnWhereTheFileWasLetGo() async throws {
    try XCTSkipIf(NSScreen.main == nil, "no screen")
    let url = path("a.png")
    try Quarters.image(at: url, width: 2400, height: 1600)
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: try ProcessableFile(url: url), convert: { file, _ in
      try await Task.sleep(nanoseconds: 700_000_000)
      return [file.url]
    })
    let tiles = DropTiles()
    tiles.isLive = true
    let panel = AskPanel(session: session, tiles: tiles) {}
    panel.appear(takingKeys: false)
    defer { panel.close() }
    try await Task.sleep(nanoseconds: 900_000_000)
    let before = panel.frame, jpeg = DropTiles.Tile(question: .format, answer: .format(.jpeg)), place = try XCTUnwrap(tiles.frames[jpeg])
    let y = before.maxY - place.midY
    session.choose(jpeg.answer, for: jpeg.question)
    session.start()
    tiles.isLive = false
    panel.gather(at: NSPoint(x: before.midX, y: y))
    var frames: [NSRect] = [before]
    // Looked at late, it has moved further in between: what counts is that no
    // prompt look found it half the way on.
    var late: Set<Int> = [], seen = Date()
    for _ in 0..<110 {
      try await Task.sleep(nanoseconds: 12_000_000)
      let wait = Date().timeIntervalSince(seen)
      seen = Date()
      guard panel.frame != frames.last else { continue }
      frames.append(panel.frame)
      if wait > 0.03 { late.insert(frames.count - 1) }
    }
    XCTAssertGreaterThan(frames.count, 5, "\(frames.map(\.height))")
    XCTAssertEqual(frames.map(\.height), frames.map(\.height).sorted(by: >), "it only grows small")
    XCTAssertEqual(try XCTUnwrap(frames.last).height, AskView.restingHeight, accuracy: 1)
    XCTAssertEqual(try XCTUnwrap(frames.last).midY, y, accuracy: 2)
    let steps = (1..<frames.count).filter { !late.contains($0) }.map { frames[$0 - 1].height - frames[$0].height }
    XCTAssertLessThan(try XCTUnwrap(steps.max()), (before.height - AskView.restingHeight) / 2)
    if case .done = session.state {} else { XCTFail("\(session.state)") }
  }

  func test_itNeverGathersOffTheScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1470, height: 890), frame = NSRect(x: 100, y: 40, width: 400, height: 360)
    for y in stride(from: 0.0, through: 890, by: 20) {
      let top = AskPanel.top(around: y, in: screen, from: frame)
      XCTAssertGreaterThanOrEqual(top - AskView.restingHeight, 0)
      XCTAssertLessThanOrEqual(top, frame.maxY)
    }
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
