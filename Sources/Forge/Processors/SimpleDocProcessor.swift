import Foundation
import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PDF and text documents.
///
/// PDFs are rasterised page by page; text documents are converted through
/// AppKit's readers, so an HTML file really does come out as plain text
/// instead of being copied across unchanged.
extension SimpleDocProcessor {
  /// A PDF that wants a password to be read has pages nobody can see yet.
  /// Rendering them gave blank images, reading them gave nothing, and both
  /// were reported as converted - with "move", at the cost of the original.
  static func refuseIfLocked(_ pdf: PDFDocument, named name: String) throws {
    guard pdf.isLocked else { return }
    throw ProcessingError.conversionFailed(
      reason: "\(name) is locked with a password. Open it in Preview, export an unlocked copy, and convert that."
    )
  }
}

final class SimpleDocProcessor: FileProcessor, @unchecked Sendable {
  let name = "Document Processor"

  /// PDF plus whatever the system's document readers accept.
  ///
  /// Shared rather than private because the Convert screen has to offer the
  /// controls this processor honours, and a second hand-written copy of the
  /// list would drift from this one.
  static let readableTypes: [UTType] = {
    var types: [UTType] = [.pdf]
    types.append(contentsOf: Array(DocumentText.readable.keys))
    if let markdown = DocumentText.markdown { types.append(markdown) }
    return types
  }()

  private let images = ImageProcessor()

  func canProcess(_ file: ProcessableFile) -> Bool {
    Self.readableTypes.contains { file.fileType.conforms(to: $0) }
  }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    // Any document can be read aloud, and written as any document format.
    if FormatCatalog.audioFormatID(for: target) != nil { return true }
    if target.conforms(to: .plainText) || DocumentText.canWrite(target) { return true }
    // Plain text is Markdown already; a PDF's words can go to whatever a tool writes.
    if let markdown = DocumentText.markdown, target.conforms(to: markdown) {
      return file.fileType.conforms(to: .plainText) && !file.fileType.conforms(to: markdown)
    }
    if file.fileType.conforms(to: .pdf), ExternalBridge.couldPlan(from: "txt", to: Conversions.fileExtension(of: target)) {
      return true
    }
    // Pictures of the pages: only a PDF has pages to draw.
    return file.fileType.conforms(to: .pdf) && Self.isAPictureFormat(target)
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    guard let inputType = UTType(filenameExtension: input.pathExtension) else {
      throw ProcessingError.unknownType
    }

    let outputType = Self.outputUTI(for: output, operations: operations, fallback: .jpeg)

    // The pages asked for, the way they were asked for, and then whatever it
    // is to become.
    var input = input
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pages-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    if inputType.conforms(to: .pdf), PDFTools.change(operations) {
      if outputType.conforms(to: .pdf), let pdf = PDFDocument(url: input) {
        try PDFTools.refuseIfSigned(pdf, named: input.lastPathComponent)
      }
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      let changed = scratch.appendingPathComponent(input.lastPathComponent)
      try PDFTools.apply(operations, to: input, writing: changed)
      input = changed
    }

    // Text asked for audio is spoken, not converted - a PDF included, which is
    // why this comes before the PDF branch rather than after it.
    if FormatCatalog.audioFormatID(for: outputType) != nil {
      return try await speak(input, from: inputType, to: outputType, at: output, operations: operations, progress: progress)
    }

    if inputType.conforms(to: .pdf) {
      // A PDF asked for text hands back the text it carries, and reads the
      // pages that carry none. A scan has no text layer at all.
      if outputType.conforms(to: .plainText) {
        return try readText(from: input, operations: operations, to: output, progress: progress)
      }
      // Asked to stay a PDF it stays the document it was. Pouring the text into
      // new pages would lose every picture and every layout; a picture of each
      // page, which is what this did, lost every word instead.
      if outputType.conforms(to: .pdf) {
        return try await keepPDF(input, at: output, operations: operations, progress: progress)
      }
      // Asked for another document format, it becomes that document's text.
      if DocumentText.canWrite(outputType) {
        return try await rewritePDF(input, as: outputType, at: output, operations: operations, progress: progress)
      }
      // And for one only a tool writes - an EPUB, an ODT - the tool is given
      // the words. A Word file could become an EPUB and a PDF could not.
      // Pictures are drawn from the pages, never written as text.
      if !Self.isAPictureFormat(outputType), ExternalBridge.couldPlan(from: "txt", to: output.pathExtension.lowercased()) {
        return try handToATool(input, at: output, operations: operations, progress: progress)
      }
      return try await renderPDF(input, to: output, operations: operations, progress: progress)
    }

