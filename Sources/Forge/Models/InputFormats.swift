import Foundation
import UniformTypeIdentifiers

/// Every format Forge can read, by kind, as file extensions.
///
/// Built from the same catalogs the processors open files with, so the list a
/// preset chooses from is the list of what would actually get through.
enum InputFormats {
  struct Group: Identifiable {
    let kind: ConvertKind
    let extensions: [String]
    var id: String { kind.rawValue }
  }

  /// "1 format chosen." / "3 formats chosen.", said the same in every place.
  static func chosen(_ count: Int) -> String {
    count == 1 ? "1 format chosen." : "\(count) formats chosen."
  }

  static let groups: [Group] = {
    func extensions(_ types: some Sequence<UTType>) -> [String] {
      // The name people type, not always the system's first choice: TOML's is `cfg`.
      Array(Set(types.compactMap { (FormatCatalog.fileExtension(for: $0) ?? $0.preferredFilenameExtension)?.lowercased() })).sorted()
    }
    let media = FormatCatalog.readableMediaTypes
    let audio = media.filter { $0.conforms(to: .audio) }
    // Films only. "Everything that is not audio" put playlists (M3U, PLS),
    // captions (VTT, SCC, TTML) and audio macOS has no class for (AWB, XHE)
    // under Videos.
    // ponytail: unclassified dyn types get no chip; "Any" still takes them.
    let video = media.filter { $0.conforms(to: .movie) }
    let documents = Set(DocumentText.readable.keys).union(SimpleDocProcessor.readableTypes)
    let fonts = FontProcessor.readable.sorted()
    return [
      Group(kind: .image, extensions: extensions(FormatCatalog.readableImageTypes)),
      Group(kind: .video, extensions: extensions(video)),
      Group(kind: .audio, extensions: extensions(audio)),
      Group(kind: .document, extensions: (extensions(documents) + ComicProcessor.readable).sorted()),
      Group(kind: .data, extensions: Set(extensions(DataProcessor.readable) + DataFormats.written + DataFormats.binary).sorted()),
      Group(kind: .model, extensions: extensions(FormatCatalog.readableModelTypes)),
      Group(kind: .subtitle, extensions: Subtitles.readableExtensions.sorted()),
      Group(kind: .font, extensions: fonts),
    ].filter { !$0.extensions.isEmpty }
  }()
}
