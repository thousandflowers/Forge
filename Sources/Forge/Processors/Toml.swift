import Foundation

/// TOML, read and written here because Foundation has no parser for it.
///
/// This is a deliberate subset: keys and values, `[tables]`, `[[arrays of
/// tables]]`, arrays, inline tables, comments, and the four kinds of scalar
/// somebody actually writes in a configuration file. What it does not do it
/// refuses rather than guesses at - a date read as a string, or a multi-line
/// string read as three empty ones, is a file quietly changed, which is worse
/// than a file that would not convert.
enum Toml {

  /// TOML by its extension rather than by its type: `public.toml` does not
  /// exist on macOS 14, so asking the type database whether a file is TOML
  /// gets a different answer depending on the Mac. The extension does not
  /// move.
  static func handles(_ ext: String) -> Bool { ext.lowercased() == "toml" }

  // MARK: - Reading

  static func object(from text: String) throws -> [String: Any] {
    var root: [String: Any] = [:]
    /// Where the keys that follow belong. Empty is the top level.
    var path: [String] = []
    var arrayPath: [String]?

    for (number, raw) in text.components(separatedBy: .newlines).enumerated() {
      let line = strip(raw)
      if line.isEmpty { continue }

      if line.hasPrefix("[[") {
        guard line.hasSuffix("]]") else { throw unreadable(number, raw) }
        arrayPath = try keyPath(String(line.dropFirst(2).dropLast(2)), number, raw)
        path = arrayPath ?? []
        append(emptyTable: path, to: &root)
        continue
      }

      if line.hasPrefix("[") {
        guard line.hasSuffix("]") else { throw unreadable(number, raw) }
        path = try keyPath(String(line.dropFirst().dropLast()), number, raw)
        arrayPath = nil
        continue
      }

      guard let equals = indexOfAssignment(in: line) else { throw unreadable(number, raw) }
      let key = try bareKey(String(line[line.startIndex..<equals]), number, raw)
      let value = try scalar(String(line[line.index(after: equals)...]), number, raw)

      if let arrayPath {
        appendToLastTable(at: arrayPath, key: key, value: value, in: &root)
      } else {
        insert(value, at: path + [key], in: &root)
      }
    }

    return root
  }

  // MARK: - Writing

  static func text(from value: Any) throws -> String {
    guard let table = value as? [String: Any] else {
      throw ProcessingError.conversionFailed(
        reason: "TOML holds a table of keys. This file is a \(kind(of: value)), "
          + "which has no name to give it."
      )
    }
    return try write(table, at: []).trimmingCharacters(in: .newlines) + "\n"
  }

  private static func write(_ table: [String: Any], at path: [String]) throws -> String {
    var scalars: [String] = []
    var tables: [String] = []

    for key in table.keys.sorted() {
      let value = table[key] ?? NSNull()

      if let nested = value as? [String: Any] {
        let name = (path + [key]).joined(separator: ".")
        let body = try write(nested, at: path + [key])
        // A table whose keys are all tables of their own needs no header: it
        // is written by the ones inside it, and `[server]` on a line by itself
        // says nothing that `[server.limiti]` does not.
        let holdsOnlyTables = !nested.isEmpty && nested.values.allSatisfy { $0 is [String: Any] }
        tables.append(holdsOnlyTables ? body : "[\(name)]\n" + body)
        continue
      }

      if let rows = value as? [Any], rows.contains(where: { $0 is [String: Any] }) {
        guard let onlyTables = rows as? [[String: Any]] else {
          throw ProcessingError.conversionFailed(
            reason: "The list “\(key)” mixes tables with other values, which TOML cannot write."
          )
        }
        let name = (path + [key]).joined(separator: ".")
        for row in onlyTables {
          tables.append("[[\(name)]]\n" + (try write(row, at: path + [key])))
        }
        continue
      }

      scalars.append("\(key) = \(try literal(value))")
    }

    // A blank line between the keys and each table that follows them: valid
    // either way, and this is the shape everybody writes TOML in.
    let keys = scalars.joined(separator: "\n")
    let sections = tables.map { $0.trimmingCharacters(in: .newlines) }
    return ([keys.isEmpty ? nil : keys] + sections)
      .compactMap { $0 }
      .joined(separator: "\n\n") + "\n"
  }

