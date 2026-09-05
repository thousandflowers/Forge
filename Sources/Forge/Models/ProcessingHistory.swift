import Foundation
import UniformTypeIdentifiers

struct ProcessingHistory: Identifiable, Codable, Sendable {
  var id = UUID()
  var fileURL: URL
  var ruleId: UUID?
  var timestamp = Date()
  var status: ProcessingStatus
  var errorMessage: String?
  var duration: TimeInterval
  var outputURL: URL?
  /// The rest of what this conversion wrote. A preset asking for two formats
  /// writes two files, and history used to keep the first and forget the
  /// other - both were on disk and only one was accounted for.
  ///
  /// Optional so that a history written before this existed still decodes.
  var additionalOutputs: [URL]?
  /// Where the output was asked to go, so a row can be run again. Nil for a
  /// conversion in place, which has no folder to send anything to.
  var destinationFolder: URL?
  /// What was actually run, in order.
  ///
  /// The preset's id alone was not enough to run anything again: a preset can
  /// be edited or deleted, and then the row in history describes a conversion
  /// nothing can reproduce. The chain is what happened, so the chain is what is
  /// kept. Optional, so history written before this still decodes.
  var actions: [Operation]?
  /// What the preset was called at the time, for naming a preset made from it.
  var presetName: String?

  /// Every file this conversion produced.
  var outputs: [URL] { [outputURL].compactMap { $0 } + (additionalOutputs ?? []) }

  /// How long it took, in words. A conversion that takes 40 milliseconds is
  /// not "0.0s" - that reads like nothing happened.
  var durationText: String? {
    guard duration > 0 else { return nil }
    if duration < 1 { return "\(Int((duration * 1000).rounded())) ms" }
    return String(format: "%.1f s", duration)
  }
}

extension ProcessingHistory {
  /// Whether there is enough here to run it again.
  ///
  /// History written before the chain was recorded says which preset ran but
  /// not what it did, and a row that offers to repeat a conversion it cannot
  /// describe is worse than a row that offers nothing.
  var isRepeatable: Bool { !(actions ?? []).isEmpty }

  /// The chain as a preset, under a name of the caller's choosing.
  ///
  /// A pure mapping: a history entry and a preset are the same thing said
  /// twice - a name and a list of actions Forge already knows how to run - so
  /// this is a rename, not a translation.
  func preset(named name: String, description: String = "") -> RulePreset? {
    guard let actions, !actions.isEmpty else { return nil }
    return RulePreset(
      name: name,
      description: description,
      // The shelf it lands on comes from what was converted, since that is what
      // the preset will be offered for.
      category: UTType(filenameExtension: fileURL.pathExtension)
        .flatMap(ConvertKind.init(fileType:))?
        .presetCategory ?? .custom,
      actions: actions
    )
  }

  /// The preset to keep: a one-off conversion, graduated.
  var savedPreset: RulePreset? {
    preset(
      named: presetName.map { "\($0) (from history)" } ?? "Run of \(fileURL.lastPathComponent)",
      description: "Saved from a conversion run on "
        + timestamp.formatted(date: .abbreviated, time: .shortened) + "."
    )
  }

  /// The preset for doing exactly this again, which is not saved anywhere.
  var rerunPreset: RulePreset? {
    preset(named: presetName ?? "Again", description: "")
  }
}

/// Where a file has got to. The first two are only ever shown on screen; the
/// rest are what gets written to history.
enum ProcessingStatus: String, Codable, Sendable, CaseIterable {
  case pending
  case processing
  case completed
  case failed
  case cancelled

  var displayName: String { rawValue.capitalized }
}
