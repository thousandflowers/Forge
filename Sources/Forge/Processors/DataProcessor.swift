import Foundation
import UniformTypeIdentifiers

/// Tabular and structured data: CSV, JSON, Property List and TOML.
///
/// The first three are Foundation's. TOML is not - nothing on the machine
/// reads it - so `Toml` reads and writes the part of it a configuration file
/// is made of, and refuses the rest rather than guessing. YAML is still not
/// here: its specification is large enough that a subset would quietly
/// misread files that look ordinary.
final class DataProcessor: FileProcessor, @unchecked Sendable {
  let name = "Data Processor"

  static let csv: UTType? = UTType("public.comma-separated-values-text")
  static let tsv: UTType? = UTType("public.tab-separated-values-text")
  static let toml: UTType? = UTType("public.toml")

  static var readable: [UTType] {
    [.json, .propertyList, csv, tsv, toml].compactMap { $0 }
  }

  func canProcess(_ file: ProcessableFile) -> Bool {
    Toml.handles(file.url.pathExtension) || Self.readable.contains { file.fileType.conforms(to: $0) }
  }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    Toml.handles(Conversions.fileExtension(of: target)) || Self.readable.contains { target.conforms(to: $0) }
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
    let writable = Toml.handles(output.pathExtension)
      || Self.readable.contains { outputType.conforms(to: $0) }
    guard writable else {
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputType)
    }

    progress(0.3)
    let value = try Self.read(input, as: inputType)
    progress(0.7)
    try Self.write(value, to: output, as: outputType)
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  // MARK: - Reading

  private static func read(_ url: URL, as type: UTType) throws -> Any {
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
    let value: Any = table?.rows ?? read

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

    guard let rows = value as? [[String: Any]] else {
      throw ProcessingError.conversionFailed(
        reason: "Only a list of flat records can become a table. This file is not one."
      )
    }
    let text = Separated.text(from: rows, columns: table?.columns, separator: separator(for: type))
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
    guard let header = records.first else { return Table(columns: [], rows: []) }
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

  private static func describe(_ value: Any?) -> String {
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
