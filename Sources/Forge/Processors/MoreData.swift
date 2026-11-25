import Compression
import Foundation

/// The data other programs keep to themselves: packed records, old databases,
/// palettes, words for translators.
enum MoreData {
  static let texts: [String: DataFormats.Written] = [
    "json5": DataFormats.Written(read: loose), "jsonc": DataFormats.Written(read: loose),
    "properties": DataFormats.Written(read: pairs, write: properties), "env": DataFormats.Written(read: pairs, write: environment),
    "po": DataFormats.Written(read: phrases, write: phrases), "xliff": DataFormats.Written(read: units), "xlf": DataFormats.Written(read: units),
    "xmp": DataFormats.Written(read: Xml.read), "tcx": DataFormats.Written(read: Geo.tcx),
    "gpl": DataFormats.Written(read: Palette.gimp, write: Palette.gimp),
  ]

  static let packs: [String: DataFormats.Packed] = [
    "xlsm": DataFormats.Packed(read: Xlsx.read), "xltx": DataFormats.Packed(read: Xlsx.read), "xltm": DataFormats.Packed(read: Xlsx.read),
    "xls": DataFormats.Packed(read: Xls.read), "xlt": DataFormats.Packed(read: Xls.read),
    "msgpack": DataFormats.Packed(read: { try MessagePack.read(Data(contentsOf: $0)) }, write: MessagePack.write),
    "cbor": DataFormats.Packed(read: { try Cbor.read(Data(contentsOf: $0)) }, write: Cbor.write),
    "dbf": DataFormats.Packed(read: { try Dbf.read(Data(contentsOf: $0)) }),
    "ase": DataFormats.Packed(read: { try Palette.adobe(Data(contentsOf: $0)) }, write: Palette.adobe),
    "aco": DataFormats.Packed(read: { try Palette.swatches(Data(contentsOf: $0)) }),
    "lrcat": DataFormats.Packed(read: Sqlite.read),
    "prproj": DataFormats.Packed(read: { try Xml.read(String(decoding: Gzip.unpacked(Data(contentsOf: $0)), as: UTF8.self)) }),
  ]

