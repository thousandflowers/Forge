import Foundation

/// The editor's Preview: a sample file taken through the chain one step at a
/// time, each stage written to scratch and measured, never beside the
/// original and never into history.
enum PreviewRunner {

  /// What the sample is at one point of the chain.
  struct Step: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let url: URL
    let bytes: Int64
    let width: Int?
    let height: Int?
  }

  /// One preset per step: the formats the chain writes, plus every step up to
  /// and including that one. Writing the format at every stage keeps the
  /// weights comparable - "after Resize" is already a JPEG. A chain with forks
  /// is shown whole, since a prefix of a fork is not something that runs.
  static func stages(of preset: RulePreset) -> [(title: String, preset: RulePreset)] {
    let formats = preset.actions.filter(isFormat)
    let steps = preset.actions.filter { !isFormat($0) }
    guard !steps.isEmpty, !steps.contains(where: isFork) else { return [("Result", preset)] }
    return steps.indices.map { index in
      var stage = preset
      stage.actions = formats + steps[...index]
      return (steps[index].title, stage)
    }
  }

  /// The original, then the sample after each stage.
  static func run(
    sample: ProcessableFile,
    preset: RulePreset,
    coordinator: ProcessingCoordinator,
    scratch: URL
  ) async throws -> [Step] {
    var steps = [
      Step(
        id: 0, title: "Original", url: sample.url, bytes: sample.fileSize,
        width: sample.dimensions?.width, height: sample.dimensions?.height
      ),
    ]
    for (index, stage) in stages(of: preset).enumerated() {
      try Task.checkCancellation()
      let folder = scratch.appendingPathComponent("stage-\(index + 1)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let result = try await coordinator.preview(sample, with: stage.preset, into: folder)
      steps.append(Step(
        id: index + 1, title: stage.title, url: result.outputURL, bytes: result.outputSize,
        width: result.outputDimensions?.width, height: result.outputDimensions?.height
      ))
    }
    return steps
  }

  private static func isFormat(_ operation: Operation) -> Bool {
    if case .convertFormat = operation { return true }
    return false
  }

  private static func isFork(_ operation: Operation) -> Bool {
    switch operation {
    case .when, .split, .join, .merge: return true
    default: return false
    }
  }
}
