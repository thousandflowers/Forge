import XCTest
import ImageIO
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

    let preset = RulePreset(
      name: "Greek", description: "", targetFormat: .plainText,
      category: .image, ocrLanguages: ["el-GR"]
    )

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

    let preset = RulePreset(
      name: "Italian", description: "", targetFormat: .plainText,
      category: .image, ocrLanguages: ["it-IT"]
    )

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

  // MARK: - The languages Vision does not have

  /// Vision speaks BCP-47 and tesseract speaks ISO 639-2. Foundation knows
  /// both, so there is no table here to go stale.
  func test_theLanguageCodesAreTranslatedRatherThanListed() {
    XCTAssertEqual(Tesseract.code(for: "el-GR"), "ell")
    XCTAssertEqual(Tesseract.code(for: "el"), "ell")
    XCTAssertEqual(Tesseract.code(for: "it-IT"), "ita")
    XCTAssertEqual(Tesseract.code(for: "zh-Hans"), "zho")
  }

  /// A language Vision does not recognise goes to tesseract, and tesseract
  /// reads the same page.
  func test_aLanguageVisionLacksIsReadByTesseract() throws {
    try XCTSkipUnless(Tesseract.has("eng"), "tesseract has no English data here")
    // `eng` rather than `en-US`: Vision does not answer to it, so this takes
    // the path a language Vision genuinely lacks would take.
    XCTAssertFalse(TextRecognizer.supports("eng"))

    let page = try Fixture.textImage(at: path("page.png"), text: "Forge legge questo")
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(page as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

    let read = try TextRecognizer.text(in: image, languages: ["eng"])
    XCTAssertTrue(read.contains("Forge"), read)
    XCTAssertTrue(read.contains("questo"), read)
  }

  /// When neither engine has the language, the message names both of them and
  /// the one command that would fix it - rather than only listing Vision's
  /// thirty and leaving it there.
  func test_whenNeitherEngineHasTheLanguageBothAreNamed() throws {
    try XCTSkipIf(Tesseract.has("el-GR"), "this machine has Greek data")
    let page = try Fixture.textImage(at: path("page.png"), text: "Forge")
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(page as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

    XCTAssertThrowsError(try TextRecognizer.text(in: image, languages: ["el-GR"])) { error in
      let said = error.localizedDescription
      XCTAssertTrue(said.contains("tesseract"), said)
      XCTAssertTrue(said.contains("Vision"), said)
    }
  }

  /// A picture with nothing written in it left an empty text file and was
  /// reported as converted. A recording with no speech in it was already a
  /// failure that said so; this is the same case, said the same way.
  func test_aPictureWithNothingWrittenInItIsAFailureThatSaysSo() async throws {
    let source = try Fixture.image(at: path("sky.png"), width: 400, height: 300)
    try await expectNoTextFound(in: source, category: .image)
  }

  func test_aScanWithNothingWrittenInItIsAFailureThatSaysSo() async throws {
    let source = try Fixture.scannedPDF(at: path("blank.pdf"), pages: ["", ""])
    try await expectNoTextFound(in: source, category: .document)
  }

  private func expectNoTextFound(in source: URL, category: PresetCategory) async throws {
    let destination = try folder("out")
    do {
      let entry = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: .plainText, category: category),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      XCTAssertNotEqual(entry.status, .completed, "an empty text file was reported as a conversion")
      XCTAssertTrue(entry.errorMessage?.contains("No text found") == true, entry.errorMessage ?? "no reason given")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("No text found"), error.localizedDescription)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
  }
}
