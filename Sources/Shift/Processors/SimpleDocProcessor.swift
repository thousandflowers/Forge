import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Simple document processor for PDF ↔ images and text conversions
/// Note: Full DOCX/XLSX/PPTX conversion requires external tools (LibreOffice) in Phase 3
final class SimpleDocProcessor: FileProcessor, @unchecked Sendable {
  let name = "Document Processor"
  let isNative = true
  let supportedTypes: [UTType] = [.pdf, .plainText, .txt, .csv, .rtf, .html]

  func canProcess(_ file: ProcessableFile) -> Bool {
    supportedTypes.contains { file.fileType.conforms(to: $0) }
  }

  func supportedOutputTypes(for input: UTType) -> [UTType] {
    if input.conforms(to: .pdf) {
      return [.jpeg, .png, .tiff] // Convert PDF to images
    }
    // Text formats can go to plain text or CSV
    return [.plainText, .csv, .html]
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    try validateOperations(operations, for: try Self.determineInputType(input))

    let inputType = try Self.determineInputType(input)

    if inputType.conforms(to: .pdf) {
      return try processPDFtoImage(input: input, output: output, operations: operations, progress: progress)
    } else if inputType.conforms(to: .plainText) || inputType.conforms(to: .csv) {
      return try processTextConversion(input: input, output: output, operations: operations)
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

    var ciImage = CIImage(cgImage: cgImage)

    // Apply operations
    // Note: we'd need to import CIContext; for now, just write raw
    // In a full implementation, we'd reuse ImageProcessor's CIContext
    // For MVP, just convert format if needed, skip resize/filter
    let rendered = ciImage // TODO: apply operations with CIContext

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
  ) throws -> ProcessingResult {
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
      duration: 0
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
    return .jpeg // PDF pages default to JPEG
  }
}
