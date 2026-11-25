import Foundation
import UniformTypeIdentifiers

/// A message saved as a file: who wrote it, when, about what, and the words.
///
/// Read as words and never as a page. A page fetches its pictures when it is
/// laid out, and the pictures in a message are there to say it was opened.
enum Email {
  static let type = UTType(filenameExtension: "eml")
  private static let deepest = 12

  struct Message: Equatable {
    var headers: [(name: String, value: String)] = []
    var text = ""
    static func == (a: Message, b: Message) -> Bool { a.text == b.text && a.headers.map { $0.name + $0.value } == b.headers.map { $0.name + $0.value } }
  }

  static func read(_ url: URL) throws -> Message {
    // One character a byte until a part says what its bytes are.
    guard let raw = String(data: try Data(contentsOf: url), encoding: .isoLatin1) else {
      throw ProcessingError.conversionFailed(reason: "Cannot read \(url.lastPathComponent)")
    }
    let part = Part(raw.replacingOccurrences(of: "\r\n", with: "\n"))
    guard !part.headers.isEmpty else {
      throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is not a message")
    }
    var message = Message()
    for name in ["From", "To", "Cc", "Date", "Subject"] {
      if let value = part.header(name) { message.headers.append((name, words(value))) }
    }
    message.text = body(of: part, depth: 0) ?? ""
    return message
  }

  static func text(of url: URL) throws -> String {
    let message = try read(url)
    return message.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n") + "\n\n" + message.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  private struct Part {
    let headers: [(String, String)]
    let body: String

    init(_ raw: String) {
      let split = raw.range(of: "\n\n")
      let head = split.map { String(raw[..<$0.lowerBound]) } ?? raw
      body = split.map { String(raw[$0.upperBound...]) } ?? ""
      // A line that begins with a space goes on from the one before.
      let lines = head.replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression).split(separator: "\n")
      headers = lines.compactMap { line in
        guard let colon = line.firstIndex(of: ":"), !line[..<colon].contains(" ") else { return nil }
        return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
      }
    }

    func header(_ name: String) -> String? { headers.first { $0.0 == name.lowercased() }?.1 }

    func parameter(_ name: String) -> String? {
      guard let content = header("content-type"),
            let match = content.range(of: "(?i)\(name)=(\"[^\"]*\"|[^;\\s]+)", options: .regularExpression) else { return nil }
      return content[match].split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }
  }

  private static func body(of part: Part, depth: Int) -> String? {
    guard depth < deepest else { return nil }
    let kind = (part.header("content-type") ?? "text/plain").lowercased()
    if kind.hasPrefix("multipart/"), let boundary = part.parameter("boundary"), !boundary.isEmpty {
      let pieces = part.body.components(separatedBy: "--" + boundary).dropFirst().filter { !$0.hasPrefix("--") }
        .map { Part(String($0.drop { $0 == "\n" })) }
      let isPlain: (Part) -> Bool = { ($0.header("content-type") ?? "text/plain").lowercased().hasPrefix("text/plain") }
      // The same thing said twice: plainly where it is said plainly.
      if kind.hasPrefix("multipart/alternative"), let plain = pieces.first(where: isPlain), let text = body(of: plain, depth: depth + 1) { return text }
      let texts = pieces.filter { !($0.header("content-disposition") ?? "").lowercased().hasPrefix("attachment") }
        .compactMap { body(of: $0, depth: depth + 1) }
      return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
    guard kind.hasPrefix("text/") else { return nil }
    let text = decode(bytes(of: part.body, encoded: part.header("content-transfer-encoding")), charset: part.parameter("charset"))
    return kind.hasPrefix("text/html") ? plain(html: text) : text
  }

  private static func bytes(of body: String, encoded: String?) -> Data {
    switch encoded?.lowercased().trimmingCharacters(in: .whitespaces) {
    case "base64": return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
    case "quoted-printable": return quoted(body.replacingOccurrences(of: "=\n", with: ""))
    default: return body.data(using: .isoLatin1) ?? Data(body.utf8)
    }
  }

  private static func quoted(_ text: String, underscoreIsSpace: Bool = false) -> Data {
    var data = Data()
    let source = [UInt8](text.data(using: .isoLatin1) ?? Data(text.utf8))
    var index = 0
    while index < source.count {
      if source[index] == UInt8(ascii: "="), index + 2 < source.count,
         let byte = UInt8(String(decoding: source[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
        data.append(byte)
        index += 3
      } else {
        data.append(underscoreIsSpace && source[index] == UInt8(ascii: "_") ? UInt8(ascii: " ") : source[index])
        index += 1
      }
    }
    return data
  }

  private static func decode(_ data: Data, charset: String?) -> String {
    let named = charset.map { CFStringConvertIANACharSetNameToEncoding($0 as CFString) } ?? kCFStringEncodingInvalidId
    if named != kCFStringEncodingInvalidId,
       let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(named))) { return text }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
  }

  /// `=?utf-8?Q?Perch=C3=A9?=`, as headers say what is not ASCII.
  private static func words(_ value: String) -> String {
    let joined = value.replacingOccurrences(of: "\\?=\\s+=\\?", with: "?==?", options: .regularExpression)
    var result = "", rest = Substring(joined)
    while let match = rest.firstMatch(of: #/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/#) {
      result += decode(Data(rest[..<match.range.lowerBound].unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }), charset: nil)
      let data = match.2.lowercased() == "b" ? Data(base64Encoded: String(match.3)) ?? Data() : quoted(String(match.3), underscoreIsSpace: true)
      result += decode(data, charset: String(match.1))
      rest = rest[match.range.upperBound...]
    }
    return result + decode(Data(rest.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }), charset: nil)
  }

  static func plain(html: String) -> String {
    var text = html
    for (pattern, with) in [
      ("(?is)<(script|style|head)\\b.*?</\\1>", ""), ("(?i)<br\\s*/?>", "\n"), ("(?i)</(p|div|tr|li|h[1-6])>", "\n"), ("(?s)<[^>]*>", ""), ("\n{3,}", "\n\n"),
    ] { text = text.replacingOccurrences(of: pattern, with: with, options: .regularExpression) }
    text = text.replacingOccurrences(of: "&nbsp;", with: " ")
    return (CFXMLCreateStringByUnescapingEntities(nil, text as CFString, nil) as String?) ?? text
  }
}
