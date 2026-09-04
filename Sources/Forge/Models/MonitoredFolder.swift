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
