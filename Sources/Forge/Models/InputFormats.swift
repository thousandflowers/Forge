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

  static let groups: [Group] = {
    func extensions(_ types: some Sequence<UTType>) -> [String] {
      Array(Set(types.compactMap { $0.preferredFilenameExtension?.lowercased() })).sorted()
    }
    let media = FormatCatalog.readableMediaTypes
    let audio = media.filter { $0.conforms(to: .audio) }
    let video = media.filter { !$0.conforms(to: .audio) }
    let documents = Set(DocumentText.readable.keys).union(SimpleDocProcessor.readableTypes)
    let fonts = ["ttf", "otf", "woff", "woff2"].filter(ExternalBridge.Fonts.handles)
    return [
      Group(kind: .image, extensions: extensions(FormatCatalog.readableImageTypes)),
      Group(kind: .video, extensions: extensions(video)),
      Group(kind: .audio, extensions: extensions(audio)),
      Group(kind: .document, extensions: extensions(documents)),
      Group(kind: .data, extensions: extensions(DataProcessor.readable)),
      Group(kind: .model, extensions: extensions(FormatCatalog.readableModelTypes)),
      Group(kind: .subtitle, extensions: Subtitles.readableExtensions.sorted()),
      Group(kind: .font, extensions: fonts),
    ].filter { !$0.extensions.isEmpty }
  }()
}
