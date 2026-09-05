import Foundation

/// What a converted file is called.
///
/// A template is a sentence with holes in it: `{name}_{counter:03}` over a
/// folder of photographs gives `holiday_001`, `holiday_002`. Some of the holes
/// can only be filled once the file exists - nothing knows how wide a resized
/// picture came out, or what quality a size ceiling settled on, until it has
/// been written - so filling them happens in two passes, and a hole that cannot
/// be filled yet is left exactly as it was for the second one.
///
/// A token nobody recognises is left alone. A name that says `{nmae}` is a typo
/// somebody can see and fix; the same name silently reduced to nothing is a
/// mystery.
enum NameTemplate {

  /// What is known before the conversion runs.
  struct Static {
    /// The original's name, without its extension.
    var name: String
    /// The folder the original was in.
    var parent: String
    /// The file's own date, or now.
    var date: Date
    /// Which file this is in the batch, counting from one.
    var counter: Int
    /// The extension the output will have.
    var ext: String
    /// A quality the chain asked for outright, if it did.
    var quality: Int?
    /// A codec the chain asked for outright, if it did.
    var codec: String?
    /// The answers to a preset's own questions, by their keys.
    var parameters: [String: String] = [:]

    init(
      name: String,
      parent: String = "",
      date: Date = Date(),
      counter: Int = 1,
      ext: String = "",
      quality: Int? = nil,
      codec: String? = nil,
      parameters: [String: String] = [:]
    ) {
      self.name = name
      self.parent = parent
      self.date = date
      self.counter = counter
      self.ext = ext
      self.quality = quality
      self.codec = codec
      self.parameters = parameters
    }
  }

  /// What is only known once the file has been written.
  struct Dynamic {
    var width: Int?
    var height: Int?
    var bytes: Int64?
    /// What a size ceiling settled on, which is a result rather than a setting.
    var quality: Int?

    init(width: Int? = nil, height: Int? = nil, bytes: Int64? = nil, quality: Int? = nil) {
      self.width = width
      self.height = height
      self.bytes = bytes
      self.quality = quality
    }
  }

  /// The tokens Forge knows, and what each is for.
  ///
  /// Listed rather than described in prose because the menu in the editor is
  /// built from this: a token that exists is a token somebody can find.
  enum Token: String, CaseIterable, Identifiable {
    case name, parent, date, counter, format, ext, quality, codec
    case width, height, dimensions, size

    var id: String { rawValue }

    /// Whether it can only be answered after the file has been written.
    var isDynamic: Bool {
      switch self {
      case .width, .height, .dimensions, .size: return true
      case .name, .parent, .date, .counter, .format, .ext, .quality, .codec: return false
      }
    }

    var summary: String {
      switch self {
      case .name: return "The original's name, without its extension"
      case .parent: return "The folder it came from"
      case .date: return "The file's date. {date:yyyy-MM-dd} sets the shape"
      case .counter: return "Its place in the batch. {counter:03} pads to 001"
      case .format, .ext: return "The new extension, like jpeg"
      case .quality: return "The quality used, including what a size ceiling settled on"
      case .codec: return "The codec, where one was chosen"
      case .width: return "How wide it came out"
      case .height: return "How tall it came out"
      case .dimensions: return "How wide by how tall, like 1920x1080"
      case .size: return "How large the finished file is"
      }
    }

    var example: String { "{\(rawValue)}" }
  }

  /// Fill in what can be filled in.
  ///
  /// - Parameter dynamic: what the finished file turned out to be, or nil on
  ///   the first pass. Without it, the tokens that need it are left in the name
  ///   untouched, so the second pass can find them.
  static func resolve(
    _ template: String,
    with context: Static,
    and dynamic: Dynamic? = nil
  ) -> String {
    var result = ""
    var rest = Substring(template)

    while let open = rest.firstIndex(of: "{") {
      result += rest[rest.startIndex..<open]
      guard let close = rest[open...].firstIndex(of: "}") else {
        // An unclosed brace is text, not a token.
        result += rest[open...]
        return finish(result)
      }

      let body = rest[rest.index(after: open)..<close]
      let pieces = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      let key = String(pieces.first ?? "")
      let argument = pieces.count > 1 ? String(pieces[1]) : nil

      result += value(for: key, argument: argument, context: context, dynamic: dynamic)
        ?? String(rest[open...close])
      rest = rest[rest.index(after: close)...]
    }

    result += rest
    return finish(result)
  }

  /// Whether a name still has holes in it that only a finished file can fill.
  static func needsSecondPass(_ name: String) -> Bool {
    Token.allCases.filter(\.isDynamic).contains { name.contains($0.example) }
  }

  // MARK: - Private

  /// The text a token stands for.
  ///
  /// Nil means "leave this alone", which covers both a token nobody recognises
  /// and one whose answer is not known yet. An empty string means the token was
  /// understood and had nothing to say - an unanswered question, a codec nobody
  /// chose - and that comes out of the name rather than into it.
  private static func value(
    for key: String,
    argument: String?,
    context: Static,
    dynamic: Dynamic?
  ) -> String? {
    if let answer = context.parameters[key] { return answer }

    guard let token = Token(rawValue: key) else { return nil }
    if token.isDynamic, dynamic == nil { return nil }

    switch token {
    case .name:
      return context.name
    case .parent:
      return context.parent
    case .counter:
      return pad(context.counter, to: argument)
    case .date:
      return formatted(context.date, as: argument)
    case .format, .ext:
      return context.ext
    case .codec:
      return context.codec ?? ""
    case .quality:
      // What the encoder was told, unless a ceiling settled on something else.
      return (dynamic?.quality ?? context.quality).map(String.init) ?? ""
    case .width:
      return dynamic?.width.map(String.init) ?? ""
    case .height:
      return dynamic?.height.map(String.init) ?? ""
    case .dimensions:
      guard let width = dynamic?.width, let height = dynamic?.height else { return "" }
      return "\(width)x\(height)"
    case .size:
      guard let bytes = dynamic?.bytes else { return "" }
      return bytes.formatted(.byteCount(style: .file)).replacingOccurrences(of: " ", with: "")
    }
  }

  private static func pad(_ number: Int, to argument: String?) -> String {
    guard let argument, let width = Int(argument), width > 0 else { return String(number) }
    return String(format: "%0\(width)d", number)
  }

  private static func formatted(_ date: Date, as pattern: String?) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = pattern ?? "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  /// A name that is only separators, or nothing at all, is not a name.
  private static func finish(_ name: String) -> String {
    var trimmed = name.trimmingCharacters(in: .whitespaces)
    while let last = trimmed.last, last == "_" || last == "-" || last == " " {
      trimmed.removeLast()
    }
    return trimmed
  }
}