  /// JSON the way people write it, with what they say beside it.
  @Sendable static func loose(_ text: String) throws -> Any {
    guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed, .fragmentsAllowed]) else { throw DataFormats.broken("JSON") }
    return value
  }

  @Sendable static func pairs(_ text: String) throws -> Any {
    var all: [String: Any] = [:]
    for raw in text.replacingOccurrences(of: "\\\n", with: "").split(whereSeparator: \.isNewline) {
      var line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
      if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
      guard let cut = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { throw DataFormats.broken("a list of settings") }
      var value = line[line.index(after: cut)...].trimmingCharacters(in: .whitespaces)
      if value.count > 1, let quote = value.first, quote == "\"" || quote == "'", value.last == quote { value = String(value.dropFirst().dropLast()) }
      all[line[..<cut].trimmingCharacters(in: .whitespaces)] = value.replacingOccurrences(of: "\\n", with: "\n")
    }
    guard !all.isEmpty else { throw DataFormats.broken("a list of settings") }
    return all
  }

  /// One level: what is inside something is named after it.
  private static func flat(_ value: Any, _ joint: String) throws -> [(String, String)] {
    guard let record = DataFormats.plain(value) as? [String: Any] else { throw ProcessingError.conversionFailed(reason: "Only a record can become a list of settings. This file is not one.") }
    return record.sorted { $0.key < $1.key }.flatMap { key, inside -> [(String, String)] in
      if let more = inside as? [String: Any], let deep = try? flat(more, joint) { return deep.map { (key + joint + $0.0, $0.1) } }
      return [(key, Separated.describe(inside))]
    }
  }

  @Sendable static func properties(_ value: Any) throws -> String {
    try flat(value, ".").map { "\($0.0.replacingOccurrences(of: " ", with: "\\ ")) = \($0.1.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n"))\n" }.joined()
  }

  @Sendable static func environment(_ value: Any) throws -> String {
    try flat(value, "_").map { key, value in
      let name = key.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
      let safe = value.wholeMatch(of: #/[A-Za-z0-9_.\/:@%+,-]*/#) != nil
      return String(name) + "=" + (safe ? value : "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "\n", with: "\\n") + "\"") + "\n"
    }.joined()
  }

  // MARK: - Translations

  @Sendable static func phrases(_ text: String) throws -> Any {
    func said(_ line: String) -> String {
      guard let from = line.firstIndex(of: "\""), let to = line.lastIndex(of: "\""), from < to else { return "" }
      return line[line.index(after: from)..<to].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
    var rows: [[String: String]] = [], row: [String: String] = [:], field = ""
    func end() { if let id = row["source"], !id.isEmpty { rows.append(row) }; row = [:] }
    for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.hasPrefix("#") {
      if line.hasPrefix("msgctxt") { end(); field = "context"; row[field] = said(line) } else if line.hasPrefix("msgid_plural") { field = "plural"; row[field] = said(line) }
      else if line.hasPrefix("msgid") { if row["source"] != nil { end() }; field = "source"; row[field] = said(line) }
      else if line.hasPrefix("msgstr") { field = line.hasPrefix("msgstr[") && !line.hasPrefix("msgstr[0]") ? "translation " + line.filter(\.isNumber).prefix(1) : "translation"; row[field] = said(line) }
      else if line.hasPrefix("\""), !field.isEmpty { row[field, default: ""] += said(line) }
    }
    end()
    guard !rows.isEmpty else { throw DataFormats.broken("a PO file") }
    let columns = ["context", "source", "plural", "translation", "translation 1", "translation 2"].filter { column in rows.contains { $0[column] != nil } }
    return Separated.Table(columns: columns, rows: rows)
  }

  @Sendable static func phrases(_ value: Any) throws -> String {
    func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\"" }
    let rows = try DataFormats.someTables(in: value).flatMap(\.table.rows)
    return try "msgid \"\"\nmsgstr \"Content-Type: text/plain; charset=UTF-8\\n\"\n" + rows.map { row in
      guard let source = row["source"] else { throw ProcessingError.conversionFailed(reason: "A PO file needs a column called “source”, and one called “translation”.") }
      return "\n" + (row["context"].map { "msgctxt \(quoted($0))\n" } ?? "") + "msgid \(quoted(source))\nmsgstr \(quoted(row["translation"] ?? ""))\n"
    }.joined()
  }

  @Sendable static func units(_ text: String) throws -> Any {
    guard let root = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]).rootElement() else { throw DataFormats.broken("an XLIFF file") }
    var rows: [[String: String]] = []
    func walk(_ element: XMLElement, _ id: String) {
      let inside = (element.children ?? []).compactMap { $0 as? XMLElement }
      if let source = inside.first(where: { $0.localName == "source" }) {
        rows.append(["id": element.attribute(forName: "id")?.stringValue ?? id, "source": source.stringValue ?? "", "translation": inside.first { $0.localName == "target" }?.stringValue ?? ""])
      } else { for child in inside { walk(child, element.attribute(forName: "id")?.stringValue ?? id) } }
    }
    walk(root, "")
    guard !rows.isEmpty else { throw DataFormats.broken("an XLIFF file") }
    return Separated.Table(columns: ["id", "source", "translation"], rows: rows)
  }
}

enum Gzip {
  /// One file, squeezed. What it says it comes to is at the end.
  static func unpacked(_ data: Data) throws -> Data {
    guard data.count > 18, data.prefix(2) == Data([0x1F, 0x8B]) else { throw Zip.Reader.broken }
    let flags = data.number(1, at: 3), size = data.number(4, at: data.count - 4)
    var at = 10
    if flags & 4 != 0 { at += 2 + data.number(2, at: at) }
    for bit in [8, 16] where flags & bit != 0 {
      while at < data.count, data.number(1, at: at) != 0 { at += 1 }
      at += 1
    }
    if flags & 2 != 0 { at += 2 }
    guard at < data.count - 8, size <= Zip.largest else { throw Zip.Reader.broken }
    return try data.subdata(in: at..<(data.count - 8)).unpacked(to: size, COMPRESSION_ZLIB)
  }
}

// MARK: - Packed records

private struct Cursor {
  let data: Data
  var at = 0
  init(_ data: Data) { self.data = Data(data) }
  mutating func number(_ size: Int) throws -> Int {
    guard at + size <= data.count else { throw Zip.Reader.broken }
    defer { at += size }
    return data.big(size, at: at)
  }
  mutating func bytes(_ count: Int) throws -> Data {
    guard count >= 0, at + count <= data.count else { throw Zip.Reader.broken }
    defer { at += count }
    return data.subdata(in: at..<(at + count))
  }
  mutating func text(_ count: Int) throws -> String { String(decoding: try bytes(count), as: UTF8.self) }
}

