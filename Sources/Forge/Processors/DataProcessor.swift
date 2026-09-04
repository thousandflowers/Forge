import Foundation
import UniformTypeIdentifiers

/// Tabular and structured data: CSV, JSON and Property List.
///
/// All three are Foundation's, so this needs nothing installed. YAML and TOML
/// are not here because Foundation has no parser for them and there would be
/// nothing to call.
final class DataProcessor: FileProcessor, @unchecked Sendable {
  let name = "Data Processor"

  static let csv: UTType? = UTType("public.comma-separated-values-text")
  static let tsv: UTType? = UTType("public.tab-separated-values-text")

  static var readable: [UTType] {
    [.json, .propertyList, csv, tsv].compactMap { $0 }
  }

  func canProcess(_ file: ProcessableFile) -> Bool {
    Self.readable.contains { file.fileType.conforms(to: $0) }
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
    guard Self.readable.contains(where: { outputType.conforms(to: $0) }) else {
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
    return try Separated.rows(from: text, separator: separator(for: type))
  }

  // MARK: - Writing

  private static func write(_ value: Any, to url: URL, as type: UTType) throws {
    if type.conforms(to: .json) {
      let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
      )
      return try data.write(to: url, options: .atomic)
    }
    if type.conforms(to: .propertyList) {
      let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
      return try data.write(to: url, options: .atomic)
    }

    guard let rows = value as? [[String: Any]] else {
      throw ProcessingError.conversionFailed(
        reason: "Only a list of flat records can become a table. This file is not one."
      )
    }
    let text = Separated.text(from: rows, separator: separator(for: type))
    try text.write(to: url, atomically: true, encoding: .utf8)
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

  static func rows(from text: String, separator: Character) throws -> [[String: String]] {
    let records = parse(text, separator: separator)
    guard let header = records.first else { return [] }
    return records.dropFirst().map { record in
      var row: [String: String] = [:]
      for (index, column) in header.enumerated() where index < record.count {
        row[column] = record[index]
      }
      return row
    }
  }

  static func text(from rows: [[String: Any]], separator: Character) -> String {
    // Every key any record has, so a row missing one still lines up.
    var columns: [String] = []
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
      case "\n": endRecord()
      case "\r": break // a CRLF file should not leave a stray return behind
      default: field.append(character)
      }
    }

    if !field.isEmpty || !record.isEmpty { endRecord() }
    return records
  }

  private static func escape(_ value: String, separator: Character) -> String {
    let needsQuotes = value.contains(separator) || value.contains("\"") || value.contains("\n")
    guard needsQuotes else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func describe(_ value: Any?) -> String {
    switch value {
    case nil, is NSNull: return ""
    case let string as String: return string
    case let number as NSNumber: return number.stringValue
    case let value?: return String(describing: value)
    }
  }
}
