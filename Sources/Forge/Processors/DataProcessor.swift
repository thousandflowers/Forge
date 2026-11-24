import Foundation
import UniformTypeIdentifiers

/// Tabular and structured data.
///
/// JSON, CSV and Property List are Foundation's. Nothing on the machine reads
/// the rest, so `Toml`, `Yaml` and `DataFormats` read the part of each that
/// people's files are made of, and refuse what is beyond it rather than guess.
final class DataProcessor: FileProcessor, @unchecked Sendable {
  let name = "Data Processor"

  static let csv: UTType? = UTType("public.comma-separated-values-text")
  static let tsv: UTType? = UTType("public.tab-separated-values-text")
  static let toml: UTType? = UTType("public.toml")

  static var readable: [UTType] {
    [.json, .propertyList, csv, tsv, toml].compactMap { $0 }
  }

  // Who may become what: a list of contacts is a table, and a table of sales is
  // no list of contacts, but nobody can tell which it is until it is asked for.
  static let records = ["json", "jsonl", "ndjson", "yaml", "yml", "toml", "plist", "xml"]
  static let tables = ["csv", "tsv", "xlsx", "ods", "sql"]
  static let settings = ["ini", "strings"]
  static let places = ["geojson", "gpx", "kml", "kmz"]
  static let cards = ["vcf", "ics"]

  static func handles(_ type: UTType) -> Bool {
    readable.contains { type.conforms(to: $0) } || type.goes(by: DataFormats.written.union(DataFormats.binary).union(ExternalBridge.tables).filter { DataFormats.reads($0) || ExternalBridge.tables.contains($0) })
  }

  private static func reads(_ ext: String, _ type: UTType) -> Bool {
    Toml.handles(ext) || DataFormats.reads(ext) || readable.contains { type.conforms(to: $0) }
  }

