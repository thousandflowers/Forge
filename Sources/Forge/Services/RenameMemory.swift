import Foundation

/// What the files in a watched folder were called, so that a file given a word
/// can be told from one that came with it: `bathroom_mirror.png` is a
/// photograph of a mirror until somebody there calls it that.
final class RenameMemory {
  private static let most = 20_000
  private var names: [UInt64: String] = [:]

  /// What is there before anything happens.
  func remember(_ folder: URL, subfolders: Bool) {
    let options: FileManager.DirectoryEnumerationOptions = subfolders ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    guard let there = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: options) else { return }
    for case let url as URL in there {
      guard names.count < Self.most else { return }
      _ = wasRenamed(url)
    }
  }

  /// Whether this file was here under another name. Either way it is known by
  /// this one from now on.
  func wasRenamed(_ url: URL) -> Bool {
    guard let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64 else { return false }
    let before = names.updateValue(url.lastPathComponent, forKey: number)
    return before != nil && before != url.lastPathComponent
  }
}
