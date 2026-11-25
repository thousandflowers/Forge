import Foundation
import UniformTypeIdentifiers

/// The instructions somebody wrote into a file's own name.
///
/// `holiday_10MB.jpg` says come out under ten megabytes. `contract_privacy.pdf`
/// says take the author details out. `holiday_10MB_privacy.jpg` says both, and
/// that is the reason this exists: reading only the last piece of the name
/// meant the second instruction hid the first.
///
/// Tokens are read from the end and stop at the first piece that is not one.
/// `10MB_notes.jpg` is a file about ten megabytes, not a file to be squeezed
/// into ten - the size has to be the instruction, and an instruction comes at
/// the end.
enum NameTokens {

  /// The words that open a menu instead of deciding: `goose_asksize.jpg`.
  enum Ask: String, CaseIterable, Sendable {
    case everything = "ask"
    case size = "asksize"
    case width = "askwidth"
    case quality = "askquality"
    case format = "askformat"
  }

  struct Read: Equatable {
    /// A ceiling on the finished file, in bytes.
    var ceiling: Int?
    /// How much metadata to leave behind.
    var privacy: PrivacyPolicy?
    /// `_1920px` — how wide it should come out.
    var width: Int?
    /// `_q80` — the quality to write at.
    var quality: Int?
    /// `_asksize` — put the question to whoever renamed it.
    var ask: Ask?
    /// `_mute`, `_speed2x` — in the order they are written.
    var tools: [Tool] = []

    var isEmpty: Bool { ceiling == nil && privacy == nil && width == nil && quality == nil && ask == nil && tools.isEmpty }
  }

  /// The name once its tools have been used. Run a second time a size is the
  /// same size, but a rotation is another rotation.
  static func spent(_ fileName: String) -> String {
    let stem = (fileName as NSString).deletingPathExtension
    let (said, instructions) = parse(fileName)
    guard !said.tools.isEmpty else { return stem }
    let type = UTType(filenameExtension: (fileName as NSString).pathExtension)
    var pieces = stem.split(separator: "_").map(String.init)
    let last = pieces.count - instructions
    pieces = Array(pieces[..<last]) + pieces[last...].filter { tool($0, for: type) == nil }
    return pieces.joined(separator: "_")
  }

  /// The name once it has asked, and been answered.
  static func answered(_ stem: String, ext: String) -> String {
    let (said, instructions) = parse("\(stem).\(ext)")
    guard said.ask != nil else { return stem }
    let pieces = stem.split(separator: "_").map(String.init), last = pieces.count - instructions
    return (Array(pieces[..<last]) + pieces[last...].filter { Ask(rawValue: $0.lowercased()) == nil }).joined(separator: "_")
  }

  /// Every width asked for, in the order it is written. Only those at the end:
  /// anywhere else a number of pixels is part of the name.
  static func widths(_ fileName: String) -> [Int] {
    let pieces = (fileName as NSString).deletingPathExtension.split(separator: "_").map(String.init)
    let instructions = parse(fileName).pieces
    guard instructions > 0 else { return [] }
    var seen: [Int] = []
    for width in pieces.suffix(instructions).compactMap(width) where !seen.contains(width) { seen.append(width) }
    return seen
  }

  /// Where one name asks for several, each is called by its own.
  static func withoutWidths(_ stem: String) -> String {
    guard widths(stem + ".x").count > 1 else { return stem }
    let pieces = stem.split(separator: "_").map(String.init)
    return pieces.enumerated().filter { $0.offset == 0 || width(of: $0.element) == nil }.map(\.element).joined(separator: "_")
  }

  private static func width(of piece: String) -> Int? {
    let token = piece.lowercased()
    guard token.hasSuffix("px"), let width = Int(token.dropLast(2)), width > 0 else { return nil }
    return width
  }

  /// A word that means nothing for that kind of file is part of its name.
  private static func tool(_ piece: String, for type: UTType?) -> Tool? {
    guard let tool = Tool(word: piece), let type, tool.suits(type) else { return nil }
    return tool
  }

  /// What the name asks for.
  static func read(_ fileName: String) -> Read { parse(fileName).read }

