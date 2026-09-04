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

  /// Input types, taken from the readers that actually exist: PDFKit for PDF,
  /// AppKit's document readers for the rest.
  let supportedTypes: [UTType] = {
    let text = NSAttributedString.textDocumentTypes.keys.sorted { $0.identifier < $1.identifier }
    return [.pdf] + text
  }()

  private let ciContext = CIContext(options: [.cacheIntermediates: false])

  func canProcess(_ file: ProcessableFile) -> Bool {
    supportedTypes.contains { file.fileType.conforms(to: $0) }
  }

  func supportedOutputTypes(for input: UTType) -> [UTType] {
    if input.conforms(to: .pdf) {
      return FormatCatalog.writableImageTypes.sorted { $0.identifier < $1.identifier }
    }
    return [.plainText]
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

    if inputType.conforms(to: .pdf) {
      return try renderPDF(input, to: output, operations: operations, progress: progress)
    }
    return try await convertText(input, from: inputType, to: output, progress: progress)
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
      throw ProcessingError.unsupportedFormat(outputUTI)
    }

    var written: [URL] = []
    var firstDimensions: (width: Int, height: Int)?

    for index in 0..<pdf.pageCount {
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else { continue }

      let destination = index == 0 ? output : Self.pageURL(output, page: index + 1)
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
    // 2x the PDF's 72 dpi, so text stays readable instead of soft.
    let renderScale: CGFloat = 2
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

  // MARK: - Text

  /// Read the document with AppKit and write out its plain text. HTML and RTF
  /// used to be copied byte for byte, so "convert to text" returned markup.
  @MainActor
  private func convertText(
    _ input: URL,
    from inputType: UTType,
    to output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    progress(0.2)

    let text: String
    if inputType.conforms(to: .plainText) {
      text = try String(contentsOf: input, encoding: .utf8)
    } else {
      guard let attributed = try? NSAttributedString(
        url: input,
        options: [.documentType: Self.documentType(for: inputType)],
        documentAttributes: nil
      ) else {
        throw ProcessingError.conversionFailed(reason: "Cannot read \(input.lastPathComponent)")
      }
      text = attributed.string
    }

    progress(0.8)
    try text.write(to: output, atomically: true, encoding: .utf8)
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  private static func documentType(for type: UTType) -> NSAttributedString.DocumentType {
    NSAttributedString.textDocumentTypes.first { type.conforms(to: $0.key) }?.value ?? .plain
  }

  // MARK: - Helpers

  private static func outputUTI(for output: URL, operations: [Operation], fallback: UTType) -> UTType {
    let requested = operations.compactMap { operation -> UTType? in
      guard case .convertFormat(let to) = operation else { return nil }
      return to
    }.first
    return requested ?? UTType(filenameExtension: output.pathExtension) ?? fallback
  }

  private static func pageURL(_ output: URL, page: Int) -> URL {
    let base = output.deletingPathExtension().lastPathComponent
    let ext = output.pathExtension
    let name = String(format: "%@-%03d", base, page)
    return output
      .deletingLastPathComponent()
      .appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
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
    case .convertFormat, .quality:
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

private extension NSAttributedString {
  /// Text document types AppKit can read, paired with the UTType that names
  /// them, so the supported list follows AppKit rather than a hand-written one.
  static let textDocumentTypes: [UTType: NSAttributedString.DocumentType] = {
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
}
