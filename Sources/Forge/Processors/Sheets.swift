import Foundation
import SQLite3

/// Reads XML as it goes by. A sheet is a long list, and a tree of it is many
/// times its size.
private final class Reading: NSObject, XMLParserDelegate {
  var began: (String, [String: String]) -> Void = { _, _ in }
  var ended: (String, String) -> Void = { _, _ in }
  private var words = ""

  static func read(_ data: Data, began: @escaping (String, [String: String]) -> Void, ended: @escaping (String, String) -> Void) throws {
    let reading = Reading()
    reading.began = began
    reading.ended = ended
    let parser = XMLParser(data: data)
    parser.delegate = reading
    guard parser.parse() else { throw Zip.Reader.broken }
  }

  /// By the last of its name: which of several prefixes a file uses is its own affair.
  private func short(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
    words = ""
    began(short(name), Dictionary(attributes.map { (short($0.key), $0.value) }, uniquingKeysWith: { first, _ in first }))
  }

  func parser(_ parser: XMLParser, foundCharacters text: String) { words += text }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    ended(short(name), words)
    words = ""
  }
}

private enum Grid {
  /// A sheet says it has a million rows, and means the few with something in.
  static let widest = 16_384
  static let longest = 1_048_576

  static func sheet(_ name: String, _ rows: [[String]]) -> (name: String, table: Separated.Table) {
    var rows = rows.map { row in Array(row.prefix((row.lastIndex { !$0.isEmpty } ?? -1) + 1)) }
    while rows.last?.allSatisfy(\.isEmpty) == true { rows.removeLast() }
    return (name, Separated.table(of: rows))
  }

  static func book(_ sheets: [(name: String, table: Separated.Table)]) throws -> Any {
    let full = sheets.filter { !$0.table.columns.isEmpty }
    guard let first = full.first else { throw ProcessingError.conversionFailed(reason: "There is nothing in it.") }
    return full.count == 1 ? first.table : DataFormats.Book(sheets: full)
  }

  /// A number is kept as one, where writing it back gives the same words: a
  /// telephone number with a zero in front is not.
  static func number(_ text: String) -> String? {
    guard text.count <= 15, text.wholeMatch(of: #/-?(0|[1-9][0-9]*)(\.[0-9]+)?/#) != nil else { return nil }
    return text
  }

  /// What a sheet may be called, once each.
  static func names(_ wanted: [String]) -> [String] {
    wanted.reduce(into: []) { names, name in
      let tidy = String(name.map { "[]:*?/\\".contains($0) ? "-" : $0 }.prefix(28))
      var one = tidy.isEmpty ? "Sheet" : tidy, copy = 2
      while names.contains(where: { $0.lowercased() == one.lowercased() }) { (one, copy) = ("\(tidy) \(copy)", copy + 1) }
      names.append(one)
    }
  }
}

// MARK: - Excel

enum Xlsx {
  @Sendable static func read(_ url: URL) throws -> Any {
    let zip = try Zip.Reader(url)
    var targets: [String: String] = [:], sheets: [(String, String)] = []
    try Reading.read(try zip.data("xl/_rels/workbook.xml.rels"), began: { name, values in
      if name == "Relationship", let id = values["Id"] { targets[id] = values["Target"] }
    }, ended: { _, _ in })
    var countsFrom1904 = false
    try Reading.read(try zip.data("xl/workbook.xml"), began: { name, values in
      if name == "workbookPr" { countsFrom1904 = ["1", "true"].contains(values["date1904"] ?? "") }
      if name == "sheet", let id = values["id"], let target = targets[id] { sheets.append((values["name"] ?? "Sheet", target)) }
    }, ended: { _, _ in })
    let words = try sharedWords(zip), dates = try dateStyles(zip)
    return try Grid.book(try sheets.map { name, target in
      let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
      return Grid.sheet(name, try rows(try zip.data(path), words, dates, countsFrom1904))
    })
  }

