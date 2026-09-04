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
final class SimpleDocProcessor: FileProcessor, @unchecked Sendable {
  let name = "Document Processor"

  /// PDF plus whatever the system's document readers accept.
  private let readableTypes: [UTType] = [.pdf]
    + DocumentText.readable.keys
    + [DocumentText.markdown].compactMap { $0 }

  private let ciContext = CIContext(options: [.cacheIntermediates: false])

  func canProcess(_ file: ProcessableFile) -> Bool {
    readableTypes.contains { file.fileType.conforms(to: $0) }
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

    if inputType.conforms(to: .pdf) {
      // A PDF asked for text hands back the text it carries, and reads the
      // pages that carry none. A scan has no text layer at all.
      if outputType.conforms(to: .plainText) {
        return try readText(from: input, operations: operations, to: output, progress: progress)
      }
      return try renderPDF(input, to: output, operations: operations, progress: progress)
    }
    return try await convertText(input, from: inputType, to: outputType, at: output, progress: progress)
  }

  // MARK: - PDF

  /// Rasterise every page. The first lands on `output`; the rest become
  /// siblings numbered after it, because a document converter that silently
  /// drops pages two onwards is not converting the document.
  private func renderPDF(
    _ input: URL,
    to output: URL,
    operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) throws -> ProcessingResult {
    let start = Date()

    guard let pdf = PDFDocument(url: input) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(input.lastPathComponent)")
    }
    guard pdf.pageCount > 0 else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no pages")
    }

    let outputUTI = Self.outputUTI(for: output, operations: operations, fallback: .jpeg)
    guard FormatCatalog.isWritableImage(outputUTI) else {
      throw ProcessingError.unsupportedConversion(from: .pdf, to: outputUTI)
    }

    var written: [URL] = []
    var firstDimensions: (width: Int, height: Int)?

    for index in 0..<pdf.pageCount {
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else { continue }

      let destination = index == 0 ? output : output.numbered(index + 1)
      let dimensions = try render(page, to: destination, as: outputUTI, operations: operations)
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

  private func render(
    _ page: PDFPage,
    to destination: URL,
    as uti: UTType,
    operations: [Operation]
  ) throws -> (width: Int, height: Int) {
    let bounds = page.bounds(for: .mediaBox)
    // 2x the PDF's 72 dpi so text stays readable, but capped: a poster-sized
    // page at 2x is hundreds of megabytes of bitmap.
    let maximumSide: CGFloat = 4096
    let longestSide = max(bounds.width, bounds.height)
    let renderScale = longestSide > 0 ? min(2, maximumSide / longestSide) : 1
    let size = CGSize(width: bounds.width * renderScale, height: bounds.height * renderScale)

    let thumbnail = page.thumbnail(of: size, for: .mediaBox)
    guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot rasterise page")
    }

    // Page images take the same operations as any other image, so a preset that
    // resizes or filters applies here too rather than being quietly ignored.
    var image = CIImage(cgImage: cgImage)
    for operation in operations {
      image = Self.apply(operation, to: image)
    }

    guard let rendered = ciContext.createCGImage(image, from: image.extent) else {
      throw ProcessingError.conversionFailed(reason: "Cannot render page")
    }
    guard let imageDestination = CGImageDestinationCreateWithURL(
      destination as CFURL,
      uti.identifier as CFString,
      1,
      nil
    ) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot write \(uti.preferredFilenameExtension ?? uti.identifier)"
      )
    }

    var options: [CFString: Any] = [:]
    if uti.conforms(to: .jpeg) || uti.conforms(to: .heic) {
      options[kCGImageDestinationLossyCompressionQuality] = Self.quality(from: operations)
    }
    CGImageDestinationAddImage(imageDestination, rendered, options as CFDictionary)

    guard CGImageDestinationFinalize(imageDestination) else {
      throw ProcessingError.conversionFailed(reason: "Cannot write \(destination.lastPathComponent)")
    }
    return (rendered.width, rendered.height)
  }

  // MARK: - Reading a PDF

  /// Text from a PDF: what is embedded, and OCR for the pages without any.
  private func readText(
    from input: URL,
    operations: [Operation],
    to output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) throws -> ProcessingResult {
    let start = Date()

    guard let pdf = PDFDocument(url: input) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(input.lastPathComponent)")
    }
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

      progress(Double(index + 1) / Double(pdf.pageCount) * 0.95)
    }

    // A form feed is the long-standing way to say "page break" in plain text.
    try pages.joined(separator: "\n\u{000C}\n").write(to: output, atomically: true, encoding: .utf8)
    progress(1.0)

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
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    progress(0.2)

    guard DocumentText.canWrite(outputType) else {
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputType)
    }

    let document = try DocumentText.read(input, as: inputType)
    progress(0.7)
    try DocumentText.write(document, to: output, as: outputType)
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }


  // MARK: - Helpers

  private static func outputUTI(for output: URL, operations: [Operation], fallback: UTType) -> UTType {
    let requested = operations.compactMap { operation -> UTType? in
      guard case .convertFormat(let to) = operation else { return nil }
      return to
    }.first
    return requested ?? UTType(filenameExtension: output.pathExtension) ?? fallback
  }


  private static func quality(from operations: [Operation]) -> Float {
    let level = operations.compactMap { operation -> Int? in
      guard case .quality(let level) = operation else { return nil }
      return level
    }.first
    return Float(level ?? 85) / 100.0
  }

  private static func apply(_ operation: Operation, to image: CIImage) -> CIImage {
    switch operation {
    case .convertFormat, .quality, .recognizeText:
      return image
    case .resize(let width, let height, _):
      let target = CGSize(
        width: CGFloat(width ?? Int(image.extent.width)),
        height: CGFloat(height ?? Int(image.extent.height))
      )
      guard target.width > 0, target.height > 0, image.extent.width > 0, image.extent.height > 0 else {
        return image
      }
      let scale = min(target.width / image.extent.width, target.height / image.extent.height)
      return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    case .filter(let type):
      switch type {
      case .grayscale: return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
      case .sepia: return image.applyingFilter("CISepiaTone", parameters: [:])
      case .blur: return image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10.0]).cropped(to: image.extent)
      case .sharpen: return image.applyingFilter("CISharpenLuminance", parameters: [:])
      case .invert: return image.applyingFilter("CIColorInvert", parameters: [:])
      }
    }
  }
}

