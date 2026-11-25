import Foundation

/// The subtitles that are not a list of times and words one under the other.
extension Subtitles {
  // MARK: - Advanced SubStation

  static func parseASS(_ text: String) -> [Cue] {
    var columns = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"], inEvents = false, cues: [Cue] = []
    for line in text.split(separator: "\n") {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]" }
      guard inEvents else { continue }
      if line.lowercased().hasPrefix("format:") {
        columns = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      } else if line.lowercased().hasPrefix("dialogue:") {
        // The words are last, and may have commas of their own.
        let fields = line.dropFirst(9).split(separator: ",", maxSplits: columns.count - 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let from = columns.firstIndex(of: "start"), let to = columns.firstIndex(of: "end"), fields.count == columns.count,
              let start = seconds(from: fields[from]), let end = seconds(from: fields[to]), let words = fields.last else { continue }
        let said = words.replacing(#/\{[^}]*\}/#, with: "").replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        if !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cues.append(Cue(start: start, end: end, text: said)) }
      }
    }
    return cues.sorted { $0.start < $1.start }
  }

  static func ass(_ cues: [Cue]) -> String {
    func stamp(_ seconds: TimeInterval) -> String {
      let hundredths = Int((max(0, seconds) * 100).rounded())
      return String(format: "%d:%02d:%02d.%02d", hundredths / 360_000, hundredths / 6000 % 60, hundredths / 100 % 60, hundredths % 100)
    }
    let lines = cues.map { "Dialogue: 0,\(stamp($0.start)),\(stamp($0.end)),Default,,0,0,0,,\(plain($0.text).replacingOccurrences(of: "\n", with: "\\N"))" }
    return """
      [Script Info]
      ScriptType: v4.00+
      PlayResX: 1920
      PlayResY: 1080

      [V4+ Styles]
      Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
      Style: Default,Helvetica,64,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,1,2,60,60,60,1

      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      \(lines.joined(separator: "\n"))

      """
  }

  /// Without the marks of a web page, which SubRip has and the rest do not.
  static func plain(_ text: String) -> String { text.replacing(#/<\/?[a-zA-Z][^>]*>/#, with: "") }

  // MARK: - Lyrics

  /// How long the last line of a song is sung.
  private static let lastLine: TimeInterval = 5

  static func parseLRC(_ text: String) -> [Cue] {
    let lines = text.split(separator: "\n").flatMap { line -> [(TimeInterval, String)] in
      var rest = Substring(line.trimmingCharacters(in: .whitespaces)), times: [TimeInterval] = []
      while let match = rest.prefixMatch(of: #/\[(\d+):(\d+(?:[.:]\d+)?)\]/#) {
        if let minutes = Double(match.1), let seconds = Double(match.2.replacingOccurrences(of: ":", with: ".")) { times.append(minutes * 60 + seconds) }
        rest = rest[match.range.upperBound...]
      }
      let words = rest.replacing(#/<\d+:\d+(?:\.\d+)?>/#, with: "").trimmingCharacters(in: .whitespaces)
      return times.map { ($0, words) }
    }.sorted { $0.0 < $1.0 }
    return lines.enumerated().compactMap { index, line in
      let next = index + 1 < lines.count ? lines[index + 1].0 : line.0 + lastLine
      return line.1.isEmpty ? nil : Cue(start: line.0, end: max(line.0, next), text: line.1)
    }
  }

  static func lrc(_ cues: [Cue]) -> String {
    func stamp(_ seconds: TimeInterval) -> String {
      let hundredths = Int((max(0, seconds) * 100).rounded())
      return String(format: "[%02d:%02d.%02d]", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }
    return cues.enumerated().map { index, cue in
      let words = stamp(cue.start) + plain(cue.text).replacingOccurrences(of: "\n", with: " ") + "\n"
      // Where nothing is sung for a while, the line goes.
      let isGap = index + 1 == cues.count || cues[index + 1].start - cue.end > 1
      return words + (isGap ? stamp(cue.end) + "\n" : "")
    }.joined()
  }

  // MARK: - Timed Text

  static func parseTTML(_ text: String) -> [Cue] {
    guard let root = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]).rootElement() else { return [] }
    func value(_ name: String) -> Double? { root.attributes?.first { $0.localName == name }?.stringValue.flatMap(Double.init) }
    let frames = value("frameRate") ?? 30, ticks = value("tickRate") ?? 10_000_000
    func time(_ text: String?) -> TimeInterval? {
      guard let text = text?.trimmingCharacters(in: .whitespaces) else { return nil }
      if let match = text.wholeMatch(of: #/([\d.]+)(h|ms|m|s|f|t)/#), let number = Double(match.1) {
        return number * (["h": 3600, "m": 60, "s": 1, "ms": 0.001, "f": 1 / frames, "t": 1 / ticks][String(match.2)] ?? 1)
      }
      let fields = text.split(separator: ":")
      // The fourth is a frame.
      if fields.count == 4, let frame = Double(fields[3]) { return seconds(from: fields.prefix(3).joined(separator: ":")).map { $0 + frame / frames } }
      return seconds(from: text)
    }
    func words(_ node: XMLNode) -> String {
      if node.kind == .text { return (node.stringValue ?? "").replacing(#/\s+/#, with: " ") }
      if node.localName == "br" { return "\n" }
      return (node.children ?? []).map(words).joined()
    }
    var cues: [Cue] = []
    func walk(_ element: XMLElement) {
      if element.localName == "p", let start = time(element.attribute(forName: "begin")?.stringValue) {
        let end = time(element.attribute(forName: "end")?.stringValue) ?? time(element.attribute(forName: "dur")?.stringValue).map { start + $0 }
        let said = words(element).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        if let end, !said.isEmpty { cues.append(Cue(start: start, end: end, text: said)) }
      } else {
        for child in element.children ?? [] { if let child = child as? XMLElement { walk(child) } }
      }
    }
    walk(root)
    return cues
  }

  static func ttml(_ cues: [Cue]) -> String {
    let lines = cues.map { cue in
      "<p begin=\"\(stamp(cue.start, separator: "."))\" end=\"\(stamp(cue.end, separator: "."))\">"
        + DataFormats.escaped(plain(cue.text)).replacingOccurrences(of: "\n", with: "<br/>") + "</p>"
    }
    return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + #"<tt xmlns="http://www.w3.org/ns/ttml" xml:lang=""><body><div>"# + "\n" + lines.joined(separator: "\n") + "\n</div></body></tt>\n"
  }
}