  private static func sharedWords(_ zip: Zip.Reader) throws -> [String] {
    guard zip.has("xl/sharedStrings.xml") else { return [] }
    var all: [String] = [], one = "", isAside = false
    try Reading.read(try zip.data("xl/sharedStrings.xml"), began: { name, _ in
      if name == "si" { one = "" }
      if name == "rPh" { isAside = true }
    }, ended: { name, words in
      if name == "t", !isAside { one += words }
      if name == "rPh" { isAside = false }
      if name == "si" { all.append(one) }
    })
    return all
  }

  /// The styles that show a number as a day, and whether with a time.
  private static func dateStyles(_ zip: Zip.Reader) throws -> Set<Int> {
    guard zip.has("xl/styles.xml") else { return [] }
    var own: Set<Int> = [], styles: Set<Int> = [], inside = false, index = 0
    try Reading.read(try zip.data("xl/styles.xml"), began: { name, values in
      if name == "numFmt", let id = values["numFmtId"].flatMap(Int.init), let code = values["formatCode"] {
        let bare = code.replacing(#/"[^"]*"|\[[^\]]*\]|\\./#, with: "").lowercased()
        if bare.contains(where: { "dy".contains($0) }) || bare.contains("h:") { own.insert(id) }
      }
      if name == "cellXfs" { inside = true }
      if name == "xf", inside {
        if let id = values["numFmtId"].flatMap(Int.init), (14...22).contains(id) || (45...47).contains(id) || own.contains(id) { styles.insert(index) }
        index += 1
      }
    }, ended: { name, _ in if name == "cellXfs" { inside = false } })
    return styles
  }

  private static func rows(_ data: Data, _ words: [String], _ dates: Set<Int>, _ countsFrom1904: Bool) throws -> [[String]] {
    var rows: [[String]] = [], row = 0, column = 0, kind = "", style = 0, value = ""
    try Reading.read(data, began: { name, values in
      switch name {
      case "row":
        row = min(values["r"].flatMap(Int.init) ?? rows.count + 1, Grid.longest) - 1
        column = -1
        while rows.count <= row, rows.count < Grid.longest { rows.append([]) }
      case "c":
        column = min(values["r"].map(Self.column) ?? column + 1, Grid.widest - 1)
        (kind, style, value) = (values["t"] ?? "n", values["s"].flatMap(Int.init) ?? 0, "")
      default: break
      }
    }, ended: { name, said in
      switch name {
      case "v": value = said
      case "t" where kind == "inlineStr": value += said
      case "c":
        guard !value.isEmpty, rows.indices.contains(row), column >= 0 else { return }
        let text: String
        switch kind {
        case "s": text = Int(value).flatMap { words.indices.contains($0) ? words[$0] : nil } ?? ""
        case "b": text = value == "1" ? "true" : "false"
        case "n": text = dates.contains(style) ? Double(value).map { day($0, countsFrom1904) } ?? value : tidy(value)
        default: text = value
        }
        while rows[row].count <= column { rows[row].append("") }
        rows[row][column] = text
      default: break
      }
    })
    return rows
  }

  /// B12 is the second.
  private static func column(_ place: String) -> Int {
    place.prefix { $0.isLetter }.uppercased().unicodeScalars.prefix(3).reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
  }

  private static func letters(_ column: Int) -> String {
    var left = column + 1, name = ""
    while left > 0 {
      name = String(UnicodeScalar(UInt8(65 + (left - 1) % 26))) + name
      left = (left - 1) / 26
    }
    return name
  }

  /// 0.1 is kept as 0.10000000000000001, which is not what anybody typed.
  private static func tidy(_ text: String) -> String {
    guard text.contains(where: { ".eE".contains($0) }), let number = Double(text) else { return text }
    let short = String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), number)
    return short.contains("e") ? "\(number)" : short
  }

  private static func day(_ serial: Double, _ countsFrom1904: Bool) -> String {
    let seconds = ((serial + (countsFrom1904 ? 1462 : 0) - 25_569) * 86_400).rounded()
    guard abs(seconds) < 1e12 else { return "\(serial)" }
    let date = Date(timeIntervalSince1970: seconds), format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = serial < 1 ? "HH:mm:ss" : seconds.truncatingRemainder(dividingBy: 86_400) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
    return format.string(from: date)
  }

