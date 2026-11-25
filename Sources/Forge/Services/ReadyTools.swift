import Foundation

/// Each thing Forge does to a file, as a preset that is ready: installed, it is in
/// the Convert window, in the menu over a file, in folders, in Shortcuts and in
/// the Finder, like any other.
enum ReadyTools {
  static let topic = "tool"

  static let entries: [PresetGallery.Entry] = Tool.Kind.allCases.map { kind in
    var preset = RulePreset(
      name: kind.title, description: kind.summary + ".", category: kind.presetCategory, actions: [.tool(kind.blank)].settlingFormat()
    )
    preset.inputFormats = kind.extensions
    // A film without its background is not a PNG: what it becomes is settled
    // when the file is known.
    if kind.kinds.count > 1 { preset.actions = [.tool(kind.blank)] }
    return PresetGallery.Entry(
      author: "Forge", summary: "\(kind.summary). With _\(kind.blank.word) in a file\u{2019}s name, the same.", preset: preset, tags: [topic]
    )
  }
}

extension Tool.Kind {
  var presetCategory: PresetCategory { kinds.count == 1 ? kinds.first?.presetCategory ?? .custom : .custom }

  /// The only files it is done to, where a kind of file is too wide.
  var extensions: [String]? {
    switch self {
    case .layers: return ["psd", "psb"]
    case .tidy: return ["json", "xml", "css", "js", "svg"]
    default: return kinds == [.document] ? ["pdf"] : nil
    }
  }
}

extension Tool {
  /// Everything that can be done to all of these, what people reach for first.
  static func all(for files: [ProcessableFile]) -> [Tool] {
    let kinds = Set(files.compactMap { ConvertKind(fileType: $0.fileType) })
    guard kinds.count == 1, let kind = kinds.first else { return [] }
    var seen: Set<String> = []
    return (handy(for: kind) + Kind.allCases.map(\.blank))
      .filter { tool in files.allSatisfy { tool.suits($0.fileType) } && seen.insert(tool.word).inserted }
  }
}
