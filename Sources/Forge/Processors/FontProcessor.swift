import Compression
import CoreText
import Foundation
import UniformTypeIdentifiers

/// Fonts. The system takes one to pieces, whatever it came in; putting the
/// pieces in another box is arithmetic, and the outlines are never touched.
final class FontProcessor: FileProcessor, @unchecked Sendable {
  let name = "Font Processor"

  static let readable: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "woff", "woff2"]
  static let writable = ["ttf", "otf", "woff", "woff2"]

  static func handles(_ ext: String) -> Bool { readable.contains(ext.lowercased()) }

  func canProcess(_ file: ProcessableFile) -> Bool { Self.handles(file.url.pathExtension) }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    let source = file.url.pathExtension.lowercased(), target = Conversions.fileExtension(of: target)
    // Curves of the one sort are not curves of the other: that is drawing the font again.
    let redraws = Set([source, target]) == ["ttf", "otf"]
    return Self.writable.contains(target) && source != target && !redraws
  }

  func process(
    _ input: URL, to output: URL, with operations: [Operation], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date(), target = output.pathExtension.lowercased()
    let faces = try Self.faces(of: input)
    var written: [URL] = []
    for (index, tables) in faces.enumerated() {
      try Task.checkCancellation()
      let place = index == 0 ? output : output.numbered(index + 1, of: faces.count)
      try Self.pack(tables, as: target, from: input).write(to: place, options: .atomic)
      written.append(place)
      progress(Double(index + 1) / Double(faces.count))
    }
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    return ProcessingResult(
      outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start),
      additionalOutputs: Array(written.dropFirst())
    )
  }

  // MARK: - Taking one to pieces

  typealias Tables = [String: Data]

  static func faces(of url: URL) throws -> [Tables] {
    let data = try Data(contentsOf: url)
    let unreadable = ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is not a font macOS can read.")
    if data.prefix(4) == Data("ttcf".utf8) {
      let count = data.big(4, at: 8)
      guard (1...256).contains(count) else { throw unreadable }
      return try (0..<count).map { try tables(of: data, at: data.big(4, at: 12 + 4 * $0)) ?? { throw unreadable }() }
    }
    if let plain = tables(of: data, at: 0) { return [plain] }
    // Packed: the system unpacks it.
    if let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider), !numbers(font.tableTags).isEmpty {
      return [numbers(font.tableTags).reduce(into: Tables()) { $0[spelled($1)] = font.table(for: $1) as Data? }]
    }
    let found = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    var seen = Set<Data>()
    let faces = found.compactMap { descriptor -> Tables? in
      let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
      let tables = numbers(CTFontCopyAvailableTables(font, [])).reduce(into: Tables()) { $0[spelled($1)] = CTFontCopyTable(font, $1, []) as Data? }
      // A font that varies is named once for every way it does.
      guard let head = tables["head"], seen.insert(head + (tables["name"] ?? Data())).inserted else { return nil }
      return tables
    }
    guard !faces.isEmpty else { throw unreadable }
    return faces
  }

  /// The array holds numbers where an array holds objects.
  private static func numbers(_ tags: CFArray?) -> [UInt32] {
    guard let tags else { return [] }
    return (0..<CFArrayGetCount(tags)).map { UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tags, $0))) }
  }

  private static func spelled(_ tag: UInt32) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: tag >> $0) }, as: UTF8.self)
  }

  private static func tables(of data: Data, at offset: Int) -> Tables? {
    let kind = data.big(4, at: offset)
    guard [0x0001_0000, 0x4F54_544F, 0x7472_7565].contains(kind) else { return nil }
    var tables: Tables = [:]
    for index in 0..<data.big(2, at: offset + 4) {
      let entry = offset + 12 + 16 * index
      let start = data.big(4, at: entry + 8), length = data.big(4, at: entry + 12)
      guard entry + 16 <= data.count, start + length <= data.count else { return nil }
      tables[String(decoding: data[entry..<(entry + 4)], as: UTF8.self)] = data.subdata(in: start..<(start + length))
    }
    return tables["head"] == nil ? nil : tables
  }

  // MARK: - Putting it in another box

  static func pack(_ all: Tables, as target: String, from input: URL) throws -> Data {
    let isPostScript = all["CFF "] != nil || all["CFF2"] != nil
    if target == "ttf", isPostScript {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has PostScript outlines, which go in an OTF.")
    }
    var tables = all
    // A signature is of the file it was in.
    tables["DSIG"] = nil
    switch target {
    case "woff2":
      // It says of itself that it was packed and is otherwise as it was.
      if var head = tables["head"], head.count >= 18 {
        head[head.startIndex + 16] |= 0x08
        tables["head"] = head
      }
      return try woff2(summed(tables), isPostScript)
    case "woff": return woff(summed(tables), isPostScript)
    default: return plain(summed(tables), isPostScript)
    }
  }

  private static func flavour(_ isPostScript: Bool) -> Int { isPostScript ? 0x4F54_544F : 0x0001_0000 }

  private static func sum(_ data: Data) -> Int {
    stride(from: 0, to: data.count, by: 4).reduce(0) { total, at in
      let word = (0..<4).reduce(0) { $0 << 8 | (at + $1 < data.count ? Int(data[data.startIndex + at + $1]) : 0) }
      return (total + word) & 0xFFFF_FFFF
    }
  }

  private static func padded(_ data: Data) -> Data { data + Data(count: (4 - data.count % 4) % 4) }

  /// With the sum of the whole written in it, worked out with nothing there.
  private static func summed(_ tables: Tables) -> Tables {
    guard let head = tables["head"], head.count >= 12 else { return tables }
    var tables = tables
    var blank = Data(head)
    blank.replaceSubrange(8..<12, with: Data(count: 4))
    tables["head"] = blank
    let whole = sum(plain(tables, tables["CFF "] != nil || tables["CFF2"] != nil))
    var number = Data()
    number.append(big: (0xB1B0_AFBA - whole) & 0xFFFF_FFFF, 4)
    blank.replaceSubrange(8..<12, with: number)
    tables["head"] = blank
    return tables
  }

  /// The table's own sum leaves out the sum of the whole.
  private static func sum(of tag: String, _ data: Data) -> Int {
    guard tag == "head", data.count >= 12 else { return sum(data) }
    var blank = Data(data)
    blank.replaceSubrange(8..<12, with: Data(count: 4))
    return sum(blank)
  }

  private static func plain(_ tables: Tables, _ isPostScript: Bool) -> Data {
    let tags = tables.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    var power = 0
    while 2 << power <= tags.count { power += 1 }
    var out = Data(), body = Data()
    out.append(big: flavour(isPostScript), 4)
    out.append(big: tags.count, 2)
    out.append(big: 16 << power, 2); out.append(big: power, 2); out.append(big: tags.count * 16 - 16 << power, 2)
    let start = 12 + 16 * tags.count
    for tag in tags {
      let table = tables[tag]!
      out.append(Data(tag.utf8))
      out.append(big: sum(of: tag, table), 4); out.append(big: start + body.count, 4); out.append(big: table.count, 4)
      body.append(padded(table))
    }
    return out + body
  }

  private static func woff(_ tables: Tables, _ isPostScript: Bool) -> Data {
    let tags = tables.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    var list = Data(), body = Data()
    let start = 44 + 20 * tags.count
    for tag in tags {
      let table = tables[tag]!
      var packed = table
      if let squeezed = table.packed(COMPRESSION_ZLIB) {
        var wrapped = Data([0x78, 0x9C]) + squeezed
        wrapped.append(big: table.adler32, 4)
        if wrapped.count < table.count { packed = wrapped }
      }
      list.append(Data(tag.utf8))
      list.append(big: start + body.count, 4); list.append(big: packed.count, 4); list.append(big: table.count, 4)
      list.append(big: sum(of: tag, table), 4)
      body.append(padded(packed))
    }
    var out = Data("wOFF".utf8)
    out.append(big: flavour(isPostScript), 4); out.append(big: start + body.count, 4)
    out.append(big: tags.count, 2); out.append(big: 0, 2); out.append(big: plainSize(tables), 4)
    out.append(big: 1, 2); out.append(big: 0, 2); out.append(Data(count: 20))
    return out + list + body
  }

  private static func plainSize(_ tables: Tables) -> Int { 12 + tables.values.reduce(0) { $0 + 16 + padded($1).count } }

  /// The tags WOFF2 has a number for, in its order.
  private static let numbered = [
    "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
    "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
    "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
    "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
  ]

  private static func woff2(_ tables: Tables, _ isPostScript: Bool) throws -> Data {
    // The outlines, and where each begins straight after.
    let rest = tables.keys.filter { $0 != "loca" }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    let tags = rest.flatMap { $0 == "glyf" && tables["loca"] != nil ? ["glyf", "loca"] : [$0] }
    var list = Data(), body = Data()
    for tag in tags {
      let table = tables[tag]!
      let number = numbered.firstIndex(of: tag) ?? 63
      // Three says the outlines were left as they are.
      list.append(UInt8(number | (tag == "glyf" || tag == "loca" ? 0xC0 : 0)))
      if number == 63 { list.append(Data(tag.utf8)) }
      list.append(sevens(table.count))
      body.append(table)
    }
    guard let packed = body.packed(COMPRESSION_BROTLI) else {
      throw ProcessingError.conversionFailed(reason: "This Mac cannot pack a WOFF2.")
    }
    var out = Data("wOF2".utf8)
    out.append(big: flavour(isPostScript), 4)
    out.append(big: (48 + list.count + packed.count + 3) / 4 * 4, 4)
    out.append(big: tags.count, 2); out.append(big: 0, 2); out.append(big: plainSize(tables), 4); out.append(big: packed.count, 4)
    out.append(big: 1, 2); out.append(big: 0, 2); out.append(Data(count: 20))
    // macOS refuses one that does not end on a fourth byte.
    return padded(out + list + packed)
  }

  /// Seven bits at a time, the last without its top bit.
  private static func sevens(_ number: Int) -> Data {
    var bytes = [UInt8(number & 0x7F)], left = number >> 7
    while left > 0 {
      bytes.insert(UInt8(left & 0x7F) | 0x80, at: 0)
      left >>= 7
    }
    return Data(bytes)
  }
}
