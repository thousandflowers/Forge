import Foundation

/// The data formats Forge reads and writes itself, by extension, each into the
/// same few shapes: a record, a list, a table, or a book of tables.
enum DataFormats {
  struct Written {
    var read: (@Sendable (String) throws -> Any)?
    var write: (@Sendable (Any) throws -> String)?
  }

  struct Packed {
    var read: (@Sendable (URL) throws -> Any)?
    var write: (@Sendable (Any) throws -> Data)?
  }

  /// Several tables under one roof, in order.
  struct Book { let sheets: [(name: String, table: Separated.Table)] }

  static let texts: [String: Written] = {
    let lines = Written(read: Lines.read, write: Lines.write), yaml = Written(read: Yaml.read, write: Yaml.write)
    return [
      "jsonl": lines, "ndjson": lines, "yaml": yaml, "yml": yaml,
      "ini": Written(read: Ini.read, write: Ini.write),
      "strings": Written(read: Strings.read, write: Strings.write),
      "xml": Written(read: Xml.read, write: Xml.write),
      "geojson": Written(read: { try JSONSerialization.jsonObject(with: Data($0.utf8)) }, write: Geo.geoJSON),
      "gpx": Written(read: Geo.gpx, write: Geo.gpx),
      "kml": Written(read: Geo.kml, write: Geo.kml),
      "vcf": Written(read: Cards.people, write: Cards.people), "vcard": Written(read: Cards.people, write: Cards.people),
      "ics": Written(read: Cards.events, write: Cards.events),
      "html": Written(write: Pages.html),
      "md": Written(write: Pages.markdown),
      "sql": Written(write: Pages.sql),
    ]
  }()

  static let packs: [String: Packed] = [
    "xlsx": Packed(read: Xlsx.read, write: Xlsx.write),
    "ods": Packed(read: Ods.read, write: Ods.write),
    "sqlite": Packed(read: Sqlite.read), "sqlite3": Packed(read: Sqlite.read), "db": Packed(read: Sqlite.read),
    "kmz": Packed(read: Geo.kmz, write: Geo.kmz),
  ]

  /// A page is written from data and is not data: reading one is reading words.
  private static let pages: Set<String> = ["html", "md"]
  static let written = Set(texts.keys).subtracting(pages)
  static let binary = Set(packs.keys)

  static func reads(_ ext: String) -> Bool {
    let ext = ext.lowercased()
    return texts[ext]?.read != nil || packs[ext]?.read != nil
  }

  static func writes(_ ext: String) -> Bool {
    let ext = ext.lowercased()
    return texts[ext]?.write != nil || packs[ext]?.write != nil
  }

  static func read(_ url: URL) throws -> Any {
    let ext = url.pathExtension.lowercased()
    if let read = packs[ext]?.read { return try read(url) }
    guard let read = texts[ext]?.read else { throw ProcessingError.unknownType }
    return try read(try DocumentText.text(in: url))
  }

  static func data(_ value: Any, as ext: String) throws -> Data {
    let ext = ext.lowercased()
    if let write = packs[ext]?.write { return try write(value) }
    guard let write = texts[ext]?.write else { throw ProcessingError.unknownType }
    return Data(try write(value).utf8)
  }

  // MARK: - Shapes

  /// The tables as the lists of records everything else knows.
  static func plain(_ value: Any) -> Any {
    switch value {
    case let table as Separated.Table: return table.rows
    case let book as Book:
      return Dictionary(book.sheets.map { ($0.name, $0.table.rows as Any) }, uniquingKeysWith: { first, _ in first })
    default: return value
    }
  }

  /// - Returns: every table there is in it, or nothing where it is no table.
  static func tables(in value: Any) -> [(name: String, table: Separated.Table)]? {
    switch value {
    case let table as Separated.Table: return [("Sheet1", table)]
    case let book as Book: return book.sheets
    case let record as [String: Any] where record["type"] as? String == "FeatureCollection":
      return [("Places", Geo.table(of: record))]
    case let rows as [[String: Any]]:
      var columns: [String] = []
      for row in rows { for key in row.keys.sorted() where !columns.contains(key) { columns.append(key) } }
      return [("Sheet1", Separated.Table(columns: columns, rows: rows.map { $0.mapValues(Separated.describe) }))]
    case let record as [String: [[String: Any]]]:
      return record.sorted { $0.key < $1.key }.flatMap { name, rows in (tables(in: rows) ?? []).map { (name, $0.table) } }
    default: return nil
    }
  }

  static func someTables(in value: Any) throws -> [(name: String, table: Separated.Table)] {
    guard let found = tables(in: value) else {
      throw ProcessingError.conversionFailed(reason: "Only a list of flat records can become a table. This file is not one.")
    }
    return found
  }

