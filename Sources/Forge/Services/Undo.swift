import Foundation

/// Puts a conversion back: what it wrote goes to the Trash, and an original it
/// replaced comes back from its backup.
enum Undo {
  struct NotPossible: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
  }

  /// Offered only while nothing would be lost by it: there is something of
  /// Forge's to take away, and the original is here or can be put back.
  static func isPossible(for entry: ProcessingHistory) -> Bool {
    guard entry.status == .completed, !entry.isUndone, !written(by: entry).isEmpty else { return false }
    return backup(of: entry) != nil || originalRemains(entry)
  }

  /// - Returns: the original, where it had to be put back.
  @discardableResult
  static func run(_ entry: ProcessingHistory, discard: (URL) throws -> Void = trash) throws -> URL? {
    guard isPossible(for: entry) else {
      throw NotPossible(reason: "\(entry.fileURL.lastPathComponent) cannot be put back: the original was not kept.")
    }
    guard !originalRemains(entry) || isOutput(entry.fileURL, of: entry), let backup = backup(of: entry) else {
      try written(by: entry).forEach(discard)
      return nil
    }

    // Beside its place first, so that the last step is a rename: a copy that
    // fails half way leaves what was written where it is.
    let fileManager = FileManager.default
    let folder = entry.fileURL.deletingLastPathComponent()
    let waiting = folder.appendingPathComponent(".forge-\(UUID().uuidString).\(entry.fileURL.pathExtension)")
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try fileManager.copyItem(at: backup, to: waiting)
    do {
      try written(by: entry).forEach(discard)
      let place = free(entry.fileURL)
      try fileManager.moveItem(at: waiting, to: place)
      return place
    } catch {
      try? fileManager.removeItem(at: waiting)
      throw error
    }
  }

  static func trash(_ url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }

  private static func written(by entry: ProcessingHistory) -> [URL] {
    entry.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private static func backup(of entry: ProcessingHistory) -> URL? {
    entry.backupURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
  }

  private static func isOutput(_ url: URL, of entry: ProcessingHistory) -> Bool {
    entry.outputs.contains { $0.standardizedFileURL == url.standardizedFileURL }
  }

  /// The original itself, not something that has its name now: one that was
  /// replaced has a backup, and is not here whatever is in its place.
  private static func originalRemains(_ entry: ProcessingHistory) -> Bool {
    entry.backupURL == nil && entry.destinationFolder != nil
      && FileManager.default.fileExists(atPath: entry.fileURL.path) && !isOutput(entry.fileURL, of: entry)
  }

  private static func free(_ url: URL) -> URL {
    let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
    let folder = url.deletingLastPathComponent()
    var candidate = url, number = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
      number += 1
    }
    return candidate
  }
}
