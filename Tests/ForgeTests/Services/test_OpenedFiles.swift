import XCTest
@testable import Forge

/// Files handed to Forge from outside - the Dock icon, Open With, `open -a` -
/// can arrive before the window that takes them exists.
@MainActor
final class OpenedFilesTests: XCTestCase {

  func test_filesThatArriveBeforeAnyoneListensAreKept() {
    let inbox = OpenedFiles()
    inbox.receive([URL(fileURLWithPath: "/tmp/a.png")])
    inbox.receive([URL(fileURLWithPath: "/tmp/b.pdf")])

    var delivered: [URL] = []
    inbox.deliver = { delivered += $0 }

    XCTAssertEqual(delivered.map(\.lastPathComponent), ["a.png", "b.pdf"])
  }

  func test_filesAfterThatGoStraightThrough() {
    let inbox = OpenedFiles()
    var delivered: [URL] = []
    inbox.deliver = { delivered += $0 }

    inbox.receive([URL(fileURLWithPath: "/tmp/c.mov")])
    XCTAssertEqual(delivered.map(\.lastPathComponent), ["c.mov"])
  }

  func test_theInfoPlistDeclaresDocumentTypes() throws {
    // Without CFBundleDocumentTypes, macOS never offers Forge in Open With and
    // a drop on the Dock icon bounces off.
    let script = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/build_app.sh"),
      encoding: .utf8
    )
    XCTAssertTrue(script.contains("CFBundleDocumentTypes"))
    XCTAssertTrue(script.contains("<string>Alternate</string>"), "Forge must never become the default app for a file")
  }
}
