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

  /// The actions, in the order they run.
  var actions: [Operation] = []

  init(
    id: UUID = UUID(),
    name: String,
    description: String,
    category: PresetCategory,
    actions: [Operation] = []
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.category = category
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
    case id, name, description, category, actions
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
    try container.encode(actions, forKey: .actions)
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
    case .video: return "filmstrip"
    case .audio: return "waveform"
    case .document: return "doc"
    case .custom: return "star"
    }
  }
}
