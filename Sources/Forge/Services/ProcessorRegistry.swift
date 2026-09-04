import Foundation
import UniformTypeIdentifiers

/// Registry that manages available processors and selects the appropriate one for a file
actor ProcessorRegistry {
  private let nativeProcessors: [FileProcessor] = [
    ImageProcessor(),
    MediaProcessor(),
    SimpleDocProcessor()
  ]

  /// Find the best processor for a given file
  func processor(for file: ProcessableFile) -> FileProcessor? {
    nativeProcessors.first { $0.canProcess(file) }
  }

  /// Get all output formats supported for a given input type
  func supportedOutputTypes(for input: UTType) -> [UTType] {
    var types: Set<UTType> = []
    for processor in nativeProcessors where processor.canProcess(.mock(type: input)) {
      types.formUnion(processor.supportedOutputTypes(for: input))
    }
    return Array(types).sorted { $0.identifier < $1.identifier }
  }
}

// MARK: - Mock helper

extension ProcessableFile {
  /// Create a mock ProcessableFile only for type checking (no file exists).
  fileprivate static func mock(type: UTType) -> ProcessableFile {
    ProcessableFile(
      url: URL(fileURLWithPath: "/dev/null"),
      fileType: type,
      fileName: "mock.\(type.preferredFilenameExtension ?? "dat")",
      fileSize: 0,
      dimensions: nil
    )
  }
}
