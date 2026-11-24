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
  /// The preset's "Only if" is not true of this file, so it was left as it
  /// is - which is the preset doing its job, not a failure.
  case leftAlone(reason: String)
  /// It could not be made to fit in the size asked for.
  case tooBig(reason: String)

  var errorDescription: String? {
    switch self {
    case .fileNotFound:
      return "The file could not be found."
    case .unknownType:
      return "The file type could not be determined."
    case .unreadableFormat(let type):
      return "Forge cannot open \(Self.name(type)) files." + Self.whatWouldOpen(type)
    case .unsupportedConversion(let from, let to):
      return "Forge cannot convert \(Self.name(from)) to \(Self.name(to))."
    case .conversionFailed(let reason):
      return reason
    case .validationFailed(let message):
      return message
    case .leftAlone(let reason), .tooBig(let reason):
      return reason
    }
  }

  /// The tool that opens this format, where there is one and this Mac lacks
  /// it. A refusal that stops at "cannot open" leaves out the one thing that
  /// would change the answer.
  private static func whatWouldOpen(_ type: UTType) -> String {
    guard let ext = type.preferredFilenameExtension?.lowercased() else { return "" }
    for capability in Capabilities.all where capability.evidence.contains(ext) {
      if case .needsPack(let pack) = capability.status, pack.isWired, let tool = pack.tool, !tool.isInstalled {
        return " \(tool.formula) can: \(tool.installCommand)"
      }
    }
    return ""
  }

  private static func name(_ type: UTType) -> String {
    FormatCatalog.fileExtension(for: type)?.uppercased() ?? type.identifier
  }
}
