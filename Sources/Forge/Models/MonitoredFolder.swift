import Foundation

/// A folder that is watched for new files and automatically processes them
struct MonitoredFolder: Identifiable, Codable, Hashable, Sendable {
  var id = UUID()
  var url: URL
  var ruleId: UUID
  var destinationMode: DestinationMode
  var destinationURL: URL?
  var isActive = true
  var includeSubfolders = false

  var displayName: String {
    url.lastPathComponent
  }

  /// The folder as a sentence, the way Shortcuts lists an automation.
  var arrivalSentence: String { "When files arrive in \(Self.abbreviated(url))" }

  /// What happens to them, in the same words: which preset, where the copies
  /// go, whether subfolders count.
  func detail(presetName: String) -> String {
    let destination: String
    switch destinationMode {
    case .overwrite: destination = "replaces the originals"
    case .copyTo: destination = "copies into \(destinationURL.map(Self.abbreviated) ?? "the same folder")"
    case .moveTo: destination = "moves into \(destinationURL.map(Self.abbreviated) ?? "the same folder")"
    }
    return [presetName, destination, includeSubfolders ? "subfolders too" : "subfolders ignored"]
      .joined(separator: " · ")
  }

  /// `~/Downloads` rather than `/Users/somebody/Downloads`.
  static func abbreviated(_ url: URL) -> String {
    (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
  }
}

enum DestinationMode: String, Codable, CaseIterable, Sendable {
  case overwrite = "overwrite"
  case copyTo = "copy_to"
  case moveTo = "move_to"

  var displayName: String {
    switch self {
    case .overwrite: return "Overwrite Original"
    case .copyTo: return "Copy To..."
    case .moveTo: return "Move To..."
    }
  }
}
