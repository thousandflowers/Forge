import Foundation
import UniformTypeIdentifiers

/// Result of processing a file
struct ProcessingResult: Sendable {
  let outputURL: URL
  let outputSize: Int64
  let outputDimensions: (width: Int, height: Int)?
  let duration: TimeInterval
}

/// Protocol for file processors
protocol FileProcessor: AnyObject, Sendable {
  var name: String { get }
  var isNative: Bool { get }
  var supportedTypes: [UTType] { get }

  func canProcess(_ file: ProcessableFile) -> Bool
  func supportedOutputTypes(for input: UTType) -> [UTType]

  /// Process the input file and write to output location.
  /// - Parameters:
  ///   - input: Source file URL
  ///   - output: Destination file URL (should not exist)
  ///   - operations: List of operations to apply (filtered to supported ones)
  ///   - progress: Closure called with progress 0.0...1.0
  /// - Returns: ProcessingResult with metadata
  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult
}

// Helper extension for FileProcessor
extension FileProcessor {
  func filterSupportedOperations(_ operations: [Operation], for fileType: UTType) -> [Operation] {
    // For MVP, return all operations. Later, filter based on capability.
    operations
  }

  func validateOperations(_ operations: [Operation], for inputType: UTType) throws {
    // Basic validation: can't convert to same format?
    if let convertOp = operations.first(where: {
      if case .convertFormat = $0 { return true } else { return false }
    }) {
      if case .convertFormat(let to) = convertOp, to == inputType {
        throw ProcessingError.validationFailed(message: "Source and destination formats are the same.")
      }
    }
  }
}