    return try await convertText(
      input, from: inputType, to: outputType, at: output, operations: operations, progress: progress
    )
  }

  // MARK: - PDF

  /// A PDF that is to stay a PDF: one document in, one document out.
  ///
  /// With nothing in the chain that redraws a page it is the file itself, so
  /// its words can still be found and copied and its links still go somewhere;
  /// who wrote it is taken off afterwards, where the privacy level asks. A
  /// chain that does redraw - a filter, a new size - makes pictures of the
  /// pages, which is what was asked for, and keeps them in one file in the
  /// order they were in.
  private func keepPDF(
    _ input: URL,
    at output: URL,
    operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    guard let pdf = PDFDocument(url: input) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(input.lastPathComponent)")
    }
    try Self.refuseIfLocked(pdf, named: input.lastPathComponent)
    guard pdf.pageCount > 0 else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no pages")
    }

    let redraws = operations.contains { operation in
      switch operation {
      case .resize, .filter: return true
      default: return false
      }
    }
    guard redraws else {
      try Data(contentsOf: input, options: .mappedIfSafe).write(to: output, options: .atomic)
      progress(1.0)
      return try Self.result(output, since: start)
    }

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-pages-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    var pages: [URL] = []
    for index in 0..<pdf.pageCount {
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else { continue }
      let drawn = scratch.appendingPathComponent("\(index).pdf")
      _ = try await render(page, to: drawn, as: .pdf, operations: operations)
      pages.append(drawn)
      progress(Double(index + 1) / Double(pdf.pageCount))
    }
    try Merger.pdf(from: pages, to: output)
    return try Self.result(output, since: start)
  }

  /// The PDF's words, written out and given to whichever tool writes the
  /// format that was asked for.
  private func handToATool(
    _ input: URL,
    at output: URL,
    operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) throws -> ProcessingResult {
    let start = Date()
    let words = try pdfPages(from: input, operations: operations) { progress($0 * 0.6) }
      .joined(separator: Self.paragraphBreak)

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-words-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let written = folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".txt")
    try words.write(to: written, atomically: true, encoding: .utf8)

    guard let plan = ExternalBridge.plan(from: written, to: output, operations: operations) else {
      throw ProcessingError.unsupportedConversion(
        from: .pdf, to: UTType(filenameExtension: output.pathExtension) ?? .data
      )
    }
    do {
      try ExternalTools.run(plan.tool, plan.arguments)
    } catch {
      throw ExternalProcessor.explain(error, about: input)
    }
    progress(1.0)
    return try Self.result(output, since: start)
  }

  /// What a page can be drawn into: what macOS writes, and WebP where cwebp
  /// is installed, as for any other picture.
  private static func isAPictureFormat(_ type: UTType) -> Bool {
    FormatCatalog.isWritableImage(type) || (ImageProcessor.isWebP(type) && ExternalTools.locate("cwebp") != nil)
  }

  /// Rasterise every page. The first lands on `output`; the rest become
  /// siblings numbered after it, because a document converter that silently
  /// drops pages two onwards is not converting the document.
  private func renderPDF(
    _ input: URL,
    to output: URL,
    operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    guard let pdf = PDFDocument(url: input) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(input.lastPathComponent)")
    }
    try Self.refuseIfLocked(pdf, named: input.lastPathComponent)
    guard pdf.pageCount > 0 else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no pages")
    }

    let outputUTI = Self.outputUTI(for: output, operations: operations, fallback: .jpeg)
    guard Self.isAPictureFormat(outputUTI) else {
      throw ProcessingError.unsupportedConversion(from: .pdf, to: outputUTI)
    }

    var written: [URL] = []
    var firstDimensions: (width: Int, height: Int)?

    for index in 0..<pdf.pageCount {
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else { continue }

      let destination = index == 0 ? output : output.numbered(index + 1, of: pdf.pageCount)
      let dimensions = try await render(page, to: destination, as: outputUTI, operations: operations)
      if index == 0 { firstDimensions = dimensions }
      written.append(destination)

      progress(Double(index + 1) / Double(pdf.pageCount))
    }

    guard let primary = written.first else {
      throw ProcessingError.conversionFailed(reason: "No pages could be rendered")
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: primary.path)
    return ProcessingResult(
      outputURL: primary,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: firstDimensions,
      duration: Date().timeIntervalSince(start),
      additionalOutputs: Array(written.dropFirst())
    )
  }

  /// A page as a picture: drawn, and then handed to the picture path like any
  /// other picture. Doing the steps here instead meant a second, poorer copy
  /// of them - a crop was ignored, WebP was refused - and a page that is
  /// turned in the file was drawn into the shape it has before it is turned,
  /// and came out small.
  private func render(
    _ page: PDFPage,
    to destination: URL,
    as uti: UTType,
    operations: [Operation]
  ) async throws -> (width: Int, height: Int) {
    // What is seen of the page, which a crop makes less than there is of it.
    let bounds = page.bounds(for: .cropBox)
    let turned = page.rotation % 180 != 0
    let shown = CGSize(width: turned ? bounds.height : bounds.width, height: turned ? bounds.width : bounds.height)
    // 2x the PDF's 72 dpi so text stays readable, but capped: a poster-sized
    // page at 2x is hundreds of megabytes of bitmap.
    let maximumSide: CGFloat = 4096
    let longestSide = max(shown.width, shown.height)
    let renderScale = longestSide > 0 ? min(2, maximumSide / longestSide) : 1
    let size = CGSize(width: shown.width * renderScale, height: shown.height * renderScale)

    let thumbnail = page.thumbnail(of: size, for: .cropBox)
    guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot rasterise page")
    }

    let drawn = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-page-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: drawn) }
    guard let png = CGImageDestinationCreateWithURL(drawn as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot render page")
    }
    CGImageDestinationAddImage(png, cgImage, nil)
    guard CGImageDestinationFinalize(png) else {
      throw ProcessingError.conversionFailed(reason: "Cannot render page")
    }

    // The format is said outright: the chain may name another (PDF to PDF
    // redraws into PDF pages whatever the preset's own target).
    // And what is done to the page has been done to it.
    let steps = operations.filter { operation in
      switch operation {
      case .convertFormat, .tool: return false
      default: return true
      }
    } + [.convertFormat(to: uti)]
    let result = try await images.process(drawn, to: destination, with: steps) { _ in }
    return result.outputDimensions ?? (cgImage.width, cgImage.height)
  }

  // MARK: - Speaking

  @MainActor
  private func speak(
    _ input: URL,
    from inputType: UTType,
    to outputType: UTType,
    at output: URL,
    operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    // A scanned PDF has no text layer, so it is read the same way as for .txt.
    let text = inputType.conforms(to: .pdf)
      ? try pdfPages(from: input, operations: operations) { progress($0 * 0.3) }
        .joined(separator: Self.paragraphBreak)
      : try DocumentText.read(input, as: inputType).string

    // The recognition language doubles as the speaking one: both answer "which
    // language is this document in".
    let language = operations.compactMap { operation -> String? in
      guard case .recognizeText(let languages) = operation else { return nil }
      return languages.first
    }.first

    try await SpeechSynthesis.write(text, to: output, as: outputType, language: language, progress: progress)
    return try Self.result(output, since: start)
  }

  // MARK: - Reading a PDF

  /// A PDF written out as plain text.
  private func readText(
    from input: URL,
    operations: [Operation],
    to output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) throws -> ProcessingResult {
    let start = Date()
    let text = try pdfPages(from: input, operations: operations) { progress($0 * 0.95) }
      .joined(separator: Self.plainPageBreak)
    try text.write(to: output, atomically: true, encoding: .utf8)
    progress(1.0)
    return try Self.result(output, since: start)
  }

  /// A PDF written out as another document format: its text, since a PDF
  /// carries no paragraphs or styles for the writer to keep.
  @MainActor
  private func rewritePDF(
    _ input: URL,
    as outputType: UTType,
    at output: URL,
    operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    let text = try pdfPages(from: input, operations: operations) { progress($0 * 0.9) }
      .joined(separator: Self.paragraphBreak)
    try DocumentText.write(NSAttributedString(string: text), to: output, as: outputType)
    progress(1.0)
    return try Self.result(output, since: start)
  }

  /// Text from a PDF, page by page: what is embedded, and OCR for the pages
  /// without any.
  private func pdfPages(
    from input: URL,
    operations: [Operation],
    progress: (Double) -> Void
  ) throws -> [String] {
    guard let pdf = PDFDocument(url: input) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(input.lastPathComponent)")
    }
    try Self.refuseIfLocked(pdf, named: input.lastPathComponent)
    guard pdf.pageCount > 0 else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no pages")
    }

    let languages = operations.compactMap { operation -> [String]? in
      guard case .recognizeText(let languages) = operation else { return nil }
      return languages
    }.first ?? []

    var pages: [String] = []
    for index in 0..<pdf.pageCount {
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else { continue }

      let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !embedded.isEmpty {
        pages.append(embedded)
      } else if let image = try? rasterise(page) {
        pages.append(try TextRecognizer.text(in: image, languages: languages))
      }

      progress(Double(index + 1) / Double(pdf.pageCount))
    }
    // Pages with nothing written on them, neither in the file nor to the eye.
    guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
      throw ProcessingError.conversionFailed(reason: "No text found")
    }
    return pages
  }

  /// A form feed is the long-standing way to say "page break" in plain text.
  private static let plainPageBreak = "\n\u{000C}\n"
  /// Rich formats and speech get a paragraph break: a form feed means nothing
  /// to a Word reader and a voice reads it as nothing.
  private static let paragraphBreak = "\n\n"

  private static func result(_ output: URL, since start: Date) throws -> ProcessingResult {
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  /// A page as pixels, for the reader to look at.
  private func rasterise(_ page: PDFPage) throws -> CGImage {
    let bounds = page.bounds(for: .mediaBox)
    // Text recognition wants detail; 2x the PDF's 72 dpi is the usual floor.
    let scale: CGFloat = 2
    let thumbnail = page.thumbnail(
      of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
      for: .mediaBox
    )
    guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot rasterise the page")
    }
    return image
  }

  // MARK: - Text

  /// Read the document, then write it out in the format that was asked for.
  ///
  /// HTML, RTF, DOCX, Markdown and plain text all go through the same pair of
  /// system readers and writers, so any of them converts to any other that can
  /// be written - PDF included.
  @MainActor
  private func convertText(
    _ input: URL,
    from inputType: UTType,
    to outputType: UTType,
    at output: URL,
    operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    progress(0.2)

    // Plain text is Markdown already: nothing has to write it, only to say so.
    // It was refused, since nothing on the system writes Markdown.
    if let markdown = DocumentText.markdown, outputType.conforms(to: markdown),
       inputType.conforms(to: .plainText), !inputType.conforms(to: markdown) {
      try DocumentText.text(in: input).write(to: output, atomically: true, encoding: .utf8)
      progress(1.0)
      return try Self.result(output, since: start)
    }

    guard DocumentText.canWrite(outputType) else {
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputType)
    }

    // The system's reader keeps the words and loses the rest of a document:
    // its links, its footnotes, its pictures, often its tables. pandoc keeps
    // them, so where it is installed and can do the pair it is asked instead.
    // Not into a PDF, which pandoc writes only through LaTeX; and not where
    // the author is to be removed, which the system's path does and pandoc's
    // does not.
    let source = input.pathExtension.lowercased()
    let target = output.pathExtension.lowercased()
    if !outputType.conforms(to: .pdf), PrivacyFilter.policy(in: operations) != .stripAll,
       ExternalBridge.couldPlan(from: source, to: target) {
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputType)
    }

    let document = try DocumentText.read(input, as: inputType)
    let details = DocumentText.details(of: input, as: inputType, keeping: PrivacyFilter.policy(in: operations))
    progress(0.7)
    try DocumentText.write(document, to: output, as: outputType, details: details)
    progress(1.0)
    return try Self.result(output, since: start)
  }


  // MARK: - Helpers

  private static func outputUTI(for output: URL, operations: [Operation], fallback: UTType) -> UTType {
    let requested = operations.compactMap { operation -> UTType? in
      guard case .convertFormat(let to) = operation else { return nil }
      return to
    }.first
    return requested ?? UTType(filenameExtension: output.pathExtension) ?? fallback
  }
}

