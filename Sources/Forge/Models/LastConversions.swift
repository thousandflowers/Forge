import Foundation

/// What a batch became, kept so the next batch of the same kind can be sent the
/// same way in one press.
///
/// The Convert sheet itself starts from nothing: a choice made for a film
/// showed up on the next song as "MOV · 1280×720 · HEVC". Remembered here
/// instead, one per kind of file, the last song's conversion is there for the
/// next song even after a film went through in between.
struct LastConversion: Codable, Equatable {
  var preset: RulePreset
  var mode: DestinationMode
  var destination: URL?
}

enum LastConversions {
  static let key = "lastConversionByKind"

  static func all(in defaults: UserDefaults = .standard) -> [ConvertKind: LastConversion] {
    guard let data = defaults.data(forKey: key),
          let stored = try? JSONDecoder().decode([ConvertKind: LastConversion].self, from: data) else { return [:] }
    return stored
  }

  /// Kept for every kind in the batch: a mixed batch that only took the
  /// location out of everything did that to each kind of file in it.
  static func record(_ conversion: LastConversion, for kinds: Set<ConvertKind>, in defaults: UserDefaults = .standard) {
    var stored = all(in: defaults)
    for kind in kinds { stored[kind] = conversion }
    if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
  }

  /// The conversion to offer for these files, or nil. Offered only for a
  /// batch of one kind, and only while it can still run here: the preset still
  /// suits these files (a tool it needed may have gone) and the folder it wrote
  /// into is still there.
  static func offer(for files: [ProcessableFile], in defaults: UserDefaults = .standard) -> LastConversion? {
    let kinds = Set(files.compactMap { ConvertKind(fileType: $0.fileType) })
    guard kinds.count == 1, let kind = kinds.first, let last = all(in: defaults)[kind] else { return nil }
    guard last.preset.suits(kinds), last.preset.suits(files),
          files.allSatisfy({ last.preset.accepts($0.url) }) else { return nil }
    if last.mode != .overwrite {
      guard let folder = last.destination else { return nil }
      var isFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
    }
    return last
  }
}
