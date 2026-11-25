import Foundation
import JavaScriptCore
import UniformTypeIdentifiers

/// Code written short, or written out. It stays the same thing: what was in it
/// is read again from what comes out, and compared.
enum Tidier {
  enum Language { case json, xml, css, javaScript }

  static func language(of type: UTType) -> Language? {
    if type.conforms(to: .json), type.preferredFilenameExtension == "json" { return .json }
    if type == .javaScript || type.goes(by: ["js", "mjs", "cjs"]) { return .javaScript }
    if type.goes(by: ["css"]) { return .css }
    if type.conforms(to: .xml) || type == .svg { return .xml }
    return nil
  }

  static func write(_ tidying: Tool.Tidying, of input: URL, as language: Language, to output: URL) throws -> ProcessingResult {
    let start = Date()
    guard let text = String(data: try Data(contentsOf: input), encoding: .utf8) else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) is not UTF-8 text")
    }
    let made = Data(try tidied(text, language, tidying).utf8)
    try made.write(to: output, options: .atomic)
    return ProcessingResult(outputURL: output, outputSize: Int64(made.count), outputDimensions: nil, duration: Date().timeIntervalSince(start))
  }

  static func tidied(_ text: String, _ language: Language, _ tidying: Tool.Tidying) throws -> String {
    let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    switch language {
    case .json:
      // As it is written: its keys in their order, its numbers to the digit.
      do { _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) } catch {
        throw ProcessingError.conversionFailed(reason: "It is not valid JSON, so it is left as it is.")
      }
      return json(try Code.tokens(of: text, .json), tidying)
    case .css: return try checked(text, .css) { css($0, tidying) }
    case .javaScript:
      let made = try checked(text, .javaScript) { javaScript($0, tidying) }
      // What ran before runs after.
      guard !runs(text) || runs(made) else { throw cannot }
      return made
    case .xml: return try xml(text, tidying)
    }
  }

  private static let cannot = ProcessingError.conversionFailed(reason: "It could not be tidied without changing it, so it is left as it is.")

  /// The same tokens in the same order, or nothing.
  private static func checked(_ text: String, _ language: Code.Kind, _ write: ([Code.Token]) -> String) throws -> String {
    let before = try Code.tokens(of: text, language)
    let made = write(before)
    let after = try Code.tokens(of: made, language)
    func meaning(_ tokens: [Code.Token]) -> [String] {
      tokens.filter { !$0.isComment || $0.text.hasPrefix("/*!") }.map(\.text)
    }
    var one = meaning(before), other = meaning(after)
    // The last of a block needs nothing after it, in CSS.
    if language == .css { one = withoutLastSemicolons(one); other = withoutLastSemicolons(other) }
    guard one == other else { throw cannot }
    return made
  }

  private static func withoutLastSemicolons(_ tokens: [String]) -> [String] {
    tokens.enumerated().filter { index, text in !(text == ";" && index + 1 < tokens.count && tokens[index + 1] == "}") }.map(\.element)
  }

  private static func runs(_ text: String) -> Bool {
    guard let context = JSGlobalContextCreate(nil), let script = JSStringCreateWithUTF8CString(text) else { return false }
    defer { JSStringRelease(script); JSGlobalContextRelease(context) }
    return JSCheckScriptSyntax(context, script, nil, 1, nil)
  }

  // MARK: - JSON

  private static func json(_ tokens: [Code.Token], _ tidying: Tool.Tidying) -> String {
    guard tidying == .pretty else { return tokens.map(\.text).joined() }
    var made = "", depth = 0
    for (index, token) in tokens.enumerated() {
      let before = index > 0 ? tokens[index - 1].text : ""
      switch token.text {
      case "}", "]":
        depth -= 1
        if before != "{", before != "[" { made += line(depth) }
        made += token.text
      case ",": made += ","
      case ":": made += ": "
      default:
        if ["{", "[", ","].contains(before) { made += line(depth) }
        made += token.text
        if token.text == "{" || token.text == "[" { depth += 1 }
      }
    }
    return made + "\n"
  }

  private static func line(_ depth: Int) -> String { "\n" + String(repeating: "  ", count: max(0, depth)) }

  // MARK: - CSS

  private static func css(_ tokens: [Code.Token], _ tidying: Tool.Tidying) -> String {
    let isShort = tidying == .min
    var made = "", depth = 0, round = 0
    let kept = tokens.filter { !isShort || !$0.isComment || $0.text.hasPrefix("/*!") }
    for (index, token) in kept.enumerated() {
      let before = index > 0 ? kept[index - 1] : nil
      // Where there was a space there may have to be one: `.a .b` is not `.a.b`.
      let needsSpace = token.hadSpace && before.map { !["{", "}", ";", ",", "("].contains($0.text) } ?? false
        && !["{", "}", ";", ",", ")"].contains(token.text)
        && !(isShort && round == 0 && (token.text == ":" || before?.text == ":") && depth > 0 && isDeclaration(kept, at: index))
      if token.text == "(" || token.text == "[" { round += 1 }
      if token.text == ")" || token.text == "]" { round = max(0, round - 1) }
      if isShort {
        if token.text == "{" { depth += 1 }
        if token.text == "}" {
          depth -= 1
          if made.hasSuffix(";") { made.removeLast() }
        }
        made += (needsSpace ? " " : "") + token.text
        continue
      }
      switch token.text {
      case "{" where round == 0:
        made += (made.isEmpty || made.hasSuffix(" ") || made.hasSuffix("\n") ? "" : " ") + "{"
        depth += 1
      case "}" where round == 0:
        depth -= 1
        made += line(depth) + "}"
      default:
        if token.isComment, !token.startsLine, before != nil { made += " " + token.text; continue }
        if let before, round == 0 || token.text == "(" , ["{", "}", ";"].contains(before.text) || before.isComment {
          made += (before.text == "}" && depth == 0 ? "\n" : "") + line(depth)
        } else if needsSpace || (before?.text == "," ) || (before?.text == ":" && depth > 0 && round == 0 && isDeclaration(kept, at: index - 1)) {
          made += " "
        }
        made += token.text
      }
    }
    return isShort ? made : made.trimmingCharacters(in: .newlines) + "\n"
  }

  /// Whether what is here is `name: value`, and not the beginning of a rule.
  private static func isDeclaration(_ tokens: [Code.Token], at index: Int) -> Bool {
    var round = 0
    for token in tokens[max(0, index)...] {
      if token.text == "(" { round += 1 }
      if token.text == ")" { round -= 1 }
      guard round <= 0 else { continue }
      if token.text == ";" || token.text == "}" { return true }
      if token.text == "{" { return false }
    }
    return true
  }

  // MARK: - JavaScript

  private static func javaScript(_ tokens: [Code.Token], _ tidying: Tool.Tidying) -> String {
    let isShort = tidying == .min
    let kept = tokens.filter { !isShort || !$0.isComment || $0.text.hasPrefix("/*!") }
    var made = "", open: [String] = []
    for (index, token) in kept.enumerated() {
      let before = index > 0 ? kept[index - 1] : nil
      if isShort {
        if let before {
          // A line ends a statement where nothing else does, and is kept
          // wherever it might be what does. After a comment to the end of a
          // line there is always one.
          if token.startsLine, !endsNothing(before.text), !beginsNothing(token.text) { made += "\n" }
          else if joins(before.text, token.text) || (token.hadSpace && isRisky(before, token)) { made += " " }
        }
        made += token.text
        continue
      }
      let isClosing = ["}", "]", ")"].contains(token.text)
      if isClosing, !open.isEmpty { open.removeLast() }
      let depth = open.count
      if let before {
        let opensBlock = before.text == "{" && !(token.text == "}")
        let afterStatement = before.text == ";" && open.last != "("
        let closesBlock = token.text == "}" && before.text != "{"
        if token.startsLine || before.isLineComment {
          made += (token.blankBefore && !isClosing && before.text != "{" ? "\n" : "") + line(depth)
        } else if (opensBlock || closesBlock), !before.isComment, isWide(kept, around: index, opening: opensBlock) {
          made += line(depth)
        } else if afterStatement, !token.isComment {
          made += line(depth)
        } else if token.hadSpace || joins(before.text, token.text) || before.text == ","
          || (token.text == "{" && (before.text == ")" || before.text.last.map(isWord) ?? false))
          || (before.text == "}" && token.text.first.map(isWord) ?? false && !before.text.hasSuffix("`")) {
          made += " "
        }
      }
      made += token.text
      if ["{", "[", "("].contains(token.text) { open.append(token.text) }
    }
    return isShort ? made : made + "\n"
  }

  /// A block with a statement in it is written over several lines; `{ a, b }` is
  /// not.
  private static func isWide(_ tokens: [Code.Token], around index: Int, opening: Bool) -> Bool {
    var depth = 0
    let path = opening ? Array(tokens[index...]) : tokens[..<index].reversed().map { $0 }
    for token in path {
      let isIn = ["{", "(", "["].contains(token.text), isOut = ["}", ")", "]"].contains(token.text)
      if opening ? isOut : isIn { if depth == 0 { return false }; depth -= 1 }
      if opening ? isIn : isOut { depth += 1 }
      if depth == 0, token.text == ";" { return true }
    }
    return false
  }

  private static func isWord(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "$" || character == "#" || character == "@" || !character.isASCII || character == "\\"
  }

  /// Written together they would be something else.
  private static func joins(_ one: String, _ other: String) -> Bool {
    guard let last = one.last, let first = other.first else { return false }
    if isWord(last), isWord(first) { return true }
    if (last == "+" && first == "+") || (last == "-" && first == "-") || (last == "/" && first == "/") || (last == "<" && first == "!") { return true }
    return last.isNumber && first == "."
  }

  /// Operators and what is made of them: kept apart if they were.
  private static func isRisky(_ one: Code.Token, _ other: Code.Token) -> Bool {
    guard let last = one.text.last, let first = other.text.first else { return false }
    let marks = "+-*/%&|^!=<>?.~"
    return marks.contains(last) && marks.contains(first)
  }

  private static func endsNothing(_ text: String) -> Bool { ["{", "(", "[", ",", ";", "=", "=>", "&", "|", ":", "?"].contains(text) }
  private static func beginsNothing(_ text: String) -> Bool { [")", "]", "}", ",", ";", ".", ":"].contains(text) }

  // MARK: - XML

  /// Words, where a space between two of them is a space.
  private static let inline: Set<String> = ["text", "tspan", "textpath", "pre", "p", "span", "a", "b", "i", "em", "strong", "td", "li"]

  private struct Mark {
    enum Kind { case opening, closing, empty, comment, other, words }
    let text: String
    let kind: Kind
    var name = ""
    /// Whether the spaces in it say anything.
    var isProse = false
  }

  /// Piece by piece, and every piece as it was: what is changed is the space
  /// between them, where it says nothing.
  private static func xml(_ text: String, _ tidying: Tool.Tidying) throws -> String {
    guard XMLParser(data: Data(text.utf8)).parse() else {
      throw ProcessingError.conversionFailed(reason: "It is not valid XML, so it is left as it is.")
    }
    var marks = try xmlMarks(text)
    findProse(&marks)
    var made = "", depth = 0, prose = 0
    for (index, mark) in marks.enumerated() {
      let wasProse = prose > 0
      if mark.kind == .closing {
        depth -= 1
        if wasProse { prose -= 1 }
      }
      let isBlank = mark.kind == .words && mark.text.allSatisfy(\.isWhitespace)
      if !wasProse {
        if isBlank || (tidying == .min && mark.kind == .comment) { continue }
        let before = index > 0 ? marks[..<index].last { !($0.kind == .words && $0.text.allSatisfy(\.isWhitespace)) } : nil
        let closesAtOnce = mark.kind == .closing && before?.kind == .opening
        if tidying == .pretty, !made.isEmpty, !closesAtOnce { made += line(depth) }
      }
      made += mark.text
      if mark.kind == .opening {
        depth += 1
        if wasProse || mark.isProse { prose += 1 }
      }
    }
    if tidying == .pretty { made += "\n" }
    guard XMLParser(data: Data(made.utf8)).parse() else { throw cannot }
    return made
  }

  private static func xmlMarks(_ text: String) throws -> [Mark] {
    var marks: [Mark] = [], rest = Substring(text)
    func take(upTo end: String) throws -> String {
      guard let found = rest.range(of: end) else { throw cannot }
      defer { rest = rest[found.upperBound...] }
      return String(rest[..<found.upperBound])
    }
    while !rest.isEmpty {
      if rest.hasPrefix("<!--") { marks.append(Mark(text: try take(upTo: "-->"), kind: .comment)) }
      else if rest.hasPrefix("<![CDATA[") { marks.append(Mark(text: try take(upTo: "]]>"), kind: .words)) }
      else if rest.hasPrefix("<?") { marks.append(Mark(text: try take(upTo: "?>"), kind: .other)) }
      else if rest.hasPrefix("<!") {
        // A document type may have a list of its own in brackets.
        let bracket = rest.firstIndex(of: "["), end = rest.firstIndex(of: ">")
        let isLong = bracket.flatMap { open in end.map { open < $0 } } ?? false
        marks.append(Mark(text: try isLong ? take(upTo: "]") + take(upTo: ">") : take(upTo: ">"), kind: .other))
      } else if rest.hasPrefix("<") {
        var quote: Character?, end = rest.startIndex
        while end < rest.endIndex {
          let character = rest[end]
          if let open = quote { if character == open { quote = nil } } else if character == "\"" || character == "'" { quote = character } else if character == ">" { break }
          end = rest.index(after: end)
        }
        guard end < rest.endIndex else { throw cannot }
        let tag = String(rest[...end])
        rest = rest[rest.index(after: end)...]
        let name = String(tag.drop { "</".contains($0) }.prefix { !$0.isWhitespace && !"/>".contains($0) })
        var mark = Mark(text: tag, kind: tag.hasPrefix("</") ? .closing : tag.hasSuffix("/>") ? .empty : .opening, name: name)
        mark.isProse = inline.contains(name.split(separator: ":").last.map { $0.lowercased() } ?? "") || tag.contains("xml:space")
        marks.append(mark)
      } else {
        let end = rest.firstIndex(of: "<") ?? rest.endIndex
        marks.append(Mark(text: String(rest[..<end]), kind: .words))
        rest = rest[end...]
      }
    }
    return marks
  }

  /// What has words straight in it has spaces that mean something.
  private static func findProse(_ marks: inout [Mark]) {
    var open: [Int] = []
    for (index, mark) in marks.enumerated() {
      switch mark.kind {
      case .opening: open.append(index)
      case .closing: _ = open.popLast()
      case .words: if !mark.text.allSatisfy(\.isWhitespace), let holder = open.last { marks[holder].isProse = true }
      case .empty, .comment, .other: break
      }
    }
  }
}