  private static func literal(_ value: Any) throws -> String {
    switch value {
    case let number as NSNumber where isBoolean(number): return number.boolValue ? "true" : "false"
    case let bool as Bool: return bool ? "true" : "false"
    case let number as NSNumber: return number.stringValue
    case let string as String: return quoted(string)
    case let date as Date: return ISO8601DateFormatter().string(from: date)
    case let list as [Any]: return "[" + (try list.map(literal).joined(separator: ", ")) + "]"
    case is NSNull:
      throw ProcessingError.conversionFailed(
        reason: "TOML has no null. A key with nothing in it is left out of a TOML file, "
          + "not written empty."
      )
    default:
      throw ProcessingError.conversionFailed(reason: "TOML cannot hold a \(kind(of: value))")
    }
  }

  // MARK: - Values

  /// The scalars a configuration file is made of, plus arrays and inline
  /// tables. A date is refused: TOML dates carry an offset, a bare one means
  /// different things to different readers, and a wrong timestamp looks
  /// exactly like a right one.
  private static func scalar(_ raw: String, _ number: Int, _ line: String) throws -> Any {
    let text = strip(raw)

    if text.hasPrefix("\"") || text.hasPrefix("'") { return try string(text, number, line) }
    if text == "true" { return true }
    if text == "false" { return false }
    if text.hasPrefix("[") { return try list(text, number, line) }
    if text.hasPrefix("{") { return try inlineTable(text, number, line) }

    let plain = text.replacingOccurrences(of: "_", with: "")
    if let integer = Int(plain) { return integer }
    if plain.contains(":") || plain.contains("-") {
      throw ProcessingError.conversionFailed(
        reason: "Line \(number + 1) looks like a date, and Forge does not read TOML dates: "
          + line.trimmingCharacters(in: .whitespaces)
      )
    }
    if let double = Double(plain) { return double }

    throw unreadable(number, line)
  }

  private static func string(_ text: String, _ number: Int, _ line: String) throws -> String {
    if text.hasPrefix("\"\"\"") || text.hasPrefix("'''") {
      throw ProcessingError.conversionFailed(
        reason: "Line \(number + 1) opens a multi-line string, which Forge does not read."
      )
    }
    guard let quote = text.first, text.count >= 2, text.hasSuffix(String(quote)) else {
      throw unreadable(number, line)
    }
    let body = String(text.dropFirst().dropLast())
    // A literal string is literal: only a basic one carries escapes.
    guard quote == "\"" else { return body }

    var result = ""
    var escaping = false
    for character in body {
      if escaping {
        switch character {
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        case "\"": result.append("\"")
        case "\\": result.append("\\")
        default: throw unreadable(number, line)
        }
        escaping = false
        continue
      }
      if character == "\\" { escaping = true } else { result.append(character) }
    }
    return result
  }

  private static func list(_ text: String, _ number: Int, _ line: String) throws -> [Any] {
    guard text.hasSuffix("]") else { throw unreadable(number, line) }
    let body = String(text.dropFirst().dropLast())
    return try split(body, number, line).map { try scalar($0, number, line) }
  }

  private static func inlineTable(
    _ text: String, _ number: Int, _ line: String
  ) throws -> [String: Any] {
    guard text.hasSuffix("}") else { throw unreadable(number, line) }
    var table: [String: Any] = [:]
    for pair in try split(String(text.dropFirst().dropLast()), number, line) {
      guard let equals = indexOfAssignment(in: pair) else { throw unreadable(number, line) }
      let key = try bareKey(String(pair[pair.startIndex..<equals]), number, line)
      table[key] = try scalar(String(pair[pair.index(after: equals)...]), number, line)
    }
    return table
  }

  /// Split on commas that are not inside a string, a list or an inline table.
  private static func split(_ text: String, _ number: Int, _ line: String) throws -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    var quote: Character?