  /// - Returns: and how many pieces, from the end, are instructions.
  private static func parse(_ fileName: String) -> (read: Read, pieces: Int) {
    let stem = (fileName as NSString).deletingPathExtension
    let type = UTType(filenameExtension: (fileName as NSString).pathExtension)
    let pieces = stem.split(separator: "_").map(String.init)
    // No underscore means no instruction: the whole name is the name.
    guard pieces.count > 1 else { return (Read(), 0) }

    var read = Read()
    var instructions = 0
    // Never the first piece: a name made only of instructions is a name, and
    // `10MB.jpg` is a file about ten megabytes.
    for piece in pieces.reversed().dropLast() {
      let token = piece.lowercased()
      if token == "privacy" || token == "nometa" {
        // Typed by hand, about this one file: the most thorough level, since
        // "privacy" is not a request for half of it.
        read.privacy = .stripAll
      } else if let ask = Ask(rawValue: token) {
        read.ask = ask
      } else if let bytes = SizeInName.bytes(in: token) {
        read.ceiling = bytes
      } else if token.hasSuffix("px"), let width = Int(token.dropLast(2)), width > 0 {
        read.width = width
      } else if token.hasPrefix("q"), token.count >= 3, let quality = Int(token.dropFirst()), (10...100).contains(quality) {
        // Two digits at least: `report_q3.pdf` is a quarter, not a request
        // to write it at quality three.
        read.quality = quality
      } else if let tool = tool(piece, for: type) {
        read.tools.insert(tool, at: 0)
      } else {
        // Anything else ends the run. Without this, a date or a word in the
        // middle of a name would be stepped over and whatever came before it
        // read as an instruction.
        break
      }
      instructions += 1
    }
    return (read, instructions)
  }

  /// The chain with the name's instructions in it.
  ///
  /// They beat what the preset says, because they were typed onto that one file
  /// for this one conversion.
  /// - Parameter tools: whether the tools in it are orders too.
  static func applying(to operations: [Operation], from fileName: String, tools: Bool = true, width takesWidth: Bool = true) -> [Operation] {
    var read = read(fileName)
    if !tools { read.tools = [] }
    if !takesWidth { read.width = nil }
    guard !read.isEmpty else { return operations }

    var result = operations
    if let ceiling = read.ceiling {
      result.removeAll { if case .limitSize = $0 { return true } else { return false } }
      result.append(.limitSize(bytes: ceiling))
    }
    if let privacy = read.privacy {
      result.removeAll { if case .stripMetadata = $0 { return true } else { return false } }
      result.append(.stripMetadata(policy: privacy))
    }
    if let width = read.width {
      result.removeAll { if case .resize = $0 { return true } else { return false } }
      result.append(.resize(width: width, height: nil, fitMode: .proportional))
    }
    if let quality = read.quality {
      result.removeAll { if case .quality = $0 { return true } else { return false } }
      result.append(.quality(level: quality))
    }
    for tool in read.tools { result = result.adding(tool) }
    return read.tools.isEmpty ? result : result.settlingFormat(overriding: true, of: UTType(filenameExtension: (fileName as NSString).pathExtension))
  }
}

extension RulePreset {
  /// Everything it would do to that file, with what the file's name says where
  /// the name is listened to.
  func tools(for file: ProcessableFile) -> [Tool] {
    (actions + NameTokens.applying(to: [], from: file.fileName, tools: readsTools)).everyTool
  }

  /// What it does to that file, in a few words: what its name says, or else what
  /// the preset does, or else what it becomes.
  func words(for file: ProcessableFile) -> String {
    func steps(_ chain: [Operation]) -> [String] { chain.flatMap(\.leaves).filter { !$0.isFormat }.map(PresetChip.text) }
    let named = steps(NameTokens.applying(to: [], from: file.fileName, tools: readsTools))
    let all = named.isEmpty ? steps(actions) : named
    guard all.isEmpty else {
      return all.prefix(Self.mostWords).joined(separator: ", ") + (all.count > Self.mostWords ? "…" : "")
    }
    let formats = actions.flatMap(\.leaves).compactMap { if case .convertFormat(let to) = $0 { return OutputFormat(type: to).label } else { return nil } }
    return formats.isEmpty ? name : formats.joined(separator: ", ")
  }

  private static let mostWords = 2
}
