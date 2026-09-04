import Foundation
import UniformTypeIdentifiers

/// A named chain of actions, applied in order.
///
/// A preset used to be a fixed set of fields - one format, one resize, one
/// quality - which meant the order was decided for you and there was no room
/// for a second filter or an action that had not been thought of. It is now a
/// list, the way Shortcuts is a list, and the editor builds it by stacking
/// actions rather than filling a form.
struct RulePreset: Identifiable, Codable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var description: String
  var category: PresetCategory

  /// Off presets stay where they are but are not offered anywhere. Turning one
  /// off is the answer to "I do not need this right now", which used to mean
  /// deleting it and making it again later.
  var isEnabled: Bool = true

  /// Where this sits in the list. Presets used to be sorted by name, which is
  /// tidy and not the order anyone works in.
  var position: Int = 0

  /// The actions, in the order they run.
  var actions: [Operation] = []

  /// What this preset asks for before it runs.
  ///
  /// A preset with no parameters is fixed: it does the same thing every time.
  /// One with parameters is a shape rather than a setting — "make it fit under
  /// a size you choose" — and the answer is asked for at conversion time and
  /// can be spent in the file's name.
  var parameters: [PresetParameter] = []

  /// Overrides the general name template for the files this preset writes.
  var nameTemplate: String? = nil

  /// What the parameters were answered with, for this run only.
  ///
  /// Deliberately outside `CodingKeys`: an answer belongs to one conversion,
  /// not to the preset, and saving it would turn a question into a setting.
  var parameterValues: [String: Double] = [:]

  init(
    id: UUID = UUID(),
    name: String,
    description: String,
    category: PresetCategory,
    position: Int = 0,
    isEnabled: Bool = true,
    actions: [Operation] = []
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.category = category
    self.position = position
    self.isEnabled = isEnabled
    self.actions = actions
  }

  /// Build a chain from the pieces a form would ask for. The order is the one
  /// that makes sense: change the format, then the size, then the quality,
  /// then anything applied on top.
  init(
    id: UUID = UUID(),
    name: String,
    description: String,
    targetFormat: UTType? = nil,
    resize: ResizeSpec? = nil,
    quality: Int? = nil,
    filters: [FilterType] = [],
    category: PresetCategory,
    ocrLanguages: [String] = []
  ) {
    self.init(
      id: id,
      name: name,
      description: description,
      category: category,
      actions: Self.chain(
        targetFormat: targetFormat,
        resize: resize,
        quality: quality,
        filters: filters,
        ocrLanguages: ocrLanguages
      )
    )
  }

  static func chain(
    targetFormat: UTType?,
    resize: ResizeSpec?,
    quality: Int?,
    filters: [FilterType],
    ocrLanguages: [String]
  ) -> [Operation] {
    var actions: [Operation] = []
    if let targetFormat { actions.append(.convertFormat(to: targetFormat)) }
    if let resize {
      actions.append(.resize(width: resize.width, height: resize.height, fitMode: resize.fitMode))
    }
    if let quality { actions.append(.quality(level: quality)) }
    actions.append(contentsOf: filters.map { .filter(type: $0) })
    if targetFormat?.conforms(to: .plainText) == true {
      actions.append(.recognizeText(languages: ocrLanguages))
    }
    return actions
  }

  /// The actions, ready to run.
  func toOperations() -> [Operation] { actions }

  /// A copy with `action` put in place of the one of its kind already there,
  /// or added if there is none.
  ///
  /// This is how the convert screen adjusts a preset for one batch without
  /// editing the preset itself.
  func replacing(_ action: Operation) -> RulePreset {
    var copy = self
    if let index = copy.actions.firstIndex(where: { $0.id == action.id }) {
      copy.actions[index] = action
    } else {
      copy.actions.append(action)
    }
    return copy
  }

  /// A copy without any action of that kind.
  func removing(_ kind: String) -> RulePreset {
    var copy = self
    copy.actions.removeAll { $0.id == kind }
    return copy
  }

  // MARK: - Reading the chain

  /// What the chain converts to, if it says.
  var targetFormat: UTType? {
    actions.compactMap { if case .convertFormat(let to) = $0 { return to } else { return nil } }.first
  }

  var resize: ResizeSpec? {
    actions.compactMap { action -> ResizeSpec? in
      guard case .resize(let width, let height, let fitMode) = action else { return nil }
      return ResizeSpec(width: width, height: height, fitMode: fitMode)
    }.first
  }

  var quality: Int? {
    actions.compactMap { if case .quality(let level) = $0 { return level } else { return nil } }.first
  }

  var filters: [FilterType] {
    actions.compactMap { if case .filter(let type) = $0 { return type } else { return nil } }
  }

  var ocrLanguages: [String] {
    actions.compactMap { if case .recognizeText(let languages) = $0 { return languages } else { return nil } }
      .first ?? []
  }
}