/// Code as the pieces it is made of.
enum Code {
  enum Kind { case json, css, javaScript }

  struct Token {
    var text: String
    /// What was between it and the one before.
    var hadSpace = false
    var startsLine = false
    var blankBefore = false
    var isComment = false
    var isLineComment: Bool { isComment && text.hasPrefix("//") }
  }

  private static let broken = ProcessingError.conversionFailed(reason: "It cannot be read to the end, so it is left as it is.")

  static func tokens(of text: String, _ kind: Kind) throws -> [Token] {
    let all = Array(text.unicodeScalars)
    var tokens: [Token] = [], at = 0
    var space = false, lines = 0
    // Which brackets are open, and whether a `}` goes back into a template.
    var open: [String] = []
    // `if (a) /b/` is a pattern, and `(a) / b` is not.
    var closedControl = false

    func isLine(_ scalar: Unicode.Scalar) -> Bool { [10, 13, 0x2028, 0x2029].contains(scalar.value) }
    func piece(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(all[from..<to])) }
    func add(_ end: Int, comment: Bool = false) {
      var token = Token(text: piece(at, end))
      token.hadSpace = space || lines > 0
      token.startsLine = lines > 0
      token.blankBefore = lines > 1
      token.isComment = comment
      tokens.append(token)
      // A comment over several lines is a line's end as well.
      lines = comment && token.text.hasPrefix("/*") && token.text.contains(where: \.isNewline) ? 1 : 0
      space = comment
      at = end
    }
    func string(_ quote: Unicode.Scalar) throws -> Int {
      var end = at + 1
      while end < all.count, all[end] != quote {
        if isLine(all[end]), kind != .css, all[end].value < 0x2028 { throw broken }
        end += all[end] == "\\" ? 2 : 1
      }
      guard end < all.count else { throw broken }
      return end + 1
    }
    /// To the end of it, or to where code begins inside it.
    func template(_ from: Int) throws -> (end: Int, opens: Bool) {
      var end = from
      while end < all.count {
        if all[end] == "\\" { end += 2; continue }
        if all[end] == "`" { return (end + 1, false) }
        if all[end] == "$", end + 1 < all.count, all[end + 1] == "{" { return (end + 2, true) }
        end += 1
      }
      throw broken
    }
    func word(_ scalar: Unicode.Scalar) -> Bool {
      CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" || scalar.value > 127 || scalar == "\\"
        || (kind == .css && (scalar == "-" || scalar == "%" || scalar == "#" || scalar == "." || scalar == "@" || scalar == "!"))
        || (kind == .json && (scalar == "-" || scalar == "+" || scalar == "."))
        || (kind == .javaScript && (scalar == "#" || scalar == "@"))
    }