enum MessagePack {
  @Sendable static func read(_ data: Data) throws -> Any {
    var cursor = Cursor(data)
    let value = try value(&cursor, 0)
    guard cursor.at == data.count else { throw Zip.Reader.broken }
    return value
  }

  private static func signed(_ raw: Int, _ size: Int) -> Int { size < 8 && raw >> (size * 8 - 1) == 1 ? raw - 1 << (size * 8) : raw }

  private static func value(_ c: inout Cursor, _ depth: Int) throws -> Any {
    guard depth < 256 else { throw Zip.Reader.broken }
    func list(_ count: Int, _ c: inout Cursor) throws -> [Any] {
      var out: [Any] = []
      for _ in 0..<count { out.append(try value(&c, depth + 1)) }
      return out
    }
    func record(_ count: Int, _ c: inout Cursor) throws -> [String: Any] {
      var out: [String: Any] = [:]
      for _ in 0..<count { let key = Separated.describe(try value(&c, depth + 1)); out[key] = try value(&c, depth + 1) }
      return out
    }
    let kind = try c.number(1)
    switch kind {
    case 0x00...0x7F: return kind
    case 0x80...0x8F: return try record(kind & 15, &c)
    case 0x90...0x9F: return try list(kind & 15, &c)
    case 0xA0...0xBF: return try c.text(kind & 31)
    case 0xC0: return NSNull()
    case 0xC2: return false
    case 0xC3: return true
    case 0xC4...0xC6: return try c.bytes(try c.number(1 << (kind - 0xC4)))
    case 0xC7...0xC9: let size = try c.number(1 << (kind - 0xC7)); _ = try c.number(1); return try c.bytes(size)
    case 0xCA: return Double(Float(bitPattern: UInt32(try c.number(4))))
    case 0xCB: return Double(bitPattern: UInt64(bitPattern: Int64(try c.number(8))))
    case 0xCC...0xCF: let raw = try c.number(1 << (kind - 0xCC)); return raw < 0 ? NSNumber(value: UInt64(bitPattern: Int64(raw))) : raw
    case 0xD0...0xD3: return signed(try c.number(1 << (kind - 0xD0)), 1 << (kind - 0xD0))
    case 0xD4...0xD8: _ = try c.number(1); return try c.bytes(1 << (kind - 0xD4))
    case 0xD9...0xDB: return try c.text(try c.number(1 << (kind - 0xD9)))
    case 0xDC, 0xDD: return try list(try c.number(kind == 0xDC ? 2 : 4), &c)
    case 0xDE, 0xDF: return try record(try c.number(kind == 0xDE ? 2 : 4), &c)
    case 0xE0...0xFF: return kind - 256
    default: throw Zip.Reader.broken
    }
  }

  @Sendable static func write(_ value: Any) throws -> Data {
    var out = Data()
    put(try DataProcessor.jsonSafe(DataFormats.plain(value)), &out)
    return out
  }

  private static func put(_ value: Any, _ out: inout Data) {
    func head(_ count: Int, _ small: Int, _ most: Int, _ codes: [(Int, Int)]) {
      if count <= most { out.append(UInt8(small | count)); return }
      let (code, size) = codes.first { count < 1 << ($0.1 * 8) } ?? codes[codes.count - 1]
      out.append(UInt8(code))
      out.append(big: count, size)
    }
    switch value {
    case is NSNull: out.append(0xC0)
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): out.append(number.boolValue ? 0xC3 : 0xC2)
    case let number as NSNumber:
      if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 9e18, !CFNumberIsFloatType(number) || number is NSDecimalNumber {
        let whole = number.int64Value
        if (0...127).contains(whole) { out.append(UInt8(whole)) } else { out.append(0xD3); out.append(big: Int(whole), 8) }
      } else { out.append(0xCB); out.append(big: Int(Int64(bitPattern: number.doubleValue.bitPattern)), 8) }
    case let text as String:
      let bytes = Data(text.utf8)
      head(bytes.count, 0xA0, 31, [(0xD9, 1), (0xDA, 2), (0xDB, 4)])
      out.append(bytes)
    case let list as [Any]:
      head(list.count, 0x90, 15, [(0xDC, 2), (0xDD, 4)])
      for one in list { put(one, &out) }
    case let record as [String: Any]:
      head(record.count, 0x80, 15, [(0xDE, 2), (0xDF, 4)])
      for (key, inside) in record.sorted(by: { $0.key < $1.key }) { put(key, &out); put(inside, &out) }
    default: put(String(describing: value), &out)
    }
  }
}

