import SwiftUI
import UniformTypeIdentifiers

struct OutputFormat: Identifiable, Hashable {
  /// `nil` means "keep the source format".
  let type: UTType?

  var id: String { type?.identifier ?? "keep" }

  var label: String {
    guard let type else { return "Keep original" }
    // Not `preferredFilenameExtension`: `public.toml` prefers `cfg`, and a
    // menu offering CFG is a menu nobody finds TOML in.
    return FormatCatalog.fileExtension(for: type)?.uppercased() ?? type.identifier
  }

  static let keep = OutputFormat(type: nil)

  static var images: [OutputFormat] { Self.sorted(FormatCatalog.writableImageTypes) }
  static var audio: [OutputFormat] { Self.sorted(Set(FormatCatalog.writableAudioTypes.keys)) }
  static var video: [OutputFormat] { Self.sorted(FormatCatalog.writableVideoTypes) }
  static var documents: [OutputFormat] {
    Self.sorted(Set(DocumentText.writable.keys).union([.pdf]).union([Book.type].compactMap { $0 }))
  }

  /// The image formats, plus the ones a tool on this Mac adds. Offered only
  /// where an image processor will do the writing: a PDF asked for WebP goes
  /// to the document processor, which has no idea what cwebp is.
  static var imagesWithTools: [OutputFormat] {
    var types = FormatCatalog.writableImageTypes
    if ExternalTools.locate("cwebp") != nil, let webp = UTType("org.webmproject.webp") {
      types.insert(webp)
    }
    types.insert(.svg)
    return Self.sorted(types)
  }

  /// Words out of a file: OCR for anything with pixels, transcription for
  /// anything with a soundtrack. One format, because both paths write text.
  static var text: [OutputFormat] { [OutputFormat(type: .plainText)] }

  /// What the tools installed on this Mac write for this kind of file and the
  /// system does not. Offered in a group of their own, so that it is clear
  /// where they come from - and why they are gone if a tool is.
  static func withTools(for kind: ConvertKind) -> [OutputFormat] {
    let own = Set((audio + video + images + documents + data + subtitles + fonts + models).compactMap(\.type))
    let fits: (UTType) -> Bool
    switch kind {
    case .video: fits = { $0.conforms(to: .audiovisualContent) || $0.conforms(to: .audio) }
    case .audio: fits = { $0.conforms(to: .audio) && !$0.conforms(to: .movie) }
    case .document, .data: fits = { !$0.conforms(to: .audiovisualContent) && !$0.conforms(to: .image) }
    default: return []
    }
    let found = ExternalBridge.formatsWrittenByTools(for: kind)
    return sorted(Set(found.filter { fits($0) && !own.contains($0) }))
  }

  /// The subtitle formats Forge writes. They are named by extension because
  /// macOS has no types for them - `.srt` is not in the type database at all.
  static var subtitles: [OutputFormat] {
    ["srt", "vtt", "sbv", "ass", "lrc", "ttml"].compactMap { ext in
      UTType(filenameExtension: ext, conformingTo: .plainText).map { OutputFormat(type: $0) }
    }
  }

  static var fonts: [OutputFormat] {
    FontProcessor.writable.compactMap { ext in
      FormatCatalog.type(named: ext).map { OutputFormat(type: $0) }
    }
  }

  /// What `DataProcessor` writes: it refuses any other pairing rather than
  /// writing something nothing can open.
  static var data: [OutputFormat] {
    let own = (DataProcessor.records + DataProcessor.tables + DataProcessor.settings + DataProcessor.places + DataProcessor.cards).compactMap(FormatCatalog.type(named:))
    return Self.sorted(Set(DataProcessor.readable).union(own.filter { $0 != FormatCatalog.type(named: "ndjson") }))
  }

  /// Data as something to look at.
  static var dataPages: [OutputFormat] { Self.sorted(Set([.html, DocumentText.markdown].compactMap { $0 })) }

  static var models: [OutputFormat] { Self.sorted(FormatCatalog.writableModelTypes) }

  private static func sorted(_ types: Set<UTType>) -> [OutputFormat] {
    types.map { OutputFormat(type: $0) }.sorted { $0.label < $1.label }
  }
}