  static func escaped(_ text: String) -> String {
    let safe = text.unicodeScalars.filter { $0.value >= 32 || "\t\n\r".unicodeScalars.contains($0) }
    return String(String.UnicodeScalarView(safe)).replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  static func broken(_ what: String) -> ProcessingError { .conversionFailed(reason: "This file is not \(what) Forge can read.") }
}

// MARK: - One record a line

private enum Lines {
  @Sendable static func read(_ text: String) throws -> Any {
    let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
    guard !lines.isEmpty else { throw DataFormats.broken("JSON Lines") }
    return try lines.enumerated().map { index, line -> Any in
      guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed) else {
        throw ProcessingError.conversionFailed(reason: "Line \(index + 1) is not JSON.")
      }
      return value
    }
  }

  @Sendable static func write(_ value: Any) throws -> String {
    let plain = DataFormats.plain(value)
    let list = plain as? [Any] ?? [plain]
    return try list.map { item in
      let data = try JSONSerialization.data(withJSONObject: try DataProcessor.jsonSafe(item), options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
      return String(decoding: data, as: UTF8.self) + "\n"
    }.joined()
  }
}

// MARK: - Settings files

private enum Ini {
  @Sendable static func read(_ text: String) throws -> Any {
    var all: [String: Any] = [:], section: String?
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
      if line.hasPrefix("["), line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast())
        all[section!] = all[section!] ?? [String: Any]()
        continue
      }
      guard let equals = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { throw DataFormats.broken("an INI file") }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.count > 1, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
      if let section {
        var inside = all[section] as? [String: Any] ?? [:]
        inside[key] = value
        all[section] = inside
      } else {
        all[key] = value
      }
    }
    return all
  }

  @Sendable static func write(_ value: Any) throws -> String {
    guard let all = DataFormats.plain(value) as? [String: Any] else { throw tooDeep }
    func lines(_ record: [String: Any]) throws -> [String] {
      try record.sorted { $0.key < $1.key }.map { key, value in
        guard !(value is [String: Any]), !(value is [Any]) else { throw tooDeep }
        let said = Separated.describe(value)
        guard !said.contains(where: \.isNewline) else { throw tooDeep }
        return "\(key) = \(said)"
      }
    }
    var blocks: [String] = []
    let loose = all.filter { !($0.value is [String: Any]) }
    if !loose.isEmpty { blocks.append(try lines(loose).joined(separator: "\n")) }
    for (name, inside) in all.sorted(by: { $0.key < $1.key }) {
      if let inside = inside as? [String: Any] { blocks.append((["[\(name)]"] + (try lines(inside))).joined(separator: "\n")) }
    }
    return blocks.joined(separator: "\n\n") + "\n"
  }

  private static let tooDeep = ProcessingError.conversionFailed(reason: "An INI file holds sections of plain values, and this holds more than that.")
}

private enum Strings {
  @Sendable static func read(_ text: String) throws -> Any {
    guard let found = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any] else { throw DataFormats.broken("a strings file") }
    return found
  }

  @Sendable static func write(_ value: Any) throws -> String {
    guard let all = DataFormats.plain(value) as? [String: Any], !all.values.contains(where: { $0 is [Any] || $0 is [String: Any] }) else {
      throw ProcessingError.conversionFailed(reason: "A strings file holds words under a name each, and this holds more than that.")
    }
    func quoted(_ text: String) -> String {
      "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    return all.sorted { $0.key < $1.key }.map { "\(quoted($0.key)) = \(quoted(Separated.describe($0.value)));\n" }.joined()
  }
}

// MARK: - XML

private enum Xml {
  private static let root = "root", item = "item"