    if kind == .javaScript, all.starts(with: "#!".unicodeScalars) {
      add(all.firstIndex(where: isLine) ?? all.count, comment: false)
      lines = 1
    }
    while at < all.count {
      try Task.checkCancellation()
      let scalar = all[at], next = at + 1 < all.count ? all[at + 1] : " "
      if isLine(scalar) {
        // A carriage return and a line feed are one.
        if !(scalar.value == 10 && at > 0 && all[at - 1].value == 13) { lines += 1 }
        at += 1
      } else if CharacterSet.whitespaces.contains(scalar) || scalar.value == 0xFEFF || scalar.value < 32 {
        space = true
        at += 1
      } else if scalar == "/", next == "*", kind != .json {
        var end = at + 2
        while end + 1 < all.count, !(all[end] == "*" && all[end + 1] == "/") { end += 1 }
        guard end + 1 < all.count else { throw broken }
        add(end + 2, comment: true)
      } else if scalar == "/", next == "/", kind == .javaScript {
        add(all[at...].firstIndex(where: isLine) ?? all.count, comment: true)
      } else if scalar == "\"" || (scalar == "'" && kind != .json) {
        add(try string(scalar))
      } else if scalar == "`", kind == .javaScript {
        let (end, opens) = try template(at + 1)
        add(end)
        if opens { open.append("`") }
      } else if scalar == "}", kind == .javaScript, open.last == "`" {
        open.removeLast()
        let (end, opens) = try template(at + 1)
        add(end)
        if opens { open.append("`") }
      } else if scalar == "/", kind == .javaScript, beginsPattern(after: tokens, onALine: lines > 0, afterControl: closedControl) {
        var end = at + 1, inSet = false
        while end < all.count, inSet || all[end] != "/" {
          if isLine(all[end]) { throw broken }
          if all[end] == "[" { inSet = true }
          if all[end] == "]" { inSet = false }
          end += all[end] == "\\" ? 2 : 1
        }
        guard end < all.count else { throw broken }
        end += 1
        while end < all.count, word(all[end]) { end += 1 }
        add(end)
      } else if kind == .css, scalar == "u" || scalar == "U", piece(at, min(all.count, at + 4)).lowercased() == "url(" {
        // What is in there is as it is, with or without quotation marks.
        var end = at + 4
        while end < all.count, all[end] != ")" {
          if all[end] == "\"" || all[end] == "'" {
            let quote = all[end]
            end += 1
            while end < all.count, all[end] != quote { end += all[end] == "\\" ? 2 : 1 }
          }
          end += end < all.count && all[end] == "\\" ? 2 : 1
        }
        guard end < all.count else { throw broken }
        add(end + 1)
      } else if word(scalar) {
        var end = at
        while end < all.count, word(all[end]) { end += all[end] == "\\" ? 2 : 1 }
        // 1.5, and 1e-5.
        if kind == .javaScript, CharacterSet.decimalDigits.contains(scalar) { end = number(all, from: at, end) }
        add(min(end, all.count))
      } else {
        if scalar == "(" || scalar == "[" || scalar == "{" {
          let isControl = scalar == "(" && ["if", "while", "for", "with"].contains(tokens.last { !$0.isComment }?.text ?? "")
          open.append(isControl ? "control" : String(scalar))
        }
        if scalar == ")" || scalar == "]" || scalar == "}" {
          guard !open.isEmpty else { throw broken }
          closedControl = open.removeLast() == "control"
        }
        add(kind == .javaScript ? mark(all, at) : at + 1)
      }
    }
    guard open.isEmpty else { throw broken }
    return tokens
  }

  private static func number(_ all: [Unicode.Scalar], from: Int, _ end: Int) -> Int {
    var end = end
    let digits = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    let isOther = end - from > 1 && all[from] == "0" && "xXbBoO".unicodeScalars.contains(all[from + 1])
    guard !isOther else { return end }
    if end < all.count, all[end] == "." {
      end += 1
      while end < all.count, digits.contains(all[end]) { end += 1 }
    }
    if end < all.count, all[end] == "+" || all[end] == "-", all[end - 1] == "e" || all[end - 1] == "E" {
      end += 1
      while end < all.count, digits.contains(all[end]) { end += 1 }
    }
    return end
  }

  private static let marks: [[Unicode.Scalar]] = [
    ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
    "=>", "==", "!=", "<=", ">=", "++", "--", "&&", "||", "??", "?.", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "**", "<<", ">>",
  ].map { Array($0.unicodeScalars) }

  private static func mark(_ all: [Unicode.Scalar], _ at: Int) -> Int {
    at + (marks.first { at + $0.count <= all.count && Array(all[at..<(at + $0.count)]) == $0 }?.count ?? 1)
  }

  private static let beforePattern: Set<String> = [
    "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await",
  ]

  /// A slash after something is a division, and after nothing the beginning of
  /// a pattern. After `)` and `}` it can be either.
  private static func beginsPattern(after tokens: [Token], onALine: Bool, afterControl: Bool) -> Bool {
    guard let last = tokens.last(where: { !$0.isComment })?.text else { return true }
    if beforePattern.contains(last) { return true }
    if last == ")" { return afterControl }
    if last == "}" { return onALine }
    if last == "]" || last == "++" || last == "--" { return false }
    guard let end = last.unicodeScalars.last else { return true }
    if end == "`" || end == "\"" || end == "'" { return false }
    // A pattern before it, with or without its flags.
    if last.hasPrefix("/"), last.count > 1, last != "/=" { return false }
    return !(CharacterSet.alphanumerics.contains(end) || end == "_" || end == "$" || end.value > 127)
  }
}
