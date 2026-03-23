import Foundation

enum ProcessingError: LocalizedError, Codable, Sendable {
  case fileNotFound
  case unknownType
  case unsupportedFormat(UTType)
  case conversionFailed(reason: String)
  case insufficientDiskSpace(required: Int64, available: Int64)
  case permissionDenied
  case processorCrashed
  case operationFailed(operation: String, underlying: Error?)
  case validationFailed(message: String)
  case externalToolNotFound(String)  // tool name
  case externalToolFailed(tool: String, exitCode: Int32, stderr: String)

  var errorDescription: String? {
    switch self {
    case .fileNotFound:
      return "The file could not be found."
    case .unknownType:
      return "The file type could not be determined."
    case .unsupportedFormat(let type):
      return "Unsupported file format: \(type.localizedString ?? type.identifier)"
    case .conversionFailed(let reason):
      return "Conversion failed: \(reason)"
    case .insufficientDiskSpace(let required, let available):
      let mbReq = Int64(required) / 1024 / 1024
      let mbAvail = Int64(available) / 1024 / 1024
      return "Insufficient disk space. Need \(mbReq)MB, have \(mbAvail)MB."
    case .permissionDenied:
      return "Permission denied. Check file access permissions."
    case .processorCrashed:
      return "The processor crashed. Please try again."
    case .operationFailed(let operation, let underlying):
      if let err = underlying {
        return "Operation '\(operation)' failed: \(err.localizedDescription)"
      }
      return "Operation '\(operation)' failed."
    case .validationFailed(let message):
      return message
    case .externalToolNotFound(let tool):
      return "Required tool '\(tool)' not found. Please install it and enable in Settings."
    case .externalToolFailed(let tool, let exitCode, let stderr):
      return "\(tool) failed with exit code \(exitCode): \(stderr.prefix(200))..."
    }
  }
}
