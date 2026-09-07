import Foundation
import XCTest
@testable import Forge

final class NameTokensMoreTests: XCTestCase {
  func testWidthAndQualityCanBeSaidInTheName() {
    let read = NameTokens.read("holiday_1920px_q80.jpg")

    XCTAssertEqual(read.width, 1920)
    XCTAssertEqual(read.quality, 80)
    XCTAssertNil(read.ceiling)
  }

  func testNameTokensReplaceTheChainsOwnResizeAndQuality() {
    let chain: [Forge.Operation] = [.resize(width: 800, height: nil, fitMode: .proportional), .quality(level: 50)]

    let applied = NameTokens.applying(to: chain, from: "shot_1280px_q90.png")

    XCTAssertTrue(applied.contains(.resize(width: 1280, height: nil, fitMode: .proportional)))
    XCTAssertTrue(applied.contains(.quality(level: 90)))
    XCTAssertFalse(applied.contains(.quality(level: 50)))
  }

  func testAWordThatOnlyLooksLikeATokenIsLeftAlone() {
    XCTAssertNil(NameTokens.read("quiz_q.jpg").quality)
    XCTAssertNil(NameTokens.read("px_notes.jpg").width)
    XCTAssertNil(NameTokens.read("report_q3.pdf").quality, "a quarter is not a quality")
    XCTAssertEqual(NameTokens.read("report_q30.pdf").quality, 30)
  }

  func testParameterSavedWithoutSourceIsAskedEachTime() throws {
    let json = #"{"key":"maxsize","label":"Maximum size","kind":"maxFileSize","defaultValue":10}"#

    let parameter = try JSONDecoder().decode(PresetParameter.self, from: Data(json.utf8))

    XCTAssertEqual(parameter.source, .prompt)
    XCTAssertEqual(parameter.defaultValue, 10)
  }

  func testParameterSourceRoundTrips() throws {
    let parameter = PresetParameter(key: "w", label: "Width", kind: .width, source: .fileName)

    let back = try JSONDecoder().decode(PresetParameter.self, from: JSONEncoder().encode(parameter))

    XCTAssertEqual(back.source, .fileName)
    XCTAssertEqual(back.nameExample, "holiday_1920px.jpg")
  }
}