enum Cbor {
  @Sendable static func read(_ data: Data) throws -> Any {
    var cursor = Cursor(data)
    guard let value = try value(&cursor, 0), cursor.at == data.count else { throw Zip.Reader.broken }
    return value
  }

  /// - Returns: nothing at the end of a list that did not say how long it was.
  private static func value(_ c: inout Cursor, _ depth: Int) throws -> Any? {
    guard depth < 256 else { throw Zip.Reader.broken }
    let first = try c.number(1), kind = first >> 5, short = first & 31
    if first == 0xFF { return nil }
    let count: Int?
    switch short {
    case 0...23: count = short
    case 24...27: count = try c.number(1 << (short - 24))
    case 31: count = nil
    default: throw Zip.Reader.broken
    }
    switch kind {
    case 0: guard let count else { throw Zip.Reader.broken }; return count < 0 ? NSNumber(value: UInt64(bitPattern: Int64(count))) : count
    case 1: guard let count, count >= 0 else { throw Zip.Reader.broken }; return -1 - count
    case 2, 3:
      var bytes = Data()
      if let count { bytes = try c.bytes(count) } else {
        while let piece = try value(&c, depth + 1) { bytes.append((piece as? Data) ?? Data(((piece as? String) ?? "").utf8)) }
      }
      return kind == 2 ? bytes : String(decoding: bytes, as: UTF8.self)
    case 4:
      var out: [Any] = []
      while count.map({ out.count < $0 }) ?? true { guard let one = try value(&c, depth + 1) else { break }; out.append(one) }
      return out
    case 5:
      var out: [String: Any] = [:], done = 0
      while count.map({ done < $0 }) ?? true {
        guard let key = try value(&c, depth + 1), let inside = try value(&c, depth + 1) else { break }
        out[Separated.describe(key)] = inside
        done += 1
      }
      return out
    case 6: return try value(&c, depth + 1)
    default:
      switch short {
      case 20: return false
      case 21: return true
      case 25:
        let raw = count ?? 0, sign = raw >> 15 == 1 ? -1.0 : 1.0, power = raw >> 10 & 31, part = Double(raw & 1023)
        return sign * (power == 0 ? part * pow(2, -24) : power == 31 ? (part == 0 ? .infinity : .nan) : (1 + part / 1024) * pow(2, Double(power - 15)))
      case 26: return Double(Float(bitPattern: UInt32(count ?? 0)))
      case 27: return Double(bitPattern: UInt64(bitPattern: Int64(count ?? 0)))
      default: return NSNull()
      }
    }
  }

  @Sendable static func write(_ value: Any) throws -> Data {
    var out = Data()
    put(try DataProcessor.jsonSafe(DataFormats.plain(value)), &out)
    return out
  }

  private static func put(_ value: Any, _ out: inout Data) {
    func head(_ kind: Int, _ count: Int) {
      if count < 24 { out.append(UInt8(kind << 5 | count)); return }
      let power = count < 1 << 8 ? 0 : count < 1 << 16 ? 1 : count < 1 << 32 ? 2 : 3
      out.append(UInt8(kind << 5 | (24 + power)))
      out.append(big: count, 1 << power)
    }
    switch value {
    case is NSNull: out.append(0xF6)
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): out.append(number.boolValue ? 0xF5 : 0xF4)
    case let number as NSNumber:
      if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 9e18, !CFNumberIsFloatType(number) || number is NSDecimalNumber {
        let whole = Int(number.int64Value)
        if whole >= 0 { head(0, whole) } else { head(1, -1 - whole) }
      } else { out.append(0xFB); out.append(big: Int(Int64(bitPattern: number.doubleValue.bitPattern)), 8) }
    case let text as String: let bytes = Data(text.utf8); head(3, bytes.count); out.append(bytes)
    case let list as [Any]: head(4, list.count); for one in list { put(one, &out) }
    case let record as [String: Any]:
      head(5, record.count)
      for (key, inside) in record.sorted(by: { $0.key < $1.key }) { put(key, &out); put(inside, &out) }
    default: put(String(describing: value), &out)
    }
  }
}

// MARK: - dBase

