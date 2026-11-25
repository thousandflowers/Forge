import Foundation

/// A past conversion, as the menu bar says it: what it came to, and what can
/// still be done about it. Worked out away from the main thread: every one of
/// these is a look at the disk.
struct Recent: Equatable, Sendable {
  let outputs: [URL]
  /// Nil where there is nothing to weigh it against.
  let before: Int64?
  let after: Int64?
  let canUndo: Bool

  static let most = 6

  /// What was left alone, or stopped by hand, is not something to come back to.
  static func entries(of history: [ProcessingHistory]) -> [ProcessingHistory] {
    Array(history.lazy.filter { $0.status == .completed || $0.status == .failed }.prefix(most))
  }

  init(_ entry: ProcessingHistory) {
    outputs = entry.isUndone ? [] : entry.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
    after = outputs.isEmpty ? nil : outputs.reduce(Int64(0)) { $0 + (Self.size(of: $1) ?? 0) }
    // Replaced in place, what has its name now is the result.
    let isReplaced = entry.outputs.contains { $0.standardizedFileURL == entry.fileURL.standardizedFileURL }
    before = entry.isSomethingElse == true ? nil : entry.backupURL.flatMap(Self.size) ?? (isReplaced ? nil : Self.size(of: entry.fileURL))
    canUndo = Undo.isPossible(for: entry)
  }

  private static func size(of url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
  }
}
