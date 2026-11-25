import AppKit
import XCTest
@testable import Forge

/// A file cut from a menu over the Finder is cut, and the Finder is come back to.
@MainActor
final class ErrandTests: BaseTestCase {
  private var returned = 0

  private func errand(from isElsewhere: Bool) -> Errand {
    returned = 0
    return Errand { isElsewhere ? { self.returned += 1 } : nil }
  }

  func test_itGoesBackWhereItCameFrom_once() {
    let errand = errand(from: true)
    errand.begin()
    errand.end()
    XCTAssertEqual(returned, 1)
    errand.end()
    XCTAssertEqual(returned, 1)
  }

  func test_begunInForge_itStaysInForge() {
    let errand = errand(from: false)
    errand.begin()
    errand.end()
    XCTAssertEqual(returned, 0)
  }

  func test_whoeverGoesToForgeMeanwhile_staysThere() {
    let errand = errand(from: true)
    errand.begin()
    errand.stay()
    errand.end()
    XCTAssertEqual(returned, 0)
  }

  /// Two windows are one errand, over when the last is closed.
  func test_theLastWindowEndsIt() throws {
    let errand = errand(from: true), center = CutCenter(errand: errand)
    let files = try ["a.png", "b.png"].map { try ProcessableFile(url: Fixture.image(at: path($0), width: 400, height: 300)) }
    for file in files { center.open(file) { _, _ in [] } }
    let windows = NSApp.windows.filter { window in files.contains { $0.fileName == window.title } && window.isVisible }
    XCTAssertEqual(windows.count, 2)
    windows[0].close()
    XCTAssertEqual(returned, 0)
    XCTAssertTrue(center.isOpen)
    windows[1].close()
    XCTAssertEqual(returned, 1)
    XCTAssertFalse(center.isOpen)
  }
}
