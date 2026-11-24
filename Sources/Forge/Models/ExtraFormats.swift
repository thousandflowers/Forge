import Foundation
import UniformTypeIdentifiers

/// The formats Forge reads or writes itself, which macOS may have no name for.
/// Each conforms to what it is a kind of, so that the rest of the app files it
/// rightly without knowing it was made up here.
enum ExtraFormats {
  private static let kinds: [(is: UTType, extensions: Set<String>)] = [
    (.font, FontProcessor.readable),
    (.threeDContent, ModelProcessor.own),
    (.archive, ArchiveProcessor.own),
    (.midi, ["mid", "midi", "kar"]),
    (.plainText, Subtitles.readableExtensions.union(["toml"])),
    (.data, DataFormats.binary.union(ComicProcessor.readable)),
    (.text, DataFormats.written),
  ]

  /// - Returns: nil where macOS has a name of its own, or nobody here reads it.
  static func type(_ ext: String) -> UTType? {
    let ext = ext.lowercased()
    // What a tool reads and nobody else does, where the tool is here.
    if let tool = ExternalBridge.special.first(where: { $0.extensions.contains(ext) }) {
      return ExternalTools.locate(tool.binary) == nil ? nil : UTType(filenameExtension: ext, conformingTo: tool.isWords ? .text : .data)
    }
    guard let kind = kinds.first(where: { $0.extensions.contains(ext) }) else { return nil }
    return UTType(filenameExtension: ext, conformingTo: kind.is)
  }
}

extension UTType {
  /// Whether files of this type go by one of these names.
  func goes(by extensions: Set<String>) -> Bool {
    guard let first = preferredFilenameExtension else { return false }
    return extensions.contains(first.lowercased()) || (tags[.filenameExtension] ?? []).contains { extensions.contains($0.lowercased()) }
  }
}
