import XCTest
import PDFKit
import UniformTypeIdentifiers
@testable import Forge

/// Text documents, converted through the system's own readers and writers.
final class DocumentConversionTests: BaseTestCase {

  private func convert(_ source: URL, to format: UTType) async throws -> URL {
    let destination = try folder("out-\(format.preferredFilenameExtension ?? "x")")
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: format, category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    return try XCTUnwrap(entry.outputURL)
  }

  private func html(at name: String, body: String) throws -> URL {
    let url = path(name)
    try "<html><body>\(body)</body></html>".write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func test_htmlBecomesPDF() async throws {
    let source = try html(at: "page.html", body: "<h1>Forge</h1><p>Converts files.</p>")
    let output = try await convert(source, to: .pdf)

    let pdf = try XCTUnwrap(PDFDocument(url: output))
    XCTAssertGreaterThan(pdf.pageCount, 0)
    let text = pdf.string ?? ""
    XCTAssertTrue(text.contains("Forge"), "got: \(text)")
    XCTAssertTrue(text.contains("Converts"), "got: \(text)")
  }

  func test_htmlBecomesRTF() async throws {
    let source = try html(at: "page.html", body: "<p>Hello from Forge</p>")
    let output = try await convert(source, to: .rtf)

    let rtf = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    XCTAssertTrue(rtf.string.contains("Hello from Forge"), "got: \(rtf.string)")
  }

  func test_htmlBecomesDOCX() async throws {
    let docx = try XCTUnwrap(UTType("org.openxmlformats.wordprocessingml.document"))
    let source = try html(at: "page.html", body: "<p>Written by Forge</p>")
    let output = try await convert(source, to: docx)

    XCTAssertGreaterThan(size(of: output), 0)
    let read = try NSAttributedString(
      url: output,
      options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
      documentAttributes: nil
    )
    XCTAssertTrue(read.string.contains("Written by Forge"), "got: \(read.string)")
  }

  /// Markdown is read by Foundation. Nothing on the system writes it back out,
  /// which is why it is an input only.
  func test_markdownBecomesPDF() async throws {
    let source = path("notes.md")
    try "# Heading\n\nSome **bold** text from Forge.".write(to: source, atomically: true, encoding: .utf8)

    let output = try await convert(source, to: .pdf)
    let text = try XCTUnwrap(PDFDocument(url: output)).string ?? ""
    XCTAssertTrue(text.contains("Forge"), "got: \(text)")
  }

  func test_markdownIsNotOfferedAsAnOutput() throws {
    let markdown = try XCTUnwrap(DocumentText.markdown)
    XCTAssertTrue(DocumentText.canRead(markdown))
    XCTAssertFalse(DocumentText.canWrite(markdown), "nothing on the system writes Markdown")
  }

  /// A long document has to paginate rather than losing everything past the
  /// first page.
  func test_aLongDocumentPaginates() async throws {
    let paragraphs = (1...120).map { "<p>Paragraph number \($0), with enough words in it to take up a line.</p>" }
    let source = try html(at: "long.html", body: paragraphs.joined())

    let output = try await convert(source, to: .pdf)
    let pdf = try XCTUnwrap(PDFDocument(url: output))
    XCTAssertGreaterThan(pdf.pageCount, 1, "everything landed on one page")
    XCTAssertTrue((pdf.string ?? "").contains("Paragraph number 120"), "the end was lost")
  }

  /// A PDF with a text layer, written the way any other document becomes one.
  @MainActor private func textPDF(_ text: String) throws -> URL {
    let url = path("letter.pdf")
    try DocumentText.write(NSAttributedString(string: text), to: url, as: .pdf)
    return url
  }

  /// The sheet offers a PDF every document format. It used to hand them all
  /// to the page rasteriser, which refused anything that was not an image.
  func test_pdfBecomesRTF() async throws {
    let output = try await convert(try await textPDF("Forge reads the letter"), to: .rtf)
    let rtf = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    XCTAssertTrue(rtf.string.contains("Forge reads the letter"), "got: \(rtf.string)")
  }

  func test_pdfBecomesDOCX() async throws {
    let docx = try XCTUnwrap(UTType("org.openxmlformats.wordprocessingml.document"))
    let output = try await convert(try await textPDF("Forge writes Word"), to: docx)
    let read = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
    XCTAssertTrue(read.string.contains("Forge writes Word"), "got: \(read.string)")
  }

  func test_pdfBecomesHTML() async throws {
    let output = try await convert(try await textPDF("Forge on the web"), to: .html)
    XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("Forge on the web"))
  }

  /// PDF to PDF stays a page-for-page render, not the text poured into new pages.
  func test_pdfToPDFStillRendersPages() async throws {
    let source = try Fixture.pdf(at: path("three.pdf"), pages: 3)
    let output = try await convert(source, to: .pdf)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func test_plainTextRoundTrip() async throws {
    let source = path("notes.txt")
    try "Forge keeps plain text plain.".write(to: source, atomically: true, encoding: .utf8)

    let output = try await convert(source, to: .plainText)
    let text = try String(contentsOf: output, encoding: .utf8)
    XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "Forge keeps plain text plain.")
  }
}
