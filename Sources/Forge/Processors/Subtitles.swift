import Foundation
import UniformTypeIdentifiers

/// Subtitle files, which are text with times in them.
///
/// macOS has no parser for any of these and no type for most of them - `.srt`
/// and `.ass` are simply not in the type database - so this is one of the few
/// places where Forge reads a format itself rather than asking a framework.
/// It is worth it because the formats are small: a cue is a start, an end and
/// some words, and everything below is a way of writing that down.
enum Subtitles {

  struct Cue: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
  }

  /// What can be read, by extension. This list is the feature: each entry is a
  /// parser below, and an extension nobody parses is not claimed.
  static let readableExtensions: Set<String> = ["srt", "vtt", "webvtt", "sbv", "sub"]

  /// What can be written. Fewer than can be read, and deliberately: MicroDVD
  /// counts in frames, so writing one means inventing a frame rate.
  static let writableExtensions: Set<String> = ["srt", "vtt", "webvtt", "sbv", "txt", "text"]

  /// The formats that carry cues, as against plain text - which is a thing any
  /// of them can be turned into and is not a subtitle format. Asking a film
  /// for `.srt` means the track inside it; asking for `.txt` still means
  /// transcribe the soundtrack, and this is the line between the two.
  static let cueExtensions: Set<String> = readableExtensions.union(["sbv"])

  static func reads(_ ext: String) -> Bool { readableExtensions.contains(ext.lowercased()) }
  static func writes(_ ext: String) -> Bool { writableExtensions.contains(ext.lowercased()) }
  static func carriesCues(_ ext: String) -> Bool { cueExtensions.contains(ext.lowercased()) }

  // MARK: - Reading

  static func read(_ url: URL) throws -> [Cue] {
    let text = try String(contentsOf: url, encoding: .utf8)
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    let cues: [Cue]
    switch url.pathExtension.lowercased() {
    case "sbv": cues = parseTimed(text, separator: ",")
    case "sub": cues = text.contains("{") ? parseMicroDVD(text) : parseTimed(text, separator: ",")
    default: cues = parseTimed(text, separator: "-->")
    }

    guard !cues.isEmpty else {
      throw ProcessingError.conversionFailed(
        reason: "No subtitles found in \(url.lastPathComponent)"
      )
    }
    return cues
  }

  /// SubRip, WebVTT, SBV and SubViewer differ in punctuation, not in shape:
  /// blocks separated by a blank line, one line holding two times, the rest
  /// being what is said. Parsing them apart would be four copies of this.
  private static func parseTimed(_ text: String, separator: String) -> [Cue] {
    var cues: [Cue] = []

    for block in text.components(separatedBy: "\n\n") {
      let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard !lines.isEmpty else { continue }

      guard let timing = lines.firstIndex(where: { $0.contains(separator) }) else { continue }
      let parts = lines[timing].components(separatedBy: separator)
      guard parts.count >= 2,
            let start = seconds(from: parts[0]),
            let end = seconds(from: parts[1]) else { continue }

      // Everything after the times is the line; a WEBVTT header, a SubRip
      // index or a cue identifier sits before them and is not.
      let said = lines[(timing + 1)...]
        .joined(separator: "\n")
        .replacingOccurrences(of: "[br]", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !said.isEmpty else { continue }

      cues.append(Cue(start: start, end: end, text: said))
    }

    return cues
  }

  /// MicroDVD counts frames rather than time: `{25}{100}the words`. The frame
  /// rate is its own first line when it has one, and 25 when it does not -
  /// which is a guess, and the reason nothing here writes one back.
  private static func parseMicroDVD(_ text: String) -> [Cue] {
    var rate = 25.0
    var cues: [Cue] = []

    for line in text.split(separator: "\n") {
      let fields = String(line).components(separatedBy: "}")
      guard fields.count >= 3 else { continue }
      let first = Double(fields[0].replacingOccurrences(of: "{", with: ""))
      let last = Double(fields[1].replacingOccurrences(of: "{", with: ""))
      guard let first, let last else { continue }
      let said = fields[2...].joined(separator: "}")
        .replacingOccurrences(of: "|", with: "\n")
        .trimmingCharacters(in: .whitespaces)

      // `{1}{1}23.976` is how a file states its rate.
      if first == 1, last == 1, let stated = Double(said), stated > 1 {
        rate = stated
        continue
      }
      guard !said.isEmpty else { continue }
      cues.append(Cue(start: first / rate, end: last / rate, text: said))
    }

    return cues
  }

  /// `01:02:03,456`, `01:02:03.456`, `0:02:03.45` and `02:03.456` all mean a
  /// number of seconds, and every one of them turns up in the wild.
  static func seconds(from stamp: String) -> TimeInterval? {
    let trimmed = stamp.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: ",", with: ".")
    // A WebVTT cue line can carry settings after the time: `... align:start`.
    let time = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    let fields = time.split(separator: ":").map(String.init)
    guard (1...3).contains(fields.count) else { return nil }

    var total: TimeInterval = 0
    for field in fields {
      guard let value = Double(field) else { return nil }
      total = total * 60 + value
    }
    return total
  }

  // MARK: - Writing

  static func write(_ cues: [Cue], to url: URL) throws {
    let text: String
    switch url.pathExtension.lowercased() {
    case "vtt", "webvtt": text = webVTT(cues)
    case "sbv": text = sbv(cues)
    case "txt", "text": text = cues.map(\.text).joined(separator: "\n\n") + "\n"
    default: text = subRip(cues)
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private static func subRip(_ cues: [Cue]) -> String {
    cues.enumerated().map { index, cue in
      """
      \(index + 1)
      \(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))
      \(cue.text)
      """
    }.joined(separator: "\n\n") + "\n"
  }

  private static func webVTT(_ cues: [Cue]) -> String {
    "WEBVTT\n\n" + cues.map { cue in
      """
      \(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))
      \(cue.text)
      """
    }.joined(separator: "\n\n") + "\n"
  }

  private static func sbv(_ cues: [Cue]) -> String {
    cues.map { cue in
      """
      \(stamp(cue.start, separator: ".")),\(stamp(cue.end, separator: "."))
      \(cue.text)
      """
    }.joined(separator: "\n\n") + "\n"
  }

  static func stamp(_ seconds: TimeInterval, separator: String) -> String {
    let whole = max(0, Int(seconds))
    let milliseconds = Int(((max(0, seconds) - Double(whole)) * 1000).rounded())
    return String(
      format: "%02d:%02d:%02d%@%03d",
      whole / 3600, (whole % 3600) / 60, whole % 60, separator, milliseconds
    )
  }
}

/// Converts one subtitle file into another, or into the words on their own.
final class SubtitleProcessor: FileProcessor, @unchecked Sendable {
  let name = "Subtitle Processor"

  func canProcess(_ file: ProcessableFile) -> Bool {
    Subtitles.reads(file.url.pathExtension)
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    guard Subtitles.writes(output.pathExtension) else {
      throw ProcessingError.unsupportedConversion(
        from: UTType(filenameExtension: input.pathExtension) ?? .plainText,
        to: UTType(filenameExtension: output.pathExtension) ?? .plainText
      )
    }

    let cues = try Subtitles.read(input)
    progress(0.5)
    try Subtitles.write(cues, to: output)
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }
}