extension RulePreset {
  private enum CodingKeys: String, CodingKey {
    case id, name, description, category, position, isEnabled, actions
    case parameters, nameTemplate
    // The shape presets were saved in before they became a chain.
    case targetFormat, resize, quality, filters, ocrLanguages
  }

  /// Decode tolerantly, and migrate.
  ///
  /// A preset saved before this change has separate fields and no `actions`,
  /// so the chain is rebuilt from them. Absence is handled for every field:
  /// the synthesized decoder does not fall back to a property's default, it
  /// fails, which would strand everything already in Application Support.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    category = try container.decodeIfPresent(PresetCategory.self, forKey: .category) ?? .custom
    position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

    // Both are newer than the presets already on disk, so absence is normal
    // and means "asks for nothing" and "use the general name template".
    parameters = try container.decodeIfPresent([PresetParameter].self, forKey: .parameters) ?? []
    nameTemplate = try container.decodeIfPresent(String.self, forKey: .nameTemplate)

    if let actions = try container.decodeIfPresent([Operation].self, forKey: .actions) {
      self.actions = actions
      return
    }

    self.actions = Self.chain(
      targetFormat: try container.decodeIfPresent(UTType.self, forKey: .targetFormat),
      resize: try container.decodeIfPresent(ResizeSpec.self, forKey: .resize),
      quality: try container.decodeIfPresent(Int.self, forKey: .quality),
      filters: try container.decodeIfPresent([FilterType].self, forKey: .filters) ?? [],
      ocrLanguages: try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? []
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(description, forKey: .description)
    try container.encode(category, forKey: .category)
    try container.encode(position, forKey: .position)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(actions, forKey: .actions)
    if !parameters.isEmpty { try container.encode(parameters, forKey: .parameters) }
    try container.encodeIfPresent(nameTemplate, forKey: .nameTemplate)
  }
}

struct ResizeSpec: Codable, Hashable, Sendable {
  var width: Int?
  var height: Int?
  var fitMode: ResizeFitMode = .proportional
}

enum PresetCategory: String, Codable, CaseIterable, Sendable {
  case image
  case video
  case audio
  case document
  case custom

  var icon: String {
    switch self {
    case .image: return "photo"
    case .video: return "film"
    case .audio: return "waveform"
    case .document: return "doc"
    case .custom: return "star"
    }
  }

  /// Which kind of work a file of this type is in for.
  ///
  /// Asked once a file is actually in hand, so that what is offered for it
  /// suits what it is: a photograph has no business being offered Audio → MP3.
  /// `nil` for a type none of these describes, which is the signal to offer
  /// everything rather than nothing.
  init?(fileType: UTType) {
    if fileType.conforms(to: .image) {
      self = .image
    } else if fileType.conforms(to: .movie) {
      self = .video
    } else if fileType.conforms(to: .audio) {
      self = .audio
    } else if fileType.conforms(to: .pdf) || fileType.conforms(to: .text) {
      self = .document
    } else {
      return nil
    }
  }
}
