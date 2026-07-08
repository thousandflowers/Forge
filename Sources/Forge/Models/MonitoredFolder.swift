import Foundation

/// A folder that is watched for new files and automatically processes them
struct MonitoredFolder: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  var url: URL
  var ruleId: UUID
  var destinationMode: DestinationMode
  var destinationURL: URL?
  var isActive: Bool
  var includeSubfolders: Bool

  init(
    id: UUID = UUID(),
    url: URL,
    ruleId: UUID,
    destinationMode: DestinationMode,
    destinationURL: URL? = nil,
    isActive: Bool = true,
    includeSubfolders: Bool = false
  ) {
    self.id = id
    self.url = url
    self.ruleId = ruleId
    self.destinationMode = destinationMode
    self.destinationURL = destinationURL
    self.isActive = isActive
    self.includeSubfolders = includeSubfolders
  }

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
