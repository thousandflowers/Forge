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
  /// Leave everything alone but the files whose names say what they want:
  /// what lets a whole desk be watched without every screenshot on it being
  /// converted.
  var onlyWhenRenamed = false

  var displayName: String {
    url.lastPathComponent
  }

  /// The folder as a sentence, the way Shortcuts lists an automation.
  var arrivalSentence: String { "When files \(onlyWhenRenamed ? "are renamed" : "arrive") in \(Self.abbreviated(url))" }

  /// What happens to them, in the same words: which preset, where the copies
  /// go, whether subfolders count.
  func detail(presetName: String) -> String {
    let destination: String
    switch destinationMode {
    case .overwrite: destination = "replaces the originals"
    case .copyTo: destination = destinationURL.map { "copies into \(Self.abbreviated($0))" } ?? "copies, but no folder is chosen"
    case .moveTo: destination = destinationURL.map { "moves into \(Self.abbreviated($0))" } ?? "moves, but no folder is chosen"
    }
    return [presetName, destination, includeSubfolders ? "subfolders too" : "subfolders ignored"]
      .joined(separator: " · ")
  }

  /// `~/Downloads` rather than `/Users/somebody/Downloads`.
  static func abbreviated(_ url: URL) -> String {
    (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
  }
}

extension MonitoredFolder {
  private enum CodingKeys: String, CodingKey {
    case id, url, ruleId, destinationMode, destinationURL, isActive, includeSubfolders, onlyWhenRenamed
  }

  /// A folder saved before a setting existed is a folder without it.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(UUID.self, forKey: .id),
      url: try c.decode(URL.self, forKey: .url),
      ruleId: try c.decode(UUID.self, forKey: .ruleId),
      destinationMode: try c.decode(DestinationMode.self, forKey: .destinationMode),
      destinationURL: try c.decodeIfPresent(URL.self, forKey: .destinationURL),
      isActive: try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true,
      includeSubfolders: try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? false,
      onlyWhenRenamed: try c.decodeIfPresent(Bool.self, forKey: .onlyWhenRenamed) ?? false
    )
  }
}

enum DestinationMode: String, Codable, CaseIterable, Sendable {
  case copyTo = "copy_to"
  case moveTo = "move_to"
  case overwrite = "overwrite"

  var displayName: String {
    switch self {
    case .overwrite: return "Replace the original"
    case .copyTo: return "Copy to…"
    case .moveTo: return "Move to…"
    }
  }
}
