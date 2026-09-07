import Foundation
import XCTest
@testable import Forge

final class InputFormatsTests: XCTestCase {
  private func preset(_ category: PresetCategory, formats: [String]? = nil) -> RulePreset {
    var preset = RulePreset(name: "p", description: "", category: category, actions: [.quality(level: 80)])
    preset.inputFormats = formats
    return preset
  }

  func testCustomPresetWithNamedFormatsTakesOnlyThose() {
    let webp = preset(.custom, formats: ["webp", "avif"])

    XCTAssertTrue(webp.accepts(URL(fileURLWithPath: "/tmp/a.WEBP")))
    XCTAssertFalse(webp.accepts(URL(fileURLWithPath: "/tmp/a.jpg")))
  }

  func testCustomPresetWithNoFormatsTakesAnything() {
    let any = preset(.custom)

    XCTAssertTrue(any.accepts(URL(fileURLWithPath: "/tmp/a.jpg")))
    XCTAssertTrue(any.accepts(URL(fileURLWithPath: "/tmp/a.csv")))
  }

  func testCategoryPresetTakesItsOwnKind() {
    let images = preset(.image)

    XCTAssertTrue(images.accepts(URL(fileURLWithPath: "/tmp/a.png")))
    XCTAssertFalse(images.accepts(URL(fileURLWithPath: "/tmp/a.mp3")))
  }

  func testDocumentPresetsStillTakeDataModelsSubtitlesAndFonts() {
    let documents = preset(.document)

    XCTAssertTrue(documents.accepts(URL(fileURLWithPath: "/tmp/table.csv")), "a CSV sat on the Documents shelf before it had its own")
    XCTAssertTrue(documents.accepts(URL(fileURLWithPath: "/tmp/subs.srt")))
    XCTAssertTrue(documents.accepts(URL(fileURLWithPath: "/tmp/page.pdf")))
    XCTAssertFalse(documents.accepts(URL(fileURLWithPath: "/tmp/photo.png")))
    XCTAssertTrue(preset(.data).accepts(URL(fileURLWithPath: "/tmp/table.csv")))
    XCTAssertFalse(preset(.data).accepts(URL(fileURLWithPath: "/tmp/page.pdf")))
  }

  func testInputFormatsRoundTripThroughJSON() throws {
    let saved = preset(.custom, formats: ["srt", "vtt"])

    let back = try JSONDecoder().decode(RulePreset.self, from: JSONEncoder().encode(saved))

    XCTAssertEqual(back.inputFormats, ["srt", "vtt"])
    XCTAssertEqual(back.category, .custom)
  }

  func testCatalogListsEveryKindForgeReads() {
    let kinds = Set(InputFormats.groups.map(\.kind))

    XCTAssertTrue(kinds.isSuperset(of: [.image, .video, .audio, .document, .data, .subtitle]))
    XCTAssertTrue(InputFormats.groups.allSatisfy { !$0.extensions.isEmpty })
    XCTAssertTrue(InputFormats.groups.first { $0.kind == .image }!.extensions.contains("png"))
  }
}
