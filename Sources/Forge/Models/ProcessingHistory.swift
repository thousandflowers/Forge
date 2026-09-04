import Foundation

struct ProcessingHistory: Identifiable, Codable, Sendable {
  var id = UUID()
  var fileURL: URL
  var ruleId: UUID?
  var timestamp = Date()
  var status: ProcessingStatus
  var errorMessage: String?
  var duration: TimeInterval
  var outputURL: URL?
}

/// Where a file has got to. The first two are only ever shown on screen; the
/// rest are what gets written to history.
enum ProcessingStatus: String, Codable, Sendable, CaseIterable {
  case pending
  case processing
  case completed
  case failed
  case cancelled

  var displayName: String { rawValue.capitalized }
}