    for character in text {
      if let open = quote {
        current.append(character)
        if character == open { quote = nil }
        continue
      }
      switch character {
      case "\"", "'": quote = character; current.append(character)
      case "[", "{": depth += 1; current.append(character)
      case "]", "}": depth -= 1; current.append(character)
      case "," where depth == 0:
        parts.append(current)
        current = ""
      default: current.append(character)
      }
    }
    if quote != nil { throw unreadable(number, line) }
    parts.append(current)

    return parts.map(strip).filter { !$0.isEmpty }
  }

  // MARK: - Lines and keys

  /// A line without its comment. A `#` inside a string is not a comment, which
  /// is the whole reason this is not a `split(separator: "#")`.
  private static func strip(_ line: String) -> String {
    var result = ""
    var quote: Character?
    for character in line {
      if let open = quote {
        result.append(character)
        if character == open { quote = nil }
        continue
      }
      if character == "#" { break }
      if character == "\"" || character == "'" { quote = character }
      result.append(character)
    }
    return result.trimmingCharacters(in: .whitespaces)
  }

  /// The first `=` that is not inside a string.
  private static func indexOfAssignment(in line: String) -> String.Index? {
    var quote: Character?
    var index = line.startIndex
    while index < line.endIndex {
      let character = line[index]
      if let open = quote {
        if character == open { quote = nil }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == "=" {
        return index
      }
      index = line.index(after: index)
    }
    return nil
  }

  private static func keyPath(_ text: String, _ number: Int, _ line: String) throws -> [String] {
    let parts = text.split(separator: ".").map(String.init)
    guard !parts.isEmpty else { throw unreadable(number, line) }
    return try parts.map { try bareKey($0, number, line) }
  }

  private static func bareKey(_ text: String, _ number: Int, _ line: String) throws -> String {
    let trimmed = strip(text)
    guard !trimmed.isEmpty else { throw unreadable(number, line) }
    if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") {
      return try string(trimmed, number, line)
    }
    return trimmed
  }

  // MARK: - Building the tree

  private static func insert(_ value: Any, at path: [String], in table: inout [String: Any]) {
    guard let key = path.first else { return }
    if path.count == 1 {
      table[key] = value
      return
    }
    var nested = table[key] as? [String: Any] ?? [:]
    insert(value, at: Array(path.dropFirst()), in: &nested)
    table[key] = nested
  }

  private static func append(emptyTable path: [String], to table: inout [String: Any]) {
    guard let key = path.first else { return }
    if path.count == 1 {
      var rows = table[key] as? [[String: Any]] ?? []
      rows.append([:])
      table[key] = rows
      return
    }
    var nested = table[key] as? [String: Any] ?? [:]
    append(emptyTable: Array(path.dropFirst()), to: &nested)
    table[key] = nested
  }

  private static func appendToLastTable(
    at path: [String], key: String, value: Any, in table: inout [String: Any]
  ) {
    guard let head = path.first else { return }
    if path.count == 1 {
      var rows = table[head] as? [[String: Any]] ?? [[:]]
      var last = rows.popLast() ?? [:]
      last[key] = value
      rows.append(last)
      table[head] = rows
      return
    }
    var nested = table[head] as? [String: Any] ?? [:]
    appendToLastTable(at: Array(path.dropFirst()), key: key, value: value, in: &nested)
    table[head] = nested
  }

  // MARK: - Odds and ends

  private static func quoted(_ text: String) -> String {
    var escaped = ""
    for character in text {
      switch character {
      case "\\": escaped += "\\\\"
      case "\"": escaped += "\\\""
      case "\n": escaped += "\\n"
      case "\t": escaped += "\\t"
      case "\r": escaped += "\\r"
      default: escaped.append(character)
      }
    }
    return "\"\(escaped)\""
  }

  /// `NSNumber` loses the difference between a boolean and a 1, except here.
  private static func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func kind(of value: Any) -> String {
    switch value {
    case is [Any]: return "list"
    case is String: return "piece of text"
    case is NSNumber: return "number"
    case is Date: return "date"
    default: return "\(type(of: value))"
    }
  }

  private static func unreadable(_ number: Int, _ line: String) -> ProcessingError {
    .conversionFailed(
      reason: "Line \(number + 1) is not TOML Forge can read: "
        + line.trimmingCharacters(in: .whitespaces)
    )
  }
}
