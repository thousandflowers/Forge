import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Simple document processor for PDF ↔ images and text conversions
/// Note: Full DOCX/XLSX/PPTX conversion requires external tools (LibreOffice) in Phase 3
final class SimpleDocProcessor: FileProcessor, @unchecked Sendable {
  let name = "Document Processor"
  let supportedTypes: [UTType] = {
    var types: [UTType] = []
    // Document types
    if let pdf = UTType(filenameExtension: "pdf") { types.append(pdf) }
    if let plain = UTType(filenameExtension: "txt") { types.append(plain) }
    // CSV and HTML have specific identifiers
    if let csv = UTType("public.comma-separated-values-text") { types.append(csv) }
    if let html = UTType("public.html") { types.append(html) }
    if let rtf = UTType(filenameExtension: "rtf") { types.append(rtf) }
    return types
  }()

  func canProcess(_ file: ProcessableFile) -> Bool {
    supportedTypes.contains { file.fileType.conforms(to: $0) }
  }

  func supportedOutputTypes(for input: UTType) -> [UTType] {
    if input.conforms(to: .pdf) {
      var types: [UTType] = []
      ["jpeg", "png", "tiff"].forEach { ext in
        if let type = UTType(filenameExtension: ext) {
          types.append(type)
        }
      }
      return types // Convert PDF to images
    }
    // Text formats can go to plain text or CSV
    var types: [UTType] = []
    if let plain = UTType(filenameExtension: "txt") { types.append(plain) }
    if let csv = UTType("public.comma-separated-values-text") { types.append(csv) }
    if let html = UTType("public.html") { types.append(html) }
    return types
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    try validateOperations(operations, for: try Self.determineInputType(input))

    let inputType = try Self.determineInputType(input)

    if inputType.conforms(to: .pdf) {
      return try await processPDFtoImage(input: input, output: output, operations: operations, progress: progress)
    } else if inputType.conforms(to: .plainText) || inputType.conforms(to: UTType("public.comma-separated-values-text")!) {
      return try await processTextConversion(input: input, output: output, operations: operations)
    } else {
      throw ProcessingError.unsupportedFormat(inputType)
    }
  }

  // MARK: - PDF to Images

  private func processPDFtoImage(
    input: URL,
    output: URL,
    operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    // Determine output image format
    let outputUTI = Self.determineOutputUTI(from: output, operations: operations)

    guard let pdf = PDFDocument(url: input) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open PDF")
    }

    let pageCount = pdf.pageCount
    guard pageCount > 0 else {
      throw ProcessingError.conversionFailed(reason: "PDF has no pages")
    }

    // For MVP, convert only first page (expand later)
    let pageIndex = 0
    guard let page = pdf.page(at: pageIndex) else {
      throw ProcessingError.conversionFailed(reason: "Cannot read page")
    }

    let pageRect = page.bounds(for: .mediaBox)
    let width = Int(pageRect.width)
    let height = Int(pageRect.height)

    // Create image from PDF page
    let pdfImage = page.thumbnail(of: CGSize(width: width, height: height), for: .mediaBox)

    guard let cgImage = pdfImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot render PDF page to image")
    }

    // For MVP, just write the CGImage directly (no operations)
    // TODO: Apply operations using CIContext (need to create one or inject)
    let rendered = cgImage

    // Write output image
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, outputUTI.identifier as CFString, 1, nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot create image destination")
    }

    let options: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: 0.85
    ]
    CGImageDestinationAddImage(destination, rendered, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ProcessingError.conversionFailed(reason: "Failed to write image")
    }

    progress(1.0)

    let outputSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64 ?? 0

    return ProcessingResult(
      outputURL: output,
      outputSize: outputSize,
      outputDimensions: (width, height),
      duration: Date().timeIntervalSince(start)
    )
  }

  // MARK: - Text Conversion

  private func processTextConversion(
    input: URL,
    output: URL,
    operations: [Operation]
  ) async throws -> ProcessingResult {
    let start = Date()

    // Read input text
    let inputString = try String(contentsOf: input, encoding: .utf8)

    // For MVP, just copy (no transformation)
    // Later: CSV normalization, HTML stripping, etc.
    try inputString.write(to: output, atomically: true, encoding: .utf8)

    let outputSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64 ?? 0

    return ProcessingResult(
      outputURL: output,
      outputSize: outputSize,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  // MARK: - Helpers

  private static func determineInputType(_ url: URL) throws -> UTType {
    guard let type = UTType(filenameExtension: url.pathExtension) else {
      throw ProcessingError.unknownType
    }
    return type
  }

  private static func determineOutputUTI(from outputURL: URL, operations: [Operation]) -> UTType {
    if let convertOp = operations.first(where: { if case .convertFormat = $0 { return true } else { return false } }),
       case .convertFormat(let to) = convertOp {
      return to
    }
    if let type = UTType(filenameExtension: outputURL.pathExtension) {
      return type
    }
    // PDF pages default to JPEG using known identifier
    return UTType(filenameExtension: "jpeg") ?? UTType("public.jpeg") ?? .png
  }
}
