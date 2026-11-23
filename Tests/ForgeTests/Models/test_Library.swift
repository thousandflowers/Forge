import XCTest
@testable import Forge

final class LibraryTests: XCTestCase {
  func testEveryEntryHasItsOwnIdentityAndItsOwnName() {
    let entries = LibraryEntry.all(for: .image)
    let ids = entries.map(\.id)

    XCTAssertEqual(Set(ids).count, ids.count, "two blocks share an id: \(ids)")
    // A question and a step used to share the name Quality.
    let titles = entries.map(\.title)
    XCTAssertEqual(Set(titles).count, titles.count, "two blocks share a name: \(titles)")
  }

  func testLibraryOnlyOffersStepsThatSuitTheKind() {
    let audio = LibraryEntry.all(for: .audio).map(\.title)
    let image = LibraryEntry.all(for: .image).map(\.title)

    XCTAssertFalse(audio.contains("Crop"))
    XCTAssertTrue(audio.contains("Codec"))
    XCTAssertTrue(image.contains("Crop"))
    XCTAssertTrue(image.contains("Comes out as"))
    XCTAssertTrue(image.contains("Names files"))
  }

  func testQuestionsAreNamedForWhatTheyAskAndStepsForWhatTheyDo() {
    let image = LibraryEntry.all(for: .image)
    XCTAssertEqual(
      image.filter { $0.group == .ask }.map(\.title),
      ["Ask for max file size", "Ask for width", "Ask for quality"]
    )
    XCTAssertEqual(LibraryEntry.Group.ask.rawValue, "Asks each time")
    for step in ["Quality", "Resize", "Max file size"] {
      XCTAssertTrue(image.contains { $0.title == step && $0.group != .ask }, step)
    }
  }

  /// A block is called the same in the library and on the canvas.
  func testAStepKeepsItsLibraryNameOnceItIsOnTheCanvas() {
    for kind in ActionKind.allCases where kind.libraryGroup != .logic {
      XCTAssertEqual(Action(kind.blank(for: .image)).title, kind.title)
    }
  }
}
