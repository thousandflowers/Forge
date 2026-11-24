import Foundation

/// Whether a file is all there.
///
/// A download that stopped, a copy that was interrupted: the start of the file
/// is fine and the rest is missing. The readers take what is there and say
/// nothing, so half a photograph came out with its lower half grey and a third
/// of a recording came out a third as long, both reported as converted. Each
/// format says where it ends, and that is what is checked.
enum Completeness {

  static func refuseIfIncomplete(_ url: URL) throws {
    guard let missing = whatIsMissing(url) else { return }
    throw ProcessingError.conversionFailed(
      reason: "\(url.lastPathComponent) is incomplete: \(missing). "
        + "If it is still being copied or downloaded, try again once it has arrived."
    )
  }

  /// What is missing, in words, or nil for a file that is whole - or of a kind
  /// that cannot be told.
  static func whatIsMissing(_ url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg":
      return jpeg(url)
    case "png":
      return png(url)
    case "wav":
      return riff(url)
    case "mkv", "webm", "mka", "avi", "flv", "wmv", "ogg", "ogv", "mp3", "flac":
      return probed(url)
    default:
      return nil
    }
  }

  // MARK: - Pictures

  /// A JPEG ends with FF D9 after its last scan. Looked for after the last
  /// scan, not anywhere: the small preview inside the file's metadata has an
  /// end of its own.
  private static func jpeg(_ url: URL) -> String? {
    guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe), bytes.count > 4 else { return nil }
    guard let scan = lastMarker(0xDA, in: bytes) else { return nil }
    return lastMarker(0xD9, in: bytes, after: scan) == nil ? "the picture stops before its end" : nil
  }

  private static func lastMarker(_ marker: UInt8, in bytes: Data, after start: Int = 0) -> Int? {
    var index = bytes.endIndex - 2
    while index >= bytes.startIndex + start {
      if bytes[index] == 0xFF, bytes[index + 1] == marker { return index }
      index -= 1
    }
    return nil
  }

  /// A PNG ends with an IEND chunk.
  private static func png(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), size > 12 else { return nil }
    try? handle.seek(toOffset: size - min(size, 64))
    let tail = handle.readDataToEndOfFile()
    return tail.range(of: Data("IEND".utf8)) == nil ? "the picture stops before its end" : nil
  }

  // MARK: - Recordings and films

  /// A WAV says how much sound it holds before the sound starts. A file
  /// shorter than that was cut off.
  private static func riff(_ url: URL) -> String? {
    guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe), bytes.count > 12,
          bytes.prefix(4) == Data("RIFF".utf8), bytes[8..<12] == Data("WAVE".utf8) else { return nil }
    var offset = 12
    while offset + 8 <= bytes.count {
      let id = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
      let size = bytes[(offset + 4)..<(offset + 8)].enumerated()
        .reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
      // A size of all ones is what a recorder writes while it is still
      // recording, and some leave it; that is not a cut-off file.
      if id == "data" {
        return size != 0xFFFF_FFFF && offset + 8 + size > bytes.count ? "the recording stops before its end" : nil
      }
      offset += 8 + size + (size & 1)
    }
    return nil
  }

  /// Where ffprobe is installed: the length the file declares, and the time of
  /// the last thing actually in it. Read near the end only, so a long film is
  /// not read through. A file cut off declares more than it holds - a third of
  /// a song still says it lasts four minutes.
  private static func probed(_ url: URL) -> String? {
    guard let ffprobe = ExternalTools.locate("ffprobe") else { return nil }
    func ask(_ arguments: [String]) -> String {
      let process = Process()
      process.executableURL = ffprobe
      process.arguments = ["-v", "error"] + arguments + ["-of", "csv=p=0", url.path]
      let said = Pipe()
      process.standardOutput = said
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return "" }
      let text = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit()
      return text
    }
    guard let declared = Double(ask(["-show_entries", "format=duration"]).trimmingCharacters(in: .whitespacesAndNewlines)),
          declared > 2 else { return nil }
    // Where each packet ends, not where it starts: a subtitle can begin at five
    // seconds and run to the end of an eight-second film.
    let near = ask(["-read_intervals", "\(declared - 1)%", "-show_entries", "packet=pts_time,duration_time"])
    let times = near.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
      let fields = line.split(separator: ",").map(String.init)
      guard let start = fields.first.flatMap(Double.init) else { return nil }
      return start + (fields.dropFirst().first.flatMap(Double.init) ?? 0)
    }
    guard let last = times.max() else { return nil }
    // A second and a half of slack for containers that round their length.
    return last < declared - 1.5 ? "it stops at \(Int(last)) seconds of \(Int(declared.rounded()))" : nil
  }
}
