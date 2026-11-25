import Foundation

/// The YAML that settings files are written in: records, lists, words, numbers,
/// and blocks of text. What is clever - anchors, tags, several documents - is
/// refused and said, because read wrongly it still looks like an answer.
enum Yaml {
  // MARK: - Reading

  @Sendable static func read(_ text: String) throws -> Any {
    var parser = Parser(text)
    return try parser.document()
  }

  private struct Line {
    let number: Int
    let indent: Int
    let text: String
  }

  private struct Parser {
    private var lines: [Line] = []
    private let raw: [String]
    private var at = 0

    init(_ text: String) {
      raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
      lines = raw.enumerated().compactMap { number, line in
        let body = Self.withoutComment(line)
        guard !body.allSatisfy(\.isWhitespace) else { return nil }
        return Line(number: number, indent: body.prefix { $0 == " " }.count, text: body.trimmingCharacters(in: .whitespaces))
      }
    }

    private func refuse(_ what: String, _ line: Line) -> ProcessingError {
      .conversionFailed(reason: "Line \(line.number + 1): \(what)")
    }

    /// A # begins a comment after a space, and not inside quotes.
    private static func withoutComment(_ line: String) -> String {
      var quote: Character?, before: Character = " "
      for index in line.indices {
        let character = line[index]
        if let open = quote {
          if character == open, !(open == "\"" && before == "\\") { quote = nil }
        } else if (character == "\"" || character == "'"), " [{,:-".contains(before) {
          quote = character
        } else if character == "#", before == " " || before == "\t" {
          return String(line[..<index])
        }
        before = character
      }
      return line
    }

    mutating func document() throws -> Any {
      if let first = lines.first, first.text.hasPrefix("%") { throw refuse("Forge does not read YAML directives.", first) }
      if let first = lines.first, first.text == "---" { at = 1 }
      if let last = lines.last, last.text == "..." { lines.removeLast() }
      if let next = lines.dropFirst(at).first(where: { $0.text == "---" && $0.indent == 0 }) {
        throw refuse("there are several documents in this file, and Forge reads one.", next)
      }
      guard at < lines.count else { return [String: Any]() }
      let value = try block(lines[at].indent)
      if at < lines.count { throw refuse("this line is not where it belongs.", lines[at]) }
      return value
    }

    private mutating func block(_ indent: Int) throws -> Any {
      let line = lines[at]
      if line.text == "-" || line.text.hasPrefix("- ") { return try list(indent) }
      if Self.key(of: line.text) != nil { return try record(indent) }
      // Words over several lines are one line.
      if let head = header(line.text) { at += 1; return try blockText(head, under: indent - 1, from: line) }
      var words = line.text
      at += 1
      while at < lines.count, lines[at].indent >= indent, unfinished(words) || (!"\"'[{".contains(words.first ?? " ") && Self.key(of: lines[at].text) == nil) {
        words += " " + lines[at].text
        at += 1
      }
      return try scalar(words, line)
    }

    private mutating func list(_ indent: Int) throws -> [Any] {
      var items: [Any] = []
      while at < lines.count, lines[at].indent == indent, lines[at].text == "-" || lines[at].text.hasPrefix("- ") {
        let line = lines[at]
        let rest = line.text.dropFirst().drop { $0 == " " }
        if rest.isEmpty {
          at += 1
          items.append(at < lines.count && lines[at].indent > indent ? try block(lines[at].indent) : NSNull())
        } else if rest == "-" || rest.hasPrefix("- ") || Self.key(of: String(rest)) != nil {
          // What follows the dash begins where it is written.
          let inner = indent + line.text.count - rest.count
          lines[at] = Line(number: line.number, indent: inner, text: String(rest))
          items.append(try block(inner))
        } else {
          items.append(try value(String(rest), line, indent))
        }
      }
      return items
    }

    private mutating func record(_ indent: Int) throws -> [String: Any] {
      var all: [String: Any] = [:]
      while at < lines.count, lines[at].indent == indent, let (key, rest) = Self.key(of: lines[at].text) {
        let line = lines[at]
        guard key != "<<", !key.hasPrefix("?"), !key.hasPrefix("&"), !key.hasPrefix("*") else { throw refuse("Forge does not read this part of YAML.", line) }
        let name = Separated.describe(try scalar(key, line, asKey: true))
        guard all[name] == nil else { throw refuse("“\(name)” is here twice.", line) }
        if rest.isEmpty {
          at += 1
          // A list may begin under its name, no further in.
          if at < lines.count, lines[at].indent > indent || (lines[at].indent == indent && (lines[at].text == "-" || lines[at].text.hasPrefix("- "))) {
            all[name] = try block(lines[at].indent)
          } else {
            all[name] = NSNull()
          }
        } else {
          all[name] = try value(rest, line, indent)
        }
      }
      if at < lines.count, lines[at].indent > indent { throw refuse("this line is not where it belongs.", lines[at]) }
      return all
    }

