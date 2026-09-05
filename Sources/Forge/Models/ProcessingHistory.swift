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
  /// The rest of what this conversion wrote. A preset asking for two formats
  /// writes two files, and history used to keep the first and forget the
  /// other - both were on disk and only one was accounted for.
  ///
  /// Optional so that a history written before this existed still decodes.
  var additionalOutputs: [URL]?
  /// Where the output was asked to go, so a row can be run again. Nil for a
  /// conversion in place, which has no folder to send anything to.
  var destinationFolder: URL?

  /// Every file this conversion produced.
  var outputs: [URL] { [outputURL].compactMap { $0 } + (additionalOutputs ?? []) }

  /// How long it took, in words. A conversion that takes 40 milliseconds is
  /// not "0.0s" - that reads like nothing happened.
  var durationText: String? {
    guard duration > 0 else { return nil }
    if duration < 1 { return "\(Int((duration * 1000).rounded())) ms" }
    return String(format: "%.1f s", duration)
  }
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
