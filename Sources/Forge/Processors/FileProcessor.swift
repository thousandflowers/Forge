import Foundation
import UniformTypeIdentifiers

/// Result of processing a file
struct ProcessingResult: Sendable {
  let outputURL: URL
  let outputSize: Int64
  let outputDimensions: (width: Int, height: Int)?
  let duration: TimeInterval
  /// Extra files the conversion produced, in order. One input can legitimately
  /// yield many outputs: a twenty-page PDF becomes twenty images.
  let additionalOutputs: [URL]

  init(
    outputURL: URL,
    outputSize: Int64,
    outputDimensions: (width: Int, height: Int)?,
    duration: TimeInterval,
    additionalOutputs: [URL] = []
  ) {
    self.outputURL = outputURL
    self.outputSize = outputSize
    self.outputDimensions = outputDimensions
    self.duration = duration
    self.additionalOutputs = additionalOutputs
  }
}

/// Protocol for file processors
protocol FileProcessor: AnyObject, Sendable {
  var name: String { get }
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

