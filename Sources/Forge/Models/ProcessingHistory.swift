import Foundation

struct ProcessingHistory: Identifiable, Codable, Sendable {
  let id: UUID
  let fileURL: URL
  let ruleId: UUID?
  let timestamp: Date
  let status: ProcessingStatus
  let errorMessage: String?
  let duration: TimeInterval
  let outputURL: URL?

  init(
    id: UUID = UUID(),
    fileURL: URL,
    ruleId: UUID?,
    timestamp: Date = Date(),
    status: ProcessingStatus,
    errorMessage: String? = nil,
    duration: TimeInterval,
    outputURL: URL? = nil
  ) {
    self.id = id
    self.fileURL = fileURL
    self.ruleId = ruleId
    self.timestamp = timestamp
    self.status = status
    self.errorMessage = errorMessage
    self.duration = duration
    self.outputURL = outputURL
  }
}

enum ProcessingStatus: String, Codable, Sendable {
  case completed = "completed"
  case failed = "failed"
  case cancelled = "cancelled"
}
