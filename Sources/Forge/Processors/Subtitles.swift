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
  static let readableExtensions: Set<String> = ["srt", "vtt", "webvtt", "sbv", "sub", "ass", "ssa", "lrc", "ttml", "dfxp", "itt"]

  /// What can be written. Fewer than can be read, and deliberately: MicroDVD
  /// counts in frames, so writing one means inventing a frame rate.
  static let writableExtensions: Set<String> = ["srt", "vtt", "webvtt", "sbv", "ass", "lrc", "ttml", "txt", "text"]

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
    case "ass", "ssa": cues = parseASS(text)
    case "lrc": cues = parseLRC(text)
    case "ttml", "dfxp", "itt": cues = parseTTML(text)
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

    // A line holding only spaces separates two cues as an empty one does:
    // read literally, the cues on either side of it became one.
    let tidy = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.allSatisfy(\.isWhitespace) ? "" : String($0) }
      .joined(separator: "\n")

    for block in tidy.components(separatedBy: "\n\n") {
      let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard !lines.isEmpty else { continue }

      guard let timing = lines.firstIndex(where: { $0.contains(separator) }) else {
        // No times in it: the rest of what the cue before was saying, after a
        // blank line inside it. Ended there, the second half was thrown away.
        // A header or a note is neither, and is passed over.
        let isAside = ["WEBVTT", "NOTE", "STYLE", "REGION"].contains { lines[0].hasPrefix($0) }
        if !isAside, let last = cues.popLast() {
          cues.append(Cue(start: last.start, end: last.end, text: last.text + "\n\n" + lines.joined(separator: "\n")))
        }
        continue
      }
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

  // MARK: - From speech

  /// What can be read in the time it is on screen: two lines, six seconds.
  static let longestLine = 42
  static let longestCue: TimeInterval = 6
  /// A silence this long is somebody finishing what they were saying.
  private static let pause: TimeInterval = 0.7
  /// How long the last words stay up after they are said.
  private static let linger: TimeInterval = 0.3

  /// Words with times, as cues: one for each thing said, and where that is too
  /// long to read at once, as many even pieces as it takes - a piece cut off
  /// where the room ran out left one word alone on screen for half a second.
  static func cues(from words: [Transcription.Word]) -> [Cue] {
    let groups = sentences(words.filter { !$0.text.isEmpty }).flatMap(readable)
    return groups.enumerated().compactMap { index, group in
      guard let first = group.first, let last = group.last else { return nil }
      let next = groups.indices.contains(index + 1) ? groups[index + 1][0].start : .infinity
      return Cue(
        start: first.start,
        end: max(first.start, min(last.end + linger, next)),
        text: lines(group.map(\.text)).joined(separator: "\n")
      )
    }
  }

  private static func sentences(_ words: [Transcription.Word]) -> [[Transcription.Word]] {
    words.reduce(into: [[Transcription.Word]]()) { groups, word in
      if let last = groups.last?.last, let end = last.text.last, !".?!".contains(end), word.start - last.end < pause {
        groups[groups.count - 1].append(word)
      } else {
        groups.append([word])
      }
    }
  }

  /// The fewest even pieces that can each be read.
  private static func readable(_ words: [Transcription.Word]) -> [[Transcription.Word]] {
    for count in 1...max(1, words.count) {
      let pieces = split(words, into: count)
      let fits = pieces.allSatisfy { piece in
        guard let first = piece.first, let last = piece.last else { return true }
        return last.end - first.start <= longestCue && lines(piece.map(\.text)).count <= 2
      }
      if fits { return pieces }
    }
    return words.map { [$0] }
  }

  /// Cut where the letters are nearest to even.
  private static func split(_ words: [Transcription.Word], into count: Int) -> [[Transcription.Word]] {
    let total = words.reduce(0) { $0 + $1.text.count + 1 }
    var pieces = [[Transcription.Word]](repeating: [], count: count)
    var passed = 0
    for word in words {
      let middle = passed + (word.text.count + 1) / 2
      pieces[min(count - 1, middle * count / max(1, total))].append(word)
      passed += word.text.count + 1
    }
    return pieces.filter { !$0.isEmpty }
  }

  /// One line if it fits; two as even as they can be; more only when it does
  /// not fit in two, which is what says the cue is too long.
  private static func lines(_ words: [String]) -> [String] {
    let whole = words.joined(separator: " ")
    guard whole.count > longestLine, words.count > 1 else { return [whole] }
    var best: [String] = []
    for cut in 1..<words.count {
      let halves = [words[..<cut].joined(separator: " "), words[cut...].joined(separator: " ")]
      guard halves[0].count <= longestLine, halves[1].count <= longestLine else { continue }
      if best.isEmpty || abs(halves[0].count - halves[1].count) < abs(best[0].count - best[1].count) { best = halves }
    }
    if !best.isEmpty { return best }
    return words.reduce(into: [String]()) { lines, word in
      if let line = lines.last, line.count + 1 + word.count <= longestLine {
        lines[lines.count - 1] = line + " " + word
      } else {
        lines.append(word)
      }
    }
  }

  // MARK: - Writing

  static func write(_ cues: [Cue], to url: URL) throws {
    let text: String
    switch url.pathExtension.lowercased() {
    case "vtt", "webvtt": text = webVTT(cues)
    case "sbv": text = sbv(cues)
    case "ass": text = ass(cues)
    case "lrc": text = lrc(cues)
    case "ttml": text = ttml(cues)
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
    // Rounded once, as thousandths, and then taken apart: rounding the
    // fraction alone turned 1.9996 into one second and a thousand thousandths.
    let thousandths = Int((max(0, seconds) * 1000).rounded())
    let whole = thousandths / 1000
    return String(
      format: "%02d:%02d:%02d%@%03d",
      whole / 3600, (whole % 3600) / 60, whole % 60, separator, thousandths % 1000
    )
  }
}

/// Converts one subtitle file into another, or into the words on their own.
final class SubtitleProcessor: FileProcessor, @unchecked Sendable {
  let name = "Subtitle Processor"

  func canProcess(_ file: ProcessableFile) -> Bool {
    Subtitles.reads(file.url.pathExtension)
  }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    Subtitles.writes(Conversions.fileExtension(of: target))
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
