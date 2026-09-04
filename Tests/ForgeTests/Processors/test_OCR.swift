import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// Reading text out of pictures, on device.
final class TextRecognitionTests: BaseTestCase {

  func test_readsTextFromAnImage() async throws {
    let source = try Fixture.textImage(at: path("sign.png"), text: "FORGE CONVERTS FILES")
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .plainText, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let text = try String(contentsOf: try XCTUnwrap(entry.outputURL), encoding: .utf8)
    XCTAssertTrue(text.uppercased().contains("FORGE"), "got: \(text)")
    XCTAssertTrue(text.uppercased().contains("FILES"), "got: \(text)")
  }

  /// A scan carries no text layer, so this is the reader doing the work.
  func test_readsAScannedPDF() async throws {
    let source = try Fixture.scannedPDF(at: path("scan.pdf"), pages: ["INVOICE TOTAL", "THANK YOU"])
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .plainText, category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let text = try String(contentsOf: try XCTUnwrap(entry.outputURL), encoding: .utf8).uppercased()
    XCTAssertTrue(text.contains("INVOICE"), "got: \(text)")
    XCTAssertTrue(text.contains("THANK"), "second page missing, got: \(text)")
  }

  /// Vision knows a fixed set of languages. Asking for one it does not have has
  /// to say so, rather than quietly returning nothing.
  func test_anUnknownLanguageIsRefusedClearly() async throws {
    let source = try Fixture.textImage(at: path("sign.png"), text: "HELLO")
    let destination = try folder("out")

    var preset = RulePreset.make(format: .plainText, category: .image)
    preset.ocrLanguages = ["el-GR"]

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: preset,
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      XCTFail("Greek is not one of Vision's languages")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("el-GR"), error.localizedDescription)
    }
  }

  func test_aKnownLanguageIsAccepted() async throws {
    let source = try Fixture.textImage(at: path("sign.png"), text: "BUONGIORNO")
    let destination = try folder("out")

    var preset = RulePreset.make(format: .plainText, category: .image)
    preset.ocrLanguages = ["it-IT"]

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
  }

  func test_theSupportedLanguagesAreReported() {
    XCTAssertFalse(TextRecognizer.supportedLanguages.isEmpty)
    XCTAssertTrue(TextRecognizer.supports("it-IT"))
    XCTAssertTrue(TextRecognizer.supports("en"))
    XCTAssertFalse(TextRecognizer.supports("el-GR"), "Vision has no Greek; saying otherwise would be a lie")
  }
}
