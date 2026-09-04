import AppKit
import CoreText
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Reading and writing the text document formats macOS understands.
///
/// AppKit ships readers and writers for HTML, RTF, DOCX and plain text, and
/// Foundation parses Markdown. Nothing here shells out to anything.
enum DocumentText {

  /// Formats that can be read, paired with the reader AppKit uses.
  static let readable: [UTType: NSAttributedString.DocumentType] = {
    let candidates: [(UTType?, NSAttributedString.DocumentType)] = [
      (.plainText, .plain),
      (.html, .html),
      (.rtf, .rtf),
      (UTType("public.rtfd"), .rtfd),
      (UTType("org.oasis-open.opendocument.text"), .officeOpenXML),
      (UTType("org.openxmlformats.wordprocessingml.document"), .officeOpenXML),
    ]
    return candidates.reduce(into: [:]) { result, candidate in
      guard let type = candidate.0 else { return }
      result[type] = candidate.1
    }
  }()

  /// Markdown is read by Foundation rather than AppKit, so it is listed apart.
  static let markdown: UTType? = UTType("net.daringfireball.markdown")

  /// Formats that can be written, paired with the writer.
  ///
  /// Markdown is absent on purpose: Foundation parses it and nothing on the
  /// system writes it back out.
  static let writable: [UTType: NSAttributedString.DocumentType] = {
    let candidates: [(UTType?, NSAttributedString.DocumentType)] = [
      (.plainText, .plain),
      (.html, .html),
      (.rtf, .rtf),
      (UTType("org.openxmlformats.wordprocessingml.document"), .officeOpenXML),
    ]
    return candidates.reduce(into: [:]) { result, candidate in
      guard let type = candidate.0 else { return }
      result[type] = candidate.1
    }
  }()

  static func canRead(_ type: UTType) -> Bool {
    if let markdown, type.conforms(to: markdown) { return true }
    return readable.keys.contains { type.conforms(to: $0) }
  }

  static func canWrite(_ type: UTType) -> Bool {
    // Markdown conforms to plain text, so it would otherwise slip through as
    // writable - and the result would be the rendered words with every mark
    // stripped, in a file called `.md`. Nothing on the system writes Markdown.
    if let markdown, type.conforms(to: markdown) { return false }
    return type.conforms(to: .pdf) || writable.keys.contains { type.conforms(to: $0) }
  }

  // MARK: - Reading

  @MainActor
  static func read(_ url: URL, as type: UTType) throws -> NSAttributedString {
    if let markdown, type.conforms(to: markdown) {
      let source = try String(contentsOf: url, encoding: .utf8)
      let parsed = try AttributedString(
        markdown: source,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
      )
      return NSAttributedString(parsed)
    }

    guard let documentType = readable.first(where: { type.conforms(to: $0.key) })?.value else {
      throw ProcessingError.unreadableFormat(type)
    }
    guard let document = try? NSAttributedString(
      url: url,
      options: [.documentType: documentType],
      documentAttributes: nil
    ) else {
      throw ProcessingError.conversionFailed(reason: "Cannot read \(url.lastPathComponent)")
    }
    return document
  }

  // MARK: - Writing

  @MainActor
  static func write(_ document: NSAttributedString, to output: URL, as type: UTType) throws {
    guard canWrite(type) else {
      throw ProcessingError.unsupportedConversion(from: .plainText, to: type)
    }
    if type.conforms(to: .pdf) {
      return try writePDF(document, to: output)
    }

    guard let documentType = writable.first(where: { type.conforms(to: $0.key) })?.value else {
      throw ProcessingError.unsupportedConversion(from: .plainText, to: type)
    }

    if documentType == .plain {
      try document.string.write(to: output, atomically: true, encoding: .utf8)
      return
    }

    let data = try document.data(
      from: NSRange(location: 0, length: document.length),
      documentAttributes: [.documentType: documentType]
    )
    try data.write(to: output, options: .atomic)
  }

  /// Lay the text out with CoreText and paginate it into a PDF.
  ///
  /// Going through the print system would work too, but it needs a print
  /// dialogue's worth of state for something that is really just typesetting.
  private static func writePDF(_ document: NSAttributedString, to output: URL) throws {
    // US Letter at 72 dpi, with a margin wide enough to read.
    let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    let margin: CGFloat = 54
    let textArea = page.insetBy(dx: margin, dy: margin)

    var mediaBox = page
    guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot create \(output.lastPathComponent)")
    }

    let framesetter = CTFramesetterCreateWithAttributedString(document)
    let path = CGPath(rect: textArea, transform: nil)
    var start = 0
    let length = document.length

    repeat {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(page)

      let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
      CTFrameDraw(frame, context)

      let visible = CTFrameGetVisibleStringRange(frame)
      context.endPDFPage()

      // A page that fits nothing would loop for ever.
      guard visible.length > 0 else { break }
      start += visible.length
    } while start < length

    context.closePDF()
  }
}
