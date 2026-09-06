import XCTest
@testable import Forge

final class LibraryTests: XCTestCase {
  func testEveryEntryHasItsOwnIdentityEvenWhenTitlesRepeat() {
    let entries = LibraryEntry.all(for: .image)
    let ids = entries.map(\.id)

    XCTAssertEqual(Set(ids).count, ids.count, "two blocks share an id: \(ids)")
    XCTAssertEqual(entries.filter { $0.title == "Quality" }.count, 2, "Quality is both a question and a step")
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
}
