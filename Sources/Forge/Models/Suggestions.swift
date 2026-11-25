import Foundation
import UniformTypeIdentifiers

/// The presets worth putting under a file in somebody's hand: the ones they
/// chose, or, where they chose none, the ones they use on files like it.
///
/// Learnt from History and from nothing else, so clearing History is forgetting
/// it. A day's use is one vote: two hundred photographs in an afternoon are not
/// two hundred opinions.
enum Suggestions {
  static let most = 5
  /// A vote is worth half after this long.
  private static let halfLife: TimeInterval = 14 * 86_400
  /// What a vote on another format of the same kind is worth.
  private static let cousin = 0.35

  static func presets(
    for files: [ProcessableFile], from presets: [RulePreset], chosen: [UUID], history: [ProcessingHistory], now: Date = Date()
  ) -> [RulePreset] {
    let kinds = Set(files.compactMap { ConvertKind(fileType: $0.fileType) })
    guard !files.isEmpty, kinds.count == 1, let kind = kinds.first else { return [] }
    let fitting = presets.filter { preset in
      preset.isEnabled && (preset.doesSomething || !preset.parameters.isEmpty) && preset.suits(files) && files.allSatisfy { preset.accepts($0.url) }
    }
    guard chosen.isEmpty else {
      return Array(chosen.compactMap { id in fitting.first { $0.id == id } }.prefix(most))
    }
    let scores = scores(on: Set(files.map { $0.url.pathExtension.lowercased() }), of: kind, history: history, now: now)
    // Used, then made for this kind, then the rest: each in the user's own order.
    func rank(_ preset: RulePreset) -> Double { scores[preset.id] ?? (preset.category == kind.presetCategory ? -1 : -2) }
    return Array(fitting.enumerated().sorted { a, b in
      let left = rank(a.element), right = rank(b.element)
      return left == right ? a.offset < b.offset : left > right
    }.map(\.element).prefix(most))
  }

  private struct Vote: Hashable { let preset: UUID, ext: String, day: Int }

  private static func scores(on extensions: Set<String>, of kind: ConvertKind, history: [ProcessingHistory], now: Date) -> [UUID: Double] {
    var votes: [Vote: Date] = [:]
    for entry in history where entry.status == .completed && !entry.isUndone {
      guard let preset = entry.ruleId else { continue }
      let vote = Vote(preset: preset, ext: entry.fileURL.pathExtension.lowercased(), day: Int(entry.timestamp.timeIntervalSince1970 / 86_400))
      votes[vote] = max(votes[vote] ?? .distantPast, entry.timestamp)
    }
    var kinds: [String: ConvertKind?] = [:]
    var scores: [UUID: Double] = [:]
    for (vote, date) in votes {
      let likeness: Double
      if extensions.contains(vote.ext) {
        likeness = 1
      } else {
        let its = kinds[vote.ext] ?? UTType(filenameExtension: vote.ext).flatMap(ConvertKind.init(fileType:))
        kinds[vote.ext] = its
        guard its == kind else { continue }
        likeness = cousin
      }
      scores[vote.preset, default: 0] += likeness * pow(0.5, max(0, now.timeIntervalSince(date)) / halfLife)
    }
    return scores
  }
}
