import AVFoundation
import Foundation
import PDFKit

/// One file taken apart: the chain it was given, once for every part of it.
///
/// Dividing is not something any processor does. A part is a film trimmed, or
/// a document with some of its pages, and those they do already.
enum Division {
  private static let most = 2000
  /// Less than this at the end is a rounding and not a part.
  private static let shortest = 0.05

  static func chains(for actions: [Operation], of file: ProcessableFile) async throws -> [(label: String, actions: [Operation])]? {
    if let tiles = tiles(for: actions) { return tiles }
    guard let division = actions.tools.compactMap({ tool -> Tool.Division? in
      if case .divide(let division) = tool { return division } else { return nil }
    }).first else { return nil }
    let rest = actions.filter { if case .tool(.divide) = $0 { return false } else { return true } }

    let parts: [[Operation]]
    if case .pages(let size) = division {
      parts = try pages(by: size, of: file, in: rest)
    } else {
      parts = try await spans(division, of: file, in: rest)
    }
    guard parts.count > 1 else {
      throw ProcessingError.conversionFailed(reason: "\(file.fileName) is all in one part already.")
    }
    guard parts.count <= most else {
      throw ProcessingError.conversionFailed(reason: "That would make \(parts.count) files of \(file.fileName).")
    }
    let digits = max(2, String(parts.count).count)
    return parts.enumerated().map { index, actions in
      let number = String(index + 1)
      return (String(repeating: "0", count: digits - number.count) + number, actions)
    }
  }

  /// Each is a crop, where the cutting up was.
  private static func tiles(for actions: [Operation]) -> [(label: String, actions: [Operation])]? {
    guard let place = actions.firstIndex(where: { if case .tool(.tile) = $0 { return true } else { return false } }),
          case .tool(.tile(let across, let down)) = actions[place] else { return nil }
    let digits = max(2, String(across * down).count)
    return (0..<(across * down)).map { index in
      var copy = actions
      copy[place] = .tool(.crop(.cell(column: index % across + 1, row: index / across + 1, across: across, down: down)))
      let number = String(index + 1)
      return (String(repeating: "0", count: digits - number.count) + number, copy)
    }
  }

  private static func pages(by size: Int, of file: ProcessableFile, in rest: [Operation]) throws -> [[Operation]] {
    guard let pdf = PDFDocument(url: file.url) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(file.fileName)")
    }
    try SimpleDocProcessor.refuseIfLocked(pdf, named: file.fileName)
    var kept = Array(0..<pdf.pageCount)
    for tool in rest.tools {
      if case .pages(let list) = tool { kept = list.indices(of: kept.count).map { kept[$0] } }
      if case .dropPages(let list) = tool {
        let dropped = Set(list.indices(of: kept.count))
        kept = kept.indices.filter { !dropped.contains($0) }.map { kept[$0] }
      }
    }
    let others = rest.filter { operation in
      guard case .tool(let tool) = operation else { return true }
      return tool.kind != .pages && tool.kind != .dropPages
    }
    return stride(from: 0, to: kept.count, by: size).compactMap { start in
      let pages = kept[start..<min(start + size, kept.count)].map { String($0 + 1) }.joined(separator: ",")
      return PageList(pages).map { [.tool(.pages($0))] + others }
    }
  }

  private static func spans(_ division: Tool.Division, of file: ProcessableFile, in rest: [Operation]) async throws -> [[Operation]] {
    let edit = MediaEdit(rest)
    guard let kept = (edit.part ?? Span()).clamped(to: try await length(of: file.url)) else {
      throw ProcessingError.conversionFailed(reason: "There is nothing in the part of \(file.fileName) asked for.")
    }
    if case .every(let seconds) = division, (kept.upperBound - kept.lowerBound) / seconds > Double(most) {
      throw ProcessingError.conversionFailed(reason: "That would make more than \(most) files of \(file.fileName).")
    }
    var cuts: [Double]
    switch division {
    case .every(let seconds): cuts = Array(stride(from: kept.lowerBound + seconds, to: kept.upperBound - shortest, by: seconds))
    case .parts(let count):
      let each = (kept.upperBound - kept.lowerBound) / Double(count)
      cuts = (1..<count).map { kept.lowerBound + each * Double($0) }
    case .chapters:
      cuts = await chapters(of: file.url).filter { $0 > kept.lowerBound + shortest && $0 < kept.upperBound - shortest }
      guard !cuts.isEmpty else { throw ProcessingError.conversionFailed(reason: "There are no chapters in \(file.fileName).") }
    case .pages: cuts = []
    }
    cuts = [kept.lowerBound] + cuts
    return cuts.indices.map { index in
      let next = index + 1 < cuts.count ? cuts[index + 1] : edit.part?.to
      return rest.adding(.trim(Span(from: cuts[index], to: next), fast: edit.isFast))
    }
  }

  /// How long it plays, as the system says or as ffprobe does.
  static func length(of url: URL) async throws -> Double {
    if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0 { return seconds }
    if let said = probe(url, ["-show_entries", "format=duration", "-of", "csv=p=0"]), let seconds = Double(said) { return seconds }
    throw ProcessingError.conversionFailed(reason: "How long \(url.lastPathComponent) is cannot be read.")
  }

  private static func chapters(of url: URL) async -> [Double] {
    let groups = (try? await AVURLAsset(url: url).loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
    let found = groups.map(\.timeRange.start.seconds)
    if !found.isEmpty { return found.sorted() }
    let said = probe(url, ["-show_entries", "chapter=start_time", "-of", "csv=p=0"]) ?? ""
    return said.split(whereSeparator: \.isNewline).compactMap { Double($0) }.sorted()
  }

  private static func probe(_ url: URL, _ arguments: [String]) -> String? {
    guard let ffprobe = ExternalTools.locate("ffprobe") else { return nil }
    return ExternalTools.answer(of: ffprobe, ["-v", "error"] + arguments + [url.path]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
