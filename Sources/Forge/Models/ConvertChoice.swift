import Foundation
import UniformTypeIdentifiers

/// What a batch should become.
///
/// One chain, however it was arrived at: a format pressed in the Convert
/// sheet, a saved preset, or steps built in the maker. `presetID` means the
/// chain is exactly that preset, run whole and recorded under its name; the
/// first change lets it go.
struct ConvertChoice: Equatable {
  var presetID: UUID?
  var draft = RulePreset(name: "This batch", description: "", category: .custom)
  /// Answers to the chain's questions, by the parameter's key.
  var answers: [String: Double] = [:]
  var destinationMode: DestinationMode = .copyTo
  var destinationURL: URL?

  var needsDestination: Bool { destinationMode != .overwrite }
  var hasDestination: Bool { !needsDestination || destinationURL != nil }

  /// The formats the whole batch comes out as.
  var formats: [UTType] {
    draft.actions.compactMap { if case .convertFormat(let to) = $0 { return to } else { return nil } }
  }

  /// Everything the chain does besides the format.
  var steps: [Operation] { draft.actions.filter { !$0.isFormat } }

  /// Nothing chosen but where the files go.
  func cleared() -> ConvertChoice {
    var updated = ConvertChoice()
    updated.destinationMode = destinationMode
    updated.destinationURL = destinationURL
    return updated
  }

  func adopting(_ preset: RulePreset) -> ConvertChoice {
    var updated = cleared()
    updated.presetID = preset.id
    updated.draft = preset
    return updated
  }

  /// One format for the batch. The steps stay, because the sheet lists them;
  /// what it has no room for - a test, a name template, questions - goes with
  /// the preset it belonged to.
  func choosing(_ format: UTType) -> ConvertChoice {
    // Reading the words is what becoming text means; it is not left behind
    // when text is no longer the answer.
    var kept = steps.filter { $0 != .recognizeText(languages: []) }
    let reads = kept.contains { if case .recognizeText = $0 { return true } else { return false } }
    if format.conforms(to: .plainText), !reads { kept.append(.recognizeText(languages: [])) }

    var updated = cleared()
    updated.draft.actions = [.convertFormat(to: format)] + kept
    return updated
  }

  /// The chain as the maker left it. Looking without touching keeps the preset.
  func edited(_ chain: RulePreset) -> ConvertChoice {
    var updated = self
    updated.answers = [:]
    if presetID != nil, chain.runs(like: draftForMaker) { return self }
    updated.presetID = nil
    updated.draft = chain
    updated.draft.name = ConvertChoice().draft.name
    if chain.id == draft.id { updated.draft.id = UUID() }
    return updated
  }

  /// The chain with the answers already given as its defaults, which is what
  /// the maker shows for a question.
  var draftForMaker: RulePreset {
    var chain = draft
    chain.parameters = chain.parameters.map { parameter in
      var answered = parameter
      answered.defaultValue = answers[parameter.key] ?? parameter.defaultValue
      return answered
    }
    return chain
  }

  /// The preset to hand the coordinator.
  func resolved(against presets: [RulePreset]) -> RulePreset? {
    let chain = presetID.flatMap { id in presets.first { $0.id == id } } ?? draft
    guard chain.doesSomething || !chain.parameters.isEmpty || chain.nameTemplate != nil else { return nil }
    return chain.parameters.isEmpty ? chain : chain.answered(with: answers)
  }
}

extension Operation {
  var isFormat: Bool { if case .convertFormat = self { return true } else { return false } }
}

extension RulePreset {
  /// Whether a file would go through the same thing, whatever the two are called.
  func runs(like other: RulePreset) -> Bool {
    actions == other.actions && parameters == other.parameters && nameTemplate == other.nameTemplate
      && nameTrigger == other.nameTrigger && gate == other.gate
  }
}