  func canProcess(_ file: ProcessableFile) -> Bool { Self.reads(file.url.pathExtension, file.fileType) }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    let source = file.url.pathExtension.lowercased(), wanted = Conversions.fileExtension(of: target)
    if Self.settings.contains(wanted) { return Self.settings.contains(source) || Self.records.contains(source) }
    if Self.places.contains(wanted) { return Self.places.contains(source) || Self.tables.contains(source) || source == "json" }
    if Self.cards.contains(wanted) { return Self.tables.contains(source) || source == wanted }
    return Toml.handles(wanted) || DataFormats.writes(wanted) || Self.readable.contains { target.conforms(to: $0) }
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    guard let inputType = UTType(filenameExtension: input.pathExtension) else {
      throw ProcessingError.unknownType
    }
    let outputType = Self.outputType(for: output, operations: operations)
    let wanted = output.pathExtension.lowercased()
    guard Toml.handles(wanted) || DataFormats.writes(wanted) || Self.readable.contains(where: { outputType.conforms(to: $0) }) else {
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputType)
    }

    progress(0.3)
    let value = try Self.read(input, as: inputType)
    progress(0.7)
    var extras: [URL] = []
    if !DataFormats.writes(wanted), [Self.csv, Self.tsv].contains(where: { $0.map(outputType.conforms) ?? false }), let book = value as? DataFormats.Book {
      // A sheet a file: there is one table in a CSV.
      for (index, sheet) in book.sheets.enumerated() {
        let place = index == 0 ? output : output.numbered(index + 1, of: book.sheets.count)
        try Self.write(sheet.table, to: place, as: outputType)
        if index > 0 { extras.append(place) }
      }
    } else {
      try Self.write(value, to: output, as: outputType)
    }
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start),
      additionalOutputs: extras
    )
  }

  // MARK: - Reading

  private static func read(_ url: URL, as type: UTType) throws -> Any {
    if DataFormats.reads(url.pathExtension) { return try DataFormats.read(url) }
    let data = try Data(contentsOf: url)

    if type.conforms(to: .json) {
      return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    if type.conforms(to: .propertyList) {
      return try PropertyListSerialization.propertyList(from: data, format: nil)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is not UTF-8 text")
    }
    if Toml.handles(url.pathExtension) {
      return try Toml.object(from: text)
    }
    return try Separated.table(from: text, separator: separator(for: type))
  }

  // MARK: - Writing

  private static func write(_ read: Any, to url: URL, as type: UTType) throws {
    // A table remembers the order of its columns; every other format only
    // wants the rows.
    let table = read as? Separated.Table
    let value = DataFormats.plain(read)
    if DataFormats.writes(url.pathExtension) { return try DataFormats.data(read, as: url.pathExtension).write(to: url, options: .atomic) }

    if type.conforms(to: .json) {
      let data = try JSONSerialization.data(
        withJSONObject: try jsonSafe(value),
        options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
      )
      return try data.write(to: url, options: .atomic)
    }
    if type.conforms(to: .propertyList) {
      guard !holdsNull(value) else {
        throw ProcessingError.conversionFailed(
          reason: "A property list cannot hold a null, and this file has one. "
            + "Remove the empty value, or convert to JSON instead."
        )
      }
      let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
      return try data.write(to: url, options: .atomic)
    }

    if Toml.handles(url.pathExtension) {
      return try Toml.text(from: value).write(to: url, atomically: true, encoding: .utf8)
    }

    let columns: [String]?, rows: [[String: Any]]
    if let plain = value as? [[String: Any]] {
      (columns, rows) = (table?.columns, plain)
    } else {
      // Places, or a record of several tables: the first of them.
      let first = try DataFormats.someTables(in: read)[0].table
      (columns, rows) = (first.columns, first.rows)
    }
    let text = Separated.text(from: rows, columns: columns, separator: separator(for: type))
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// The same value with everything JSON has no word for put into one it has.
  ///
  /// A property list holds dates and raw bytes and JSON holds neither.
  /// `JSONSerialization` answers an object it cannot write with an Objective-C
  /// exception, which Swift cannot catch: converting such a file took the
  /// whole process down. So the value is made safe first, and checked.
  static func jsonSafe(_ value: Any) throws -> Any {
    let safe = try jsonReady(value)
    // Wrapped, because the check refuses a bare string or number at the top
    // and those are fine here.
    guard JSONSerialization.isValidJSONObject([safe]) else {
      throw ProcessingError.conversionFailed(reason: "This file holds a value JSON has no way to write.")
    }
    return safe
  }

  private static func jsonReady(_ value: Any) throws -> Any {
    switch value {
    case let date as Date:
      return ISO8601DateFormatter().string(from: date)
    case let data as Data:
      return data.base64EncodedString()
    case let record as [String: Any]:
      return try record.mapValues(jsonReady)
    case let list as [Any]:
      return try list.map(jsonReady)
    case let number as NSNumber where !number.doubleValue.isFinite:
      throw ProcessingError.conversionFailed(
        reason: "JSON has no way to write \(number.stringValue), and this file holds one."
      )
    case let number as NSNumber where CFNumberIsFloatType(number) && !(number is NSDecimalNumber):
      // Written as the shortest number that reads back the same, which is the
      // one somebody typed: left to the serialiser, 3.14 came out with every
      // digit the machine holds, 3.1400000000000001.
      return NSDecimalNumber(string: "\(number.doubleValue)")
    default:
      return value
    }
  }

  private static func holdsNull(_ value: Any) -> Bool {
    switch value {
    case is NSNull: return true
    case let record as [String: Any]: return record.values.contains(where: holdsNull)
    case let list as [Any]: return list.contains(where: holdsNull)
    default: return false
    }
  }

  private static func separator(for type: UTType) -> Character {
    if let tsv, type.conforms(to: tsv) { return "\t" }
    return ","
  }

  private static func outputType(for output: URL, operations: [Operation]) -> UTType {
    let requested = operations.compactMap { operation -> UTType? in
      guard case .convertFormat(let to) = operation else { return nil }
      return to
    }.first
    return requested ?? UTType(filenameExtension: output.pathExtension) ?? .json
  }
}

/// A separated-values reader and writer, to the rules everyone follows:
/// fields may be quoted, a quote inside a quoted field is doubled, and a
/// quoted field may contain the separator or a newline.
enum Separated {

  /// A table as it was read: its rows, and the order its columns came in,
  /// which a dictionary forgets.
  struct Table {
    let columns: [String]
    let rows: [[String: String]]
  }

  static func rows(from text: String, separator: Character) throws -> [[String: String]] {
    try table(from: text, separator: separator).rows
  }

  static func table(from text: String, separator: Character) throws -> Table {
    let records = parse(text, separator: separator)
    // One line and nothing under it, opening like JSON: a JSON file under a
    // table's name. Read as a table it is a header with no rows, and came out
    // as an empty list, reported as converted.
    if records.count == 1, let opening = text.first(where: { !$0.isWhitespace }), "[{".contains(opening) {
      throw ProcessingError.conversionFailed(
        reason: "This file is called a table and holds JSON. Give it the .json extension and it will convert."
      )
    }
    return self.table(of: records)
  }

  /// The first of them are the headings.
  static func table(of records: [[String]]) -> Table {
    guard let stated = records.first else { return Table(columns: [], rows: []) }
    // Every cell needs a heading of its own to be kept under. A second column
    // called "name" replaced the first, and a row longer than the header lost
    // whatever did not fit beneath it; a repeat is numbered, and what has no
    // heading is given one.
    let widest = records.map(\.count).max() ?? stated.count
    var header: [String] = []
    for index in 0..<widest {
      let wanted = index < stated.count && !stated[index].isEmpty ? stated[index] : "column \(index + 1)"
      var name = wanted
      var copy = 2
      while header.contains(name) {
        name = "\(wanted) \(copy)"
        copy += 1
      }
      header.append(name)
    }
    let rows = records.dropFirst().map { record in
      var row: [String: String] = [:]
      for (index, column) in header.enumerated() where index < record.count {
        row[column] = record[index]
      }
      return row
    }
    return Table(columns: header, rows: rows)
  }

  /// - Parameter columns: the order to write them in, when the source had one.
  ///   Records out of JSON or a property list have none, so theirs is
  ///   alphabetical: the same file gives the same table every time.
  static func text(from rows: [[String: Any]], columns known: [String]? = nil, separator: Character) -> String {
    // Every key any record has, so a row missing one still lines up.
    var columns: [String] = known ?? []
    for row in rows {
      for key in row.keys.sorted() where !columns.contains(key) {
        columns.append(key)
      }
    }

    let header = columns.map { escape($0, separator: separator) }.joined(separator: String(separator))
    let body = rows.map { row in
      columns
        .map { escape(describe(row[$0]), separator: separator) }
        .joined(separator: String(separator))
    }
    return ([header] + body).joined(separator: "\n") + "\n"
  }

  // MARK: - Parsing

  private static func parse(_ text: String, separator: Character) -> [[String]] {
    var records: [[String]] = []
    var record: [String] = []
    var field = ""
    var quoted = false
    var iterator = text.makeIterator()
    var pending: Character?

    func endField() {
      record.append(field)
      field = ""
    }
    func endRecord() {
      endField()
      // A trailing newline should not add an empty record.
      if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
      record = []
    }

    while let character = pending ?? iterator.next() {
      pending = nil

      if quoted {
        if character == "\"" {
          if let next = iterator.next() {
            if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
          } else {
            quoted = false
          }
        } else {
          field.append(character)
        }
        continue
      }

      switch character {
      case "\"": quoted = true
      case separator: endField()
      // "\r\n" is a single Character, equal to neither of its halves: a file
      // with Windows line endings used to be read as one endless record.
      case "\n", "\r\n", "\r": endRecord()
      default: field.append(character)
      }
    }

    if !field.isEmpty || !record.isEmpty { endRecord() }
    return records
  }

  private static func escape(_ value: String, separator: Character) -> String {
    let needsQuotes = value.contains(separator) || value.contains("\"") || value.contains(where: \.isNewline)
    guard needsQuotes else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  static func describe(_ value: Any?) -> String {
    switch value {
    case nil, is NSNull: return ""
    case let string as String: return string
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
      return number.boolValue ? "true" : "false"
    case let number as NSNumber: return number.stringValue
    // A list or a record in one cell, as JSON: the alternative was
    // Objective-C's debug description of it, which nothing reads back.
    case let value? where JSONSerialization.isValidJSONObject(value):
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      return data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
    case let value?: return String(describing: value)
    }
  }
}
