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
}
