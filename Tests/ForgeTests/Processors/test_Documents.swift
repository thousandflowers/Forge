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

  /// Three pages of words, with an author, the way a contract arrives.
  @MainActor private func contract() throws -> URL {
    let document = PDFDocument()
    for (index, words) in ["Forge keeps the words", "on every page", "of the contract"].enumerated() {
      let page = path("page-\(index).pdf")
      try DocumentText.write(NSAttributedString(string: words), to: page, as: .pdf)
      document.insert(try XCTUnwrap(PDFDocument(url: page)?.page(at: 0)), at: index)
    }
    document.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Mario Rossi"]
    let url = path("contract.pdf")
    XCTAssertTrue(document.write(to: url))
    return url
  }

  private func files(beside url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
  }

  /// PDF to PDF was a picture of every page, one file per page: the words
  /// could no longer be found or copied, and a three-page contract came back
  /// as three files. With nothing that redraws a page, it is the same document.
  func test_pdfToPDFKeepsTheDocument() async throws {
    let output = try await convert(try await contract(), to: .pdf)

    XCTAssertEqual(try files(beside: output), ["contract.pdf"], "one document in, one document out")
    let written = try XCTUnwrap(PDFDocument(url: output))
    XCTAssertEqual(written.pageCount, 3)
    let words = written.string ?? ""
    for expected in ["Forge keeps the words", "on every page", "of the contract"] {
      XCTAssertTrue(words.contains(expected), "lost “\(expected)”; has: \(words)")
    }
  }

  /// The use the README shows: the same contract, without who wrote it.
  func test_pdfToPDFWithoutItsAuthorStillHasItsWords() async throws {
    var preset = RulePreset.make(format: .pdf, category: .document)
    preset.actions.append(.stripMetadata(policy: .stripAll))
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: try await contract()), with: preset,
      destinationMode: .copyTo, destinationURL: try folder("anonymous")
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")

    let written = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(entry.outputURL)))
    XCTAssertEqual(written.pageCount, 3)
    XCTAssertTrue(written.string?.contains("of the contract") == true)
    XCTAssertNil(written.documentAttributes?[PDFDocumentAttribute.authorAttribute], "who wrote it is gone")
  }

  /// Asked to redraw the pages - in grey, or smaller - they are pictures of
  /// pages, and still one document in the order they were in.
  func test_pdfRedrawnIsStillOneDocument() async throws {
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: try await contract()),
      with: .make(format: .pdf, filters: [.grayscale], category: .document),
      destinationMode: .copyTo, destinationURL: try folder("grey")
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")

    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(try files(beside: output), ["contract.pdf"])
    XCTAssertEqual(PDFDocument(url: output)?.pageCount, 3)
  }

  func test_plainTextRoundTrip() async throws {
    let source = path("notes.txt")
    try "Forge keeps plain text plain.".write(to: source, atomically: true, encoding: .utf8)

    let output = try await convert(source, to: .plainText)
    let text = try String(contentsOf: output, encoding: .utf8)
    XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "Forge keeps plain text plain.")
  }
}
