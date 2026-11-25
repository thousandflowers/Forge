import Foundation

/// What the files in a watched folder were called, so that a file given a word
/// can be told from one that came with it: `bathroom_mirror.png` is a
/// photograph of a mirror until somebody there calls it that.
final class RenameMemory: @unchecked Sendable {
  private static let most = 20_000
  /// Learnt on the watcher's queue, asked on the main one.
  private let lock = NSLock()
  private var names: [UInt64: String] = [:]

  /// What is there before anything happens.
  func remember(_ folder: URL, subfolders: Bool) {
    let options: FileManager.DirectoryEnumerationOptions = subfolders ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    guard let there = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: options) else { return }
    for case let url as URL in there {
      guard lock.withLock({ names.count < Self.most }) else { return }
      _ = wasRenamed(url)
    }
  }

  /// Whether this file was here under another name. Either way it is known by
  /// this one from now on.
  func wasRenamed(_ url: URL) -> Bool { nameBefore(url) != nil }

  /// What it was called here, if that was something else.
  func nameBefore(_ url: URL) -> String? {
    guard let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64 else { return nil }
    let before = lock.withLock { names.updateValue(url.lastPathComponent, forKey: number) }
    return before == url.lastPathComponent ? nil : before
  }

  /// Called this by Forge, and not by somebody who wants something.
  func know(_ url: URL) { _ = nameBefore(url) }
}
