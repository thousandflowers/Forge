import Foundation
import UniformTypeIdentifiers

/// Registry that manages available processors and selects the appropriate one for a file
actor ProcessorRegistry {
  private var nativeProcessors: [FileProcessor] = []
  private var externalProcessors: [FileProcessor] = []
  private let settings: AppSettings

  init(settings: AppSettings = .load()) {
    self.settings = settings

    // Register native processors
    self.nativeProcessors = [
      ImageProcessor(),
      VideoProcessor(),
      AudioProcessor(),
      SimpleDocProcessor()
    ]
  }

  /// Register an external processor (Phase 3)
  func registerExternal(_ processor: FileProcessor) {
    externalProcessors.append(processor)
  }

  /// Find the best processor for a given file
  func processor(for file: ProcessableFile) -> FileProcessor? {
    // Tier 1: Try native processors (always highest priority)
    if let native = nativeProcessors.first(where: { $0.canProcess(file) }) {
      return native
    }

    // Tier 2: Check enabled external processors
    if settings.externalProcessorsEnabled {
      if let external = externalProcessors.first(where: { $0.canProcess(file) }) {
        return external
      }
    }

    return nil // Unsupported
  }

  /// Get all output formats supported for a given input type
  func supportedOutputTypes(for input: UTType) -> [UTType] {
    var types: Set<UTType> = []

    for processor in nativeProcessors where processor.canProcess(ProcessableFile.mock(type: input)) {
      types.formUnion(processor.supportedOutputTypes(for: input))
    }

    if settings.externalProcessorsEnabled {
      for processor in externalProcessors where processor.canProcess(ProcessableFile.mock(type: input)) {
        types.formUnion(processor.supportedOutputTypes(for: input))
      }
    }

    return Array(types).sorted { $0.identifier < $1.identifier }
  }

  /// Get all processors that can handle a given input type (for UI display)
  func availableProcessors(for file: ProcessableFile) -> [FileProcessor] {
    var procs: [FileProcessor] = []
    if let native = nativeProcessors.first(where: { $0.canProcess(file) }) {
      procs.append(native)
    }
    if settings.externalProcessorsEnabled {
      procs.append(contentsOf: externalProcessors.filter { $0.canProcess(file) })
    }
    return procs
  }
}

// MARK: - Mock helper

extension ProcessableFile {
  /// Create a mock ProcessableFile only for type checking (no file exists)
  fileprivate static func mock(type: UTType) -> ProcessableFile {
    // This is hacky but works for registry queries
    // In production we'd have a better API
    let tempURL = URL(fileURLWithPath: "/dev/null")
    return try! ProcessableFile(
      url: tempURL,
      fileType: type,
      fileName: "mock.\(type.preferredFilenameExtension ?? "dat")",
      fileSize: 0,
      dimensions: nil
    )
  }

  private init(url: URL, fileType: UTType, fileName: String, fileSize: Int64, dimensions: (Int, Int)?) {
    self.url = url
    self.fileType = fileType
    self.fileName = fileName
    self.fileSize = fileSize
    self.dimensions = dimensions
  }
}