  @Sendable static func write(_ value: Any) throws -> Data {
    let tables = try DataFormats.someTables(in: value), names = Grid.names(tables.map(\.name))
    let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main", office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    let package = "http://schemas.openxmlformats.org/package/2006", kind = "application/vnd.openxmlformats-officedocument.spreadsheetml."
    func sheet(_ table: Separated.Table) -> String {
      let rows = [table.columns] + table.rows.map { row in table.columns.map { row[$0] ?? "" } }
      let body = rows.enumerated().map { index, row -> String in
        let cells = row.enumerated().map { column, text -> String in
          let place = "\(letters(column))\(index + 1)", style = index == 0 ? #" s="1""# : ""
          if text.isEmpty { return "" }
          if index > 0, let number = Grid.number(text) { return #"<c r="\#(place)"><v>\#(number)</v></c>"# }
          return #"<c r="\#(place)"\#(style) t="inlineStr"><is><t xml:space="preserve">\#(DataFormats.escaped(text))</t></is></c>"#
        }
        return #"<row r="\#(index + 1)">"# + cells.joined() + "</row>"
      }
      return head + #"<worksheet xmlns="\#(main)"><sheetData>"# + body.joined() + "</sheetData></worksheet>"
    }
    let numbers = names.indices.map { $0 + 1 }
    var entries = [
      Zip.Entry(name: "[Content_Types].xml", data: Data((head + #"<Types xmlns="\#(package)/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="\#(kind)sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="\#(kind)styles+xml"/>"#
        + numbers.map { #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="\#(kind)worksheet+xml"/>"# }.joined() + "</Types>").utf8)),
      Zip.Entry(name: "_rels/.rels", data: Data((head + #"<Relationships xmlns="\#(package)/relationships"><Relationship Id="rId1" Type="\#(office)/officeDocument" Target="xl/workbook.xml"/></Relationships>"#).utf8)),
      Zip.Entry(name: "xl/workbook.xml", data: Data((head + #"<workbook xmlns="\#(main)" xmlns:r="\#(office)"><sheets>"#
        + zip(names, numbers).map { #"<sheet name="\#(DataFormats.escaped($0))" sheetId="\#($1)" r:id="rId\#($1)"/>"# }.joined() + "</sheets></workbook>").utf8)),
      Zip.Entry(name: "xl/_rels/workbook.xml.rels", data: Data((head + #"<Relationships xmlns="\#(package)/relationships">"#
        + numbers.map { #"<Relationship Id="rId\#($0)" Type="\#(office)/worksheet" Target="worksheets/sheet\#($0).xml"/>"# }.joined()
        + #"<Relationship Id="rId\#(numbers.count + 1)" Type="\#(office)/styles" Target="styles.xml"/></Relationships>"#).utf8)),
      Zip.Entry(name: "xl/styles.xml", data: Data((head + #"<styleSheet xmlns="\#(main)"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf/><xf fontId="1" applyFont="1"/></cellXfs></styleSheet>"#).utf8)),
    ]
    for (number, one) in Swift.zip(numbers, tables) { entries.append(Zip.Entry(name: "xl/worksheets/sheet\(number).xml", data: Data(sheet(one.table).utf8))) }
    return Zip.data(entries)
  }

}

// MARK: - OpenDocument

enum Ods {
  @Sendable static func read(_ url: URL) throws -> Any {
    let zip = try Zip.Reader(url)
    var sheets: [(name: String, table: Separated.Table)] = [], name = "", rows: [[String]] = [], row: [String] = []
    var cell = "", stated: String?, again = 1, rowAgain = 1, paragraphs: [String] = []
    try Reading.read(try zip.data("content.xml"), began: { element, values in
      switch element {
      case "table": (name, rows) = (values["name"] ?? "Sheet", [])
      case "table-row":
        row = []
        rowAgain = values["number-rows-repeated"].flatMap(Int.init) ?? 1
      case "table-cell", "covered-table-cell":
        again = values["number-columns-repeated"].flatMap(Int.init) ?? 1
        paragraphs = []
        switch values["value-type"] {
        case "float", "currency", "percentage": stated = values["value"]
        case "date": stated = values["date-value"]
        case "boolean": stated = values["boolean-value"]
        default: stated = nil
        }
      default: break
      }
    }, ended: { element, words in
      switch element {
      case "p": paragraphs.append(words)
      case "table-cell", "covered-table-cell":
        cell = stated ?? paragraphs.joined(separator: "\n")
        // The empty ones out to the edge are said once, with how many.
        guard row.count + again <= Grid.widest, !cell.isEmpty || again < 256 else { return }
        row += Array(repeating: cell, count: max(1, again))
      case "table-row":
        guard rows.count + rowAgain <= Grid.longest, row.contains(where: { !$0.isEmpty }) || rowAgain < 256 else { return }
        rows += Array(repeating: row, count: max(1, rowAgain))
      case "table": sheets.append(Grid.sheet(name, rows))
      default: break
      }
    })
    return try Grid.book(sheets)
  }

  @Sendable static func write(_ value: Any) throws -> Data {
    let tables = try DataFormats.someTables(in: value), kind = "application/vnd.oasis.opendocument.spreadsheet"
    let space = "urn:oasis:names:tc:opendocument:xmlns:"
    func cell(_ text: String, _ isHead: Bool) -> String {
      if text.isEmpty { return "<table:table-cell/>" }
      let words = "<text:p>\(DataFormats.escaped(text))</text:p>"
      if !isHead, let number = Grid.number(text) { return #"<table:table-cell office:value-type="float" office:value="\#(number)">"# + words + "</table:table-cell>" }
      return #"<table:table-cell office:value-type="string">"# + words + "</table:table-cell>"
    }
    let sheets = Swift.zip(Grid.names(tables.map(\.name)), tables).map { name, one -> String in
      let rows = [one.table.columns] + one.table.rows.map { row in one.table.columns.map { row[$0] ?? "" } }
      return #"<table:table table:name="\#(DataFormats.escaped(name))">"#
        + rows.enumerated().map { index, row in "<table:table-row>" + row.map { cell($0, index == 0) }.joined() + "</table:table-row>" }.joined() + "</table:table>"
    }
    let head = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
    let content = head + #"<office:document-content xmlns:office="\#(space)office:1.0" xmlns:table="\#(space)table:1.0" xmlns:text="\#(space)text:1.0" office:version="1.2"><office:body><office:spreadsheet>"#
      + sheets.joined() + "</office:spreadsheet></office:body></office:document-content>"
    let manifest = head + #"<manifest:manifest xmlns:manifest="\#(space)manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="\#(kind)"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>"#
    return Zip.data([
      Zip.Entry(name: "mimetype", data: Data(kind.utf8), isStored: true),
      Zip.Entry(name: "content.xml", data: Data(content.utf8)),
      Zip.Entry(name: "META-INF/manifest.xml", data: Data(manifest.utf8)),
    ])
  }
}

// MARK: - SQLite

enum Sqlite {
  @Sendable static func read(_ url: URL) throws -> Any {
    var base: OpaquePointer?
    defer { sqlite3_close(base) }
    // As it stands: nothing is written beside somebody's database.
    let place = url.absoluteString + "?mode=ro&immutable=1"
    guard sqlite3_open_v2(place, &base, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { throw DataFormats.broken("a SQLite database") }
    let names = try rows(of: base, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").rows.compactMap { $0["name"] }
    return try Grid.book(try names.map { name in
      (name, try rows(of: base, "SELECT * FROM \"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
    })
  }

  private static func rows(of base: OpaquePointer?, _ question: String) throws -> Separated.Table {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(base, question, -1, &statement, nil) == SQLITE_OK else { throw DataFormats.broken("a SQLite database") }
    let columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
    var rows: [[String: String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      var row: [String: String] = [:]
      for (index, column) in columns.enumerated() {
        let index = Int32(index)
        if sqlite3_column_type(statement, index) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, index) {
          row[column] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))).base64EncodedString()
        } else if let text = sqlite3_column_text(statement, index) {
          row[column] = String(cString: text)
        }
      }
      rows.append(row)
    }
    return Separated.Table(columns: columns, rows: rows)
  }
}
