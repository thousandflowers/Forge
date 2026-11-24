import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a file is by what is in it, for the kinds that begin by saying so.
struct Signature {
  let ext: String
  var also: Set<String> = []
  let begins: (Data) -> Bool

  private static let enough = 1024

  private static func at(_ offset: Int, _ bytes: String) -> (Data) -> Bool {
    let wanted = Data(bytes.unicodeScalars.map { UInt8($0.value & 0xFF) })
    return { $0.count >= offset + wanted.count && $0.dropFirst(offset).prefix(wanted.count) == wanted }
  }

  private static func all(_ tests: ((Data) -> Bool)...) -> (Data) -> Bool { { data in tests.allSatisfy { $0(data) } } }
  private static func any(_ tests: ((Data) -> Bool)...) -> (Data) -> Bool { { data in tests.contains { $0(data) } } }

  static let known: [Signature] = [
    Signature(ext: "pdf", begins: { $0.range(of: Data("%PDF-".utf8)) != nil }),
    Signature(ext: "rtf", begins: at(0, "{\\rtf")),
    Signature(ext: "wav", also: ["w64"], begins: all(any(at(0, "RIFF"), at(0, "RF64")), at(8, "WAVE"))),
    Signature(ext: "avi", begins: all(at(0, "RIFF"), at(8, "AVI "))),
    Signature(ext: "aiff", also: ["aif", "aifc"], begins: all(at(0, "FORM"), at(8, "AIF"))),
    Signature(ext: "flac", begins: at(0, "fLaC")),
    Signature(ext: "ogg", also: ["oga", "ogv", "opus"], begins: at(0, "OggS")),
    Signature(ext: "mp3", begins: any(at(0, "ID3"), at(0, "\u{FF}\u{FB}"), at(0, "\u{FF}\u{F3}"), at(0, "\u{FF}\u{F2}"))),
    Signature(ext: "caf", begins: at(0, "caff")),
    Signature(ext: "mkv", also: ["webm", "mka"], begins: at(0, "\u{1A}\u{45}\u{DF}\u{A3}")),
    Signature(
      ext: "mp4", also: ["mov", "qt", "m4v", "m4a", "m4r", "m4b", "3gp"],
      begins: any(at(4, "ftyp"), at(4, "moov"), at(4, "mdat"), at(4, "wide"), at(4, "free"))
    ),
    Signature(ext: "zip", also: ["docx", "xlsx", "pptx", "odt", "ods", "odp", "epub", "cbz", "usdz", "key", "pages", "numbers"], begins: at(0, "PK\u{03}\u{04}")),
    Signature(ext: "doc", also: ["xls", "ppt"], begins: at(0, "\u{D0}\u{CF}\u{11}\u{E0}")),
    Signature(ext: "7z", begins: at(0, "7z\u{BC}\u{AF}")),
    Signature(ext: "rar", begins: at(0, "Rar!")),
    Signature(ext: "gz", also: ["tgz"], begins: at(0, "\u{1F}\u{8B}")),
    Signature(ext: "ttf", begins: any(at(0, "\u{00}\u{01}\u{00}\u{00}"), at(0, "true"))),
    Signature(ext: "otf", begins: at(0, "OTTO")),
    Signature(ext: "woff", begins: at(0, "wOFF")),
    Signature(ext: "woff2", begins: at(0, "wOF2")),
    Signature(ext: "glb", begins: at(0, "glTF")),
  ]

  private static func beginning(of url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: enough)
  }

  private static func picture(in url: URL) -> UTType? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let found = CGImageSourceGetType(source) as String?,
          let type = UTType(found), type.conforms(to: .image) else { return nil }
    return type
  }

  /// Whether such a file says what it is.
  static func knows(_ ext: String) -> Bool {
    let ext = ext.lowercased()
    if let type = UTType(filenameExtension: ext), type.conforms(to: .image), !type.conforms(to: .rawImage), !type.conforms(to: .svg) { return true }
    return known.contains { $0.ext == ext || $0.also.contains(ext) }
  }

  /// Whether it is what this extension says. Nil where nothing in such a file
  /// would tell: text, and what cameras write.
  static func fits(_ url: URL, _ ext: String) -> Bool? {
    let ext = ext.lowercased()
    if let type = UTType(filenameExtension: ext), type.conforms(to: .image), !type.conforms(to: .rawImage), !type.conforms(to: .svg) {
      guard let found = picture(in: url) else { return beginning(of: url)?.isEmpty == false ? false : nil }
      return found == type || found.conforms(to: type) || type.conforms(to: found)
    }
    guard let data = beginning(of: url), !data.isEmpty else { return nil }
    if let mine = known.first(where: { $0.ext == ext || $0.also.contains(ext) }) { return mine.begins(data) }
    // Anything else says nothing, unless it plainly says something different.
    return picture(in: url) != nil || known.contains { $0.begins(data) } ? false : nil
  }

  /// The extension it ought to have, where it can be told.
  static func telling(_ url: URL) -> String? {
    if let type = picture(in: url) { return Conversions.fileExtension(of: type) }
    guard let data = beginning(of: url) else { return nil }
    return known.first { $0.begins(data) }?.ext
  }
}
