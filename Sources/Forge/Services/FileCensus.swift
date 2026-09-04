import Foundation

/// What kinds of file this Mac actually holds.
///
/// The Capabilities screen uses it to put what would help *you* first: someone
/// with four hundred WebP files wants the WebP encoder, and someone with none
/// does not. Only names are read — never contents, never anything off the
/// machine — and only when asked, because the first look at these folders is
/// what makes macOS put up its permission sheet.
enum FileCensus {

  /// Where a person's own files live. Not the whole home folder: caches, build
  /// products and node_modules are somebody else's files and would drown the
  /// count.
  static let places: [FileManager.SearchPathDirectory] = [
    .desktopDirectory,
    .downloadsDirectory,
    .documentDirectory,
    .picturesDirectory,
    .moviesDirectory,
    .musicDirectory,
  ]

  /// How many files to look at before stopping. A photo library alone can run
  /// to six figures, and the answer does not get better after the first few
  /// thousand: this is a sense of what somebody has, not an audit.
  static let limit = 40_000

  /// How deep to go. Deep enough to see inside a project folder, shallow
  /// enough not to walk somebody's whole archive.
  static let depth = 3

  /// How many files carry each of these extensions.
  ///
  /// Extensions are matched lowercased, and anything not asked about is never
  /// tallied: the caller says what it cares about, and nothing else is counted.
  static func counts(of extensions: Set<String>) async -> [String: Int] {
    let wanted = Set(extensions.map { $0.lowercased() })
    guard !wanted.isEmpty else { return [:] }

    return await Task.detached(priority: .utility) {
      var counts: [String: Int] = [:]
      var seen = 0

      for place in places {
        guard let root = try? FileManager.default.url(
          for: place, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { continue }

        guard let walker = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }

        for case let url as URL in walker {
          if seen >= limit { return counts }
          if walker.level > depth {
            walker.skipDescendants()
            continue
          }

          let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
          if isDirectory { continue }

          seen += 1
          let ext = url.pathExtension.lowercased()
          if wanted.contains(ext) { counts[ext, default: 0] += 1 }
        }
      }

      return counts
    }.value
  }
}