  @Sendable static func read(_ text: String) throws -> Any {
    guard let document = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]), let root = document.rootElement() else {
      throw DataFormats.broken("XML")
    }
    return [root.name ?? Self.root: value(of: root)]
  }

  /// What is in an element: words, or its pieces by name, the repeated ones as
  /// a list. Attributes begin with an @, as everybody writes them.
  private static func value(of element: XMLElement) -> Any {
    var record: [String: Any] = [:]
    for attribute in element.attributes ?? [] { record["@" + (attribute.name ?? "")] = attribute.stringValue ?? "" }
    for child in element.children ?? [] {
      guard let child = child as? XMLElement, let name = child.name else { continue }
      let inside = value(of: child)
      if var list = record[name] as? [Any] {
        list.append(inside)
        record[name] = list
      } else if let first = record[name] {
        record[name] = [first, inside]
      } else {
        record[name] = inside
      }
    }
    let words = (element.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    if record.isEmpty { return words }
    if !words.isEmpty { record["#text"] = words }
    return record
  }

  @Sendable static func write(_ value: Any) throws -> String {
    let plain = DataFormats.plain(value)
    let top: XMLElement
    // One name at the top is the root; otherwise it is given one.
    if let record = plain as? [String: Any], record.count == 1, let (name, inside) = record.first, !(inside is [Any]), !name.hasPrefix("@"), !name.hasPrefix("#") {
      top = element(name, inside)
    } else {
      top = element(root, plain is [Any] ? [item: plain] : plain)
    }
    let document = XMLDocument(rootElement: top)
    document.version = "1.0"
    document.characterEncoding = "UTF-8"
    return document.xmlString(options: .nodePrettyPrint) + "\n"
  }

  private static func element(_ name: String, _ value: Any) -> XMLElement {
    let made = XMLElement(name: named(name))
    switch value {
    case let record as [String: Any]:
      for (key, inside) in record.sorted(by: { $0.key < $1.key }) {
        if key.hasPrefix("@") {
          made.addAttribute(XMLNode.attribute(withName: named(String(key.dropFirst())), stringValue: Separated.describe(inside)) as! XMLNode)
        } else if key == "#text" {
          made.addChild(XMLNode.text(withStringValue: Separated.describe(inside)) as! XMLNode)
        } else if let list = inside as? [Any] {
          for one in list { made.addChild(element(key, one)) }
        } else {
          made.addChild(element(key, inside))
        }
      }
    case let list as [Any]:
      for one in list { made.addChild(element(item, one)) }
    default:
      made.stringValue = Separated.describe(value)
    }
    return made
  }

  /// A name XML will have: a heading may hold a space, and an element may not.
  private static func named(_ text: String) -> String {
    let safe = text.map { $0.isLetter || $0.isNumber || "_-.:".contains($0) ? $0 : "_" }
    guard let first = safe.first else { return item }
    return (first.isLetter || first == "_" ? "" : "_") + String(safe)
  }
}

// MARK: - Pages of it

private enum Pages {
  @Sendable static func html(_ value: Any) throws -> String {
    let tables = try DataFormats.someTables(in: value).map { name, table -> String in
      let head = table.columns.map { "<th>\(DataFormats.escaped($0))</th>" }.joined()
      let body = table.rows.map { row in "<tr>" + table.columns.map { "<td>\(DataFormats.escaped(row[$0] ?? ""))</td>" }.joined() + "</tr>" }
      return "<table>\n<caption>\(DataFormats.escaped(name))</caption>\n<tr>\(head)</tr>\n\(body.joined(separator: "\n"))\n</table>"
    }
    return """
      <!doctype html>
      <html><head><meta charset="utf-8"><style>
      body { font: 13px -apple-system, sans-serif; margin: 24px } table { border-collapse: collapse; margin-bottom: 24px }
      th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left } th { background: #f2f2f2 }
      </style></head><body>
      \(tables.joined(separator: "\n"))
      </body></html>

      """
  }

  @Sendable static func markdown(_ value: Any) throws -> String {
    func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").split(whereSeparator: \.isNewline).joined(separator: "<br>") }
    let tables = try DataFormats.someTables(in: value)
    return tables.map { name, table in
      let title = tables.count > 1 ? "## \(name)\n\n" : ""
      let lines = [table.columns.map(cell), table.columns.map { _ in "---" }] + table.rows.map { row in table.columns.map { cell(row[$0] ?? "") } }
      return title + lines.map { "| " + $0.joined(separator: " | ") + " |\n" }.joined()
    }.joined(separator: "\n")
  }