enum Dbf {
  @Sendable static func read(_ data: Data) throws -> Any {
    let count = data.number(4, at: 4), start = data.number(2, at: 8), size = data.number(2, at: 10)
    guard data.count > 64, [0x02, 0x03, 0x30, 0x31, 0x32, 0x43, 0x63, 0x83, 0x8B, 0xF5, 0xFB].contains(data.number(1, at: 0)), start > 32, size > 1 else { throw DataFormats.broken("a dBase table") }
    var fields: [(name: String, kind: Character, length: Int)] = [], at = 32
    while at + 32 <= start, data.number(1, at: at) != 0x0D {
      let name = String(decoding: data[(data.startIndex + at)..<(data.startIndex + at + 11)].prefix { $0 != 0 }, as: UTF8.self)
      fields.append((name, Character(UnicodeScalar(UInt8(data.number(1, at: at + 11)))), data.number(1, at: at + 16)))
      at += 32
    }
    guard !fields.isEmpty, fields.reduce(1, { $0 + $1.length }) <= size else { throw DataFormats.broken("a dBase table") }
    var rows: [[String]] = [fields.map(\.name)]
    for index in 0..<min(count, (data.count - start) / size) {
      var place = start + index * size
      // Crossed out, and not yet taken away.
      if data.number(1, at: place) == 0x2A { continue }
      place += 1
      rows.append(fields.map { field in
        defer { place += field.length }
        let raw = data.subdata(in: (data.startIndex + place)..<(data.startIndex + place + field.length))
        if field.kind == "I", field.length == 4 { return "\(Int32(truncatingIfNeeded: raw.number(4, at: 0)))" }
        let text = (String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .windowsCP1252) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if field.kind == "D", text.count == 8 { return "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))" }
        if field.kind == "L" { return "TtYy".contains(text) && !text.isEmpty ? "true" : "FfNn".contains(text) && !text.isEmpty ? "false" : "" }
        return text
      })
    }
    return Separated.table(of: rows)
  }
}

// MARK: - Palettes

enum Palette {
  private static func table(_ colours: [(name: String, r: Double, g: Double, b: Double)]) throws -> Any {
    guard !colours.isEmpty else { throw DataFormats.broken("a palette") }
    return Separated.Table(columns: ["name", "hex"], rows: colours.map { one in
      ["name": one.name, "hex": "#" + [one.r, one.g, one.b].map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()]
    })
  }