    /// What is on the line with its name, and goes on under it.
    private mutating func value(_ text: String, _ line: Line, _ indent: Int) throws -> Any {
      at += 1
      if let head = header(text) { return try blockText(head, under: indent, from: line) }
      var words = text
      while at < lines.count, lines[at].indent > indent || unfinished(words) {
        guard unfinished(words) || (!"\"'[{".contains(words.first ?? " ") && Self.key(of: lines[at].text) == nil) else { throw refuse("this line is not where it belongs.", lines[at]) }
        words += " " + lines[at].text
        at += 1
      }
      return try scalar(words, line)
    }

    private func header(_ text: String) -> String? { text.wholeMatch(of: #/[|>][+-]?/#) == nil ? nil : text }

    private mutating func blockText(_ head: String, under indent: Int, from line: Line) throws -> String {
      var body: [String] = [], inner: Int?, next = line.number + 1
      while next < raw.count {
        let one = raw[next]
        let isBlank = one.allSatisfy(\.isWhitespace), depth = one.prefix { $0 == " " }.count
        if !isBlank, depth <= indent { break }
        if !isBlank, inner == nil { inner = depth }
        body.append(isBlank ? "" : String(one.dropFirst(min(depth, inner ?? depth))))
        next += 1
      }
      while at < lines.count, lines[at].number < next { at += 1 }
      while body.last == "" { body.removeLast() }
      let text: String
      if head.hasPrefix("|") {
        text = body.joined(separator: "\n")
      } else {
        text = body.reduce(into: "") { text, line in
          if line.isEmpty { text += "\n" } else { text += text.isEmpty || text.hasSuffix("\n") ? line : " " + line }
        }
      }
      return head.hasSuffix("-") || text.isEmpty ? text : text + "\n"
    }

    /// Whether a bracket or a quote is still open.
    private func unfinished(_ text: String) -> Bool {
      guard let first = text.first, "[{\"'".contains(first) else { return false }
      var depth = 0, quote: Character?, before: Character = " "
      for character in text {
        if let open = quote {
          if character == open, !(open == "\"" && before == "\\") { quote = nil }
        } else if character == "\"" || character == "'" {
          quote = character
        } else if "[{".contains(character) {
          depth += 1
        } else if "]}".contains(character) {
          depth -= 1
        }
        before = before == "\\" && character == "\\" ? " " : character
      }
      return depth > 0 || quote != nil
    }

    /// A name and what comes after its colon.
    private static func key(of text: String) -> (String, String)? {
      if let quote = text.first, quote == "\"" || quote == "'" {
        guard let end = text.dropFirst().firstIndex(of: quote) else { return nil }
        let after = text[text.index(after: end)...].drop { $0 == " " }
        guard after.hasPrefix(":"), after.count == 1 || after.dropFirst().first == " " else { return nil }
        return (String(text[...end]), after.dropFirst().trimmingCharacters(in: .whitespaces))
      }
      guard let first = text.first, !"[{".contains(first) else { return nil }
      if text.hasSuffix(":"), !text.contains(": ") { return (String(text.dropLast()).trimmingCharacters(in: .whitespaces), "") }
      guard let colon = text.range(of: ": ") else { return nil }
      return (text[..<colon.lowerBound].trimmingCharacters(in: .whitespaces), text[colon.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    private func scalar(_ text: String, _ line: Line, asKey: Bool = false) throws -> Any {
      var flow = Flow(text)
      do {
        let value = try flow.whole(asKey: asKey)
        return value
      } catch { throw refuse(error.localizedDescription, line) }
    }
  }

  /// What is written on one line: words, a number, a list in brackets.
  private struct Flow {
    private let text: [Character]
    private var at = 0

    init(_ text: String) { self.text = Array(text) }

    private func refuse(_ what: String) -> ProcessingError { .conversionFailed(reason: what) }

    mutating func whole(asKey: Bool) throws -> Any {
      if let first = text.first, "[{\"'".contains(first) {
        let value = try value()
        space()
        guard at == text.count else { throw refuse("something follows where nothing should.") }
        return value
      }
      return try Yaml.plain(String(text), asKey: asKey)
    }

    private mutating func space() { while at < text.count, text[at].isWhitespace { at += 1 } }

    private mutating func value() throws -> Any {
      space()
      guard at < text.count else { throw refuse("something is missing.") }
      switch text[at] {
      case "[":
        at += 1
        var items: [Any] = []
        while true {
          space()
          guard at < text.count else { throw refuse("a bracket is not closed.") }
          if text[at] == "]" { at += 1; return items }
          items.append(try value())
          try comma(or: "]")
        }
      case "{":
        at += 1
        var all: [String: Any] = [:]
        while true {
          space()
          guard at < text.count else { throw refuse("a brace is not closed.") }
          if text[at] == "}" { at += 1; return all }
          let name = Separated.describe(try value())
          space()
          guard at < text.count, text[at] == ":" else { throw refuse("a name has nothing after it.") }
          at += 1
          all[name] = try value()
          try comma(or: "}")
        }
      case "\"", "'": return try quoted()
      default:
        let start = at
        while at < text.count, !",]}".contains(text[at]), !(text[at] == ":" && (at + 1 == text.count || text[at + 1] == " ")) { at += 1 }
        return try Yaml.plain(String(text[start..<at]).trimmingCharacters(in: .whitespaces), asKey: false)
      }
    }

    private mutating func comma(or end: Character) throws {
      space()
      guard at < text.count, text[at] == "," || text[at] == end else { throw refuse("a comma is missing.") }
      if text[at] == "," { at += 1 }
    }

    private static let escapes: [Character: String] = ["n": "\n", "t": "\t", "r": "\r", "0": "\0", "\"": "\"", "\\": "\\", "/": "/", "e": "\u{1B}", " ": " "]

    private mutating func quoted() throws -> String {
      let quote = text[at]
      var said = ""
      at += 1
      while at < text.count {
        let character = text[at]
        at += 1
        if quote == "'", character == "'" {
          guard at < text.count, text[at] == "'" else { return said }
          at += 1
          said += "'"
        } else if quote == "\"", character == "\"" {
          return said
        } else if quote == "\"", character == "\\", at < text.count {
          let code = text[at]
          at += 1
          if let length = ["x": 2, "u": 4, "U": 8][code] {
            guard at + length <= text.count, let number = UInt32(String(text[at..<(at + length)]), radix: 16), let scalar = Unicode.Scalar(number) else {
              throw refuse("a character in it cannot be read.")
            }
            said.unicodeScalars.append(scalar)
            at += length
          } else if let known = Self.escapes[code] {
            said += known
          } else {
            throw refuse("a character in it cannot be read.")
          }
        } else {
          said.append(character)
        }
      }
      throw refuse("a quotation is not closed.")
    }
  }

  /// Words with no quotes round them, for what they mean.
  fileprivate static func plain(_ text: String, asKey: Bool) throws -> Any {
    if let first = text.first, "&*!|>%@`".contains(first) {
      throw ProcessingError.conversionFailed(reason: "Forge does not read this part of YAML.")
    }
    if asKey { return text }
    switch text {
    case "", "~", "null", "Null", "NULL": return NSNull()
    case "true", "True", "TRUE": return true
    case "false", "False", "FALSE": return false
    default: break
    }
    if text.wholeMatch(of: #/[-+]?(0|[1-9][0-9]*)/#) != nil, let number = Int(text) { return number }
    if text.wholeMatch(of: #/[-+]?([0-9]+\.[0-9]*|\.[0-9]+|[0-9]+(?=[eE]))([eE][-+]?[0-9]+)?/#) != nil, let number = Double(text) { return number }
    return text
  }

  // MARK: - Writing

  @Sendable static func write(_ value: Any) throws -> String {
    let lines = lines(try DataProcessor.jsonSafe(DataFormats.plain(value)))
    return lines.joined(separator: "\n") + "\n"
  }

  private static func lines(_ value: Any) -> [String] {
    switch value {
    case let record as [String: Any] where !record.isEmpty:
      return record.sorted { $0.key < $1.key }.flatMap { key, inside -> [String] in
        let name = quotedIfNeeded(key)
        if isEmpty(inside) || !(inside is [String: Any] || inside is [Any]) { return [name + ": " + scalar(inside)] }
        return [name + ":"] + lines(inside).map { "  " + $0 }
      }
    case let list as [Any] where !list.isEmpty:
      return list.flatMap { item -> [String] in
        if isEmpty(item) || !(item is [String: Any] || item is [Any]) { return ["- " + scalar(item)] }
        let inside = lines(item)
        return ["- " + inside[0]] + inside.dropFirst().map { "  " + $0 }
      }
    default:
      return [scalar(value)]
    }
  }

  private static func isEmpty(_ value: Any) -> Bool { (value as? [String: Any])?.isEmpty ?? (value as? [Any])?.isEmpty ?? false }

  private static func scalar(_ value: Any) -> String {
    switch value {
    case is NSNull: return "null"
    case let text as String: return quotedIfNeeded(text)
    case let record as [String: Any] where record.isEmpty: return "{}"
    case let list as [Any] where list.isEmpty: return "[]"
    default: return Separated.describe(value)
    }
  }

  /// Plain where it would be read back as the same words.
  private static func quotedIfNeeded(_ text: String) -> String {
    let reads = (try? plain(text, asKey: false)) as? String == text
    let isSafe = reads && text.first?.isWhitespace == false && text.last?.isWhitespace == false
      && !text.contains(": ") && !text.contains(" #") && !text.hasSuffix(":") && !text.contains { $0.isNewline || $0 == "\t" }
      && !"-?:,[]{}#'\"".contains(text.first ?? "-")
    guard !isSafe else { return text }
    let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
  }
}