  @Sendable static func sql(_ value: Any) throws -> String {
    func name(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    func quoted(_ text: String?) -> String { text.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
    return try DataFormats.someTables(in: value).map { title, table in
      let columns = table.columns.map(name).joined(separator: ", ")
      let made = "CREATE TABLE \(name(title)) (\(table.columns.map { name($0) + " TEXT" }.joined(separator: ", ")));\n"
      return made + table.rows.map { row in "INSERT INTO \(name(title)) (\(columns)) VALUES (\(table.columns.map { quoted(row[$0]) }.joined(separator: ", ")));\n" }.joined()
    }.joined(separator: "\n")
  }
}

// MARK: - Addresses and diaries

/// vCard and iCalendar are the same lines about different things.
private enum Cards {
  private static func lines(_ text: String) -> [(name: String, parameters: String, value: String)] {
    // A line that begins with a space goes on from the one before.
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n[ \t]", with: "", options: .regularExpression)
      .split(separator: "\n").compactMap { line in
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[..<colon].split(separator: ";", maxSplits: 1).map(String.init)
        guard let name = head.first?.split(separator: ".").last else { return nil }
        return (name.uppercased(), head.count > 1 ? head[1] : "", String(line[line.index(after: colon)...]))
      }
  }

  private static func said(_ value: String) -> String {
    value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\,", with: ",")
      .replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
  }

  private static func written(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
      .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\\n")
  }

  private static func records(_ text: String, begin: String, columns: [(String, String)], what: String) throws -> Any {
    var rows: [[String: String]] = [], row: [String: String]?, depth = 0
    for (name, _, value) in lines(text) {
      if name == "BEGIN" {
        if row != nil { depth += 1 } else if value.uppercased() == begin { row = [:] }
      } else if name == "END" {
        if depth > 0 { depth -= 1 } else if let made = row { rows.append(made); row = nil }
      } else if depth == 0, row != nil, let column = columns.first(where: { $0.0 == name })?.1 {
        // A name, an address: in pieces, the empty ones for what is not there.
        let pieces = ["N", "ADR", "ORG"].contains(name) ? value.components(separatedBy: ";").map(said).filter { !$0.isEmpty }.joined(separator: ", ") : said(value)
        guard !pieces.isEmpty else { continue }
        var place = column, copy = 2
        while row?[place] != nil { (place, copy) = ("\(column) \(copy)", copy + 1) }
        row?[place] = pieces
      }
    }
    guard !rows.isEmpty else { throw DataFormats.broken(what) }
    var order = columns.map(\.1)
    for row in rows { for key in row.keys.sorted() where !order.contains(key) { order.append(key) } }
    let used = order.filter { column in rows.contains { $0[column] != nil } }
    return Separated.Table(columns: used, rows: rows)
  }

  private static let person = [
    ("FN", "name"), ("N", "full name"), ("ORG", "organization"), ("TITLE", "title"), ("TEL", "phone"), ("EMAIL", "email"),
    ("ADR", "address"), ("URL", "url"), ("BDAY", "birthday"), ("NOTE", "note"),
  ]
  private static let event = [
    ("SUMMARY", "summary"), ("DTSTART", "start"), ("DTEND", "end"), ("LOCATION", "location"), ("DESCRIPTION", "description"), ("URL", "url"), ("UID", "uid"),
  ]

  @Sendable static func people(_ text: String) throws -> Any { try records(text, begin: "VCARD", columns: person, what: "a vCard") }
  @Sendable static func events(_ text: String) throws -> Any { try records(text, begin: "VEVENT", columns: event, what: "a calendar") }

  private static func blocks(_ value: Any, _ columns: [(String, String)], need: String, what: String) throws -> [[String]] {
    let rows = try DataFormats.someTables(in: value).flatMap(\.table.rows)
    return try rows.map { row in
      let found = Dictionary(row.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
      guard let must = found[need], !must.isEmpty else {
        throw ProcessingError.conversionFailed(reason: "\(what) needs a column called “\(need)”, with something in every row.")
      }
      return columns.flatMap { property, column -> [String] in
        // The second of something is under its name and a number.
        ([column] + (2...9).map { "\(column) \($0)" }).compactMap { found[$0] }.filter { !$0.isEmpty }.map { value in
          if property == "N" { return "N:" + value.components(separatedBy: ", ").map(written).joined(separator: ";") }
          if property == "ADR" { return "ADR:;;" + written(value) + ";;;;" }
          if property.hasPrefix("DT") { return property + stamp(value) }
          return property + ":" + written(value)
        }
      }
    }
  }

  /// A day, or a day and a time, however it was written.
  private static func stamp(_ value: String) -> String {
    let digits = value.filter(\.isNumber)
    if digits.count == 8 { return ";VALUE=DATE:" + digits }
    return ":" + digits.prefix(8) + "T" + digits.dropFirst(8).prefix(6).padding(toLength: 6, withPad: "0", startingAt: 0) + (value.hasSuffix("Z") ? "Z" : "")
  }

  @Sendable static func people(_ value: Any) throws -> String {
    try blocks(value, person, need: "name", what: "A vCard").map { lines in
      let named = lines.contains { $0.hasPrefix("N:") } ? lines : lines + ["N:" + (lines.first { $0.hasPrefix("FN:") }?.dropFirst(3) ?? "") + ";;;;"]
      return (["BEGIN:VCARD", "VERSION:3.0"] + named + ["END:VCARD"]).joined(separator: "\r\n") + "\r\n"
    }.joined()
  }

  @Sendable static func events(_ value: Any) throws -> String {
    let blocks = try blocks(value, event, need: "start", what: "A calendar").map { lines in
      let known = lines.contains { $0.hasPrefix("UID:") } ? lines : lines + ["UID:\(UUID().uuidString)"]
      return ["BEGIN:VEVENT", "DTSTAMP:19700101T000000Z"] + known + ["END:VEVENT"]
    }
    return (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Forge//EN"] + blocks.flatMap { $0 } + ["END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
  }
}