  private static func cmyk(_ c: [Double]) -> (Double, Double, Double) { ((1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])) }

  private static func lab(_ l: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
    let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
    func back(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16 / 116) / 7.787 }
    let x = back(fx) * 0.9642, y = back(fy), z = back(fz) * 0.8249
    func screen(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    return (screen(3.1339 * x - 1.6169 * y - 0.4906 * z), screen(-0.9788 * x + 1.9161 * y + 0.0335 * z), screen(0.0719 * x - 0.2290 * y + 1.4052 * z))
  }

  private static func colours(_ value: Any) throws -> [(name: String, rgb: [Double])] {
    let found = try DataFormats.someTables(in: value).flatMap(\.table.rows).compactMap { row -> (String, [Double])? in
      let row = Dictionary(row.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
      let digits = (row["hex"] ?? row["color"] ?? row["colour"] ?? "").filter(\.isHexDigit)
      guard digits.count == 6, let number = Int(digits, radix: 16) else { return nil }
      return (row["name"] ?? "#" + digits, [16, 8, 0].map { Double(number >> $0 & 255) / 255 })
    }
    guard !found.isEmpty else { throw ProcessingError.conversionFailed(reason: "A palette needs a column called “hex”, with colors such as #FF8800.") }
    return found
  }

  /// Adobe Swatch Exchange.
  @Sendable static func adobe(_ data: Data) throws -> Any {
    guard data.prefix(4) == Data("ASEF".utf8) else { throw DataFormats.broken("a palette") }
    var found: [(name: String, r: Double, g: Double, b: Double)] = [], at = 12
    while at + 6 <= data.count {
      let kind = data.big(2, at: at), size = data.big(4, at: at + 2), end = at + 6 + size
      guard end <= data.count else { break }
      if kind == 1 {
        let length = data.big(2, at: at + 6), name = String(decoding: (0..<max(0, length - 1)).map { UInt16(data.big(2, at: at + 8 + 2 * $0)) }, as: UTF16.self)
        let place = at + 8 + length * 2
        func float(_ index: Int) -> Double { Double(Float(bitPattern: UInt32(data.big(4, at: place + 4 + 4 * index)))) }
        let model = String(decoding: data.subdata(in: min(place, end)..<min(place + 4, end)), as: UTF8.self), rgb: (Double, Double, Double)
        switch model {
        case "RGB ": rgb = (float(0), float(1), float(2))
        case "CMYK": rgb = cmyk((0..<4).map(float))
        case "LAB ": rgb = lab(float(0) * 100, float(1), float(2))
        default: rgb = (float(0), float(0), float(0))
        }
        found.append((name, rgb.0, rgb.1, rgb.2))
      }
      at = end
    }
    return try table(found)
  }

  @Sendable static func adobe(_ value: Any) throws -> Data {
    let all = try colours(value)
    var out = Data("ASEF".utf8)
    out.append(big: 0x0001_0000, 4); out.append(big: all.count, 4)
    for one in all {
      var block = Data()
      let name = Array(one.name.utf16) + [0]
      block.append(big: name.count, 2)
      for unit in name { block.append(big: Int(unit), 2) }
      block.append(Data("RGB ".utf8))
      for part in one.rgb { block.append(big: Int(Float(part).bitPattern), 4) }
      block.append(big: 2, 2)
      out.append(big: 1, 2); out.append(big: block.count, 4); out.append(block)
    }
    return out
  }

  /// Photoshop's: the second half has the names.
  @Sendable static func swatches(_ data: Data) throws -> Any {
    let count = data.big(2, at: 2)
    let second = 4 + count * 10, hasNames = data.big(2, at: second) == 2 && data.count > second + 4
    var found: [(name: String, r: Double, g: Double, b: Double)] = [], at = hasNames ? second + 4 : 4
    guard data.count >= second, count > 0, data.big(2, at: 0) == 1 || data.big(2, at: 0) == 2 else { throw DataFormats.broken("a palette") }
    for index in 0..<count where at + 10 <= data.count {
      let space = data.big(2, at: at), w = (0..<4).map { Double(data.big(2, at: at + 2 + 2 * $0)) }, rgb: (Double, Double, Double)
      switch space {
      case 1: rgb = hsb(w[0] / 65_535, w[1] / 65_535, w[2] / 65_535)
      case 2: rgb = cmyk(w.map { 1 - $0 / 65_535 })
      case 7:
        func signed(_ v: Double) -> Double { v > 32_767 ? v - 65_536 : v }
        rgb = lab(w[0] / 100, signed(w[1]) / 100, signed(w[2]) / 100)
      case 8: rgb = (1 - w[0] / 10_000, 1 - w[0] / 10_000, 1 - w[0] / 10_000)
      default: rgb = (w[0] / 65_535, w[1] / 65_535, w[2] / 65_535)
      }
      at += 10
      var name = "Color \(index + 1)"
      if hasNames {
        let length = data.big(4, at: at)
        guard length < 4096, at + 4 + length * 2 <= data.count else { break }
        name = String(decoding: (0..<max(0, length - 1)).map { UInt16(data.big(2, at: at + 4 + 2 * $0)) }, as: UTF16.self)
        at += 4 + length * 2
      }
      found.append((name, rgb.0, rgb.1, rgb.2))
    }
    return try table(found)
  }

  private static func hsb(_ h: Double, _ s: Double, _ b: Double) -> (Double, Double, Double) {
    func part(_ n: Double) -> Double { let k = (n + h * 6).truncatingRemainder(dividingBy: 6); return b - b * s * max(0, min(k, 4 - k, 1)) }
    return (part(5), part(3), part(1))
  }

  @Sendable static func gimp(_ text: String) throws -> Any {
    guard text.hasPrefix("GIMP Palette") else { throw DataFormats.broken("a palette") }
    return try table(text.split(whereSeparator: \.isNewline).compactMap { line in
      guard let match = line.wholeMatch(of: #/\s*(\d+)\s+(\d+)\s+(\d+)\s*(.*)/#), let r = Double(match.1), let g = Double(match.2), let b = Double(match.3) else { return nil }
      return (String(match.4), r / 255, g / 255, b / 255)
    })
  }

  @Sendable static func gimp(_ value: Any) throws -> String {
    try "GIMP Palette\nName: Forge\n#\n" + colours(value).map { one in one.rgb.map { String(format: "%3d", Int(($0 * 255).rounded())) }.joined(separator: " ") + "\t\(one.name)\n" }.joined()
  }
}
