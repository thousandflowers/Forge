import Foundation
import ModelIO
import UniformTypeIdentifiers

/// 3D models, through ModelIO.
///
/// ModelIO is part of macOS, so this needs nothing installed. It also does not
/// cover glTF, GLB or FBX, and `FormatCatalog` reports what it does cover
/// rather than guessing.
final class ModelProcessor: FileProcessor, @unchecked Sendable {
  let name = "Model Processor"

  func canProcess(_ file: ProcessableFile) -> Bool {
    guard let ext = file.url.pathExtension.nilIfEmpty else { return false }
    return MDLAsset.canImportFileExtension(ext.lowercased())
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    guard let outputExtension = output.pathExtension.nilIfEmpty,
          MDLAsset.canExportFileExtension(outputExtension.lowercased()) else {
      let from = UTType(filenameExtension: input.pathExtension) ?? .data
      let to = UTType(filenameExtension: output.pathExtension) ?? .data
      throw ProcessingError.unsupportedConversion(from: from, to: to)
    }

    progress(0.2)
    let asset = MDLAsset(url: input)
    guard asset.count > 0 else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) contains no geometry")
    }

    progress(0.6)
    try Task.checkCancellation()
    try asset.export(to: output)
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
