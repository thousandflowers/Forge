import Foundation
import UniformTypeIdentifiers

enum ProcessingError: LocalizedError, Sendable {
  case fileNotFound
  case unknownType
  /// Forge cannot open this kind of file at all.
  case unreadableFormat(UTType)
  /// Forge can open the input, but not turn it into the requested output.
  /// Kept separate from `unreadableFormat` because collapsing the two produced
  /// messages like "cannot write JPEG" for an MP3, which reads as though JPEG
  /// were the problem.
  case unsupportedConversion(from: UTType, to: UTType)
  case conversionFailed(reason: String)
  case validationFailed(message: String)

  var errorDescription: String? {
    switch self {
    case .fileNotFound:
      return "The file could not be found."
    case .unknownType:
      return "The file type could not be determined."
    case .unreadableFormat(let type):
      return "Forge cannot open \(Self.name(type)) files."
    case .unsupportedConversion(let from, let to):
      return "Forge cannot convert \(Self.name(from)) to \(Self.name(to))."
    case .conversionFailed(let reason):
      return reason
    case .validationFailed(let message):
      return message
    }
  }

  private static func name(_ type: UTType) -> String {
    type.preferredFilenameExtension?.uppercased() ?? type.identifier
  }
}
