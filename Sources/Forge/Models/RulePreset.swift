import Foundation
import UniformTypeIdentifiers

/// A named preset containing a set of operations to apply
struct RulePreset: Identifiable, Codable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var description: String

  var targetFormat: UTType?
  var resize: ResizeSpec?
  var quality: Int?        // 1-100
  var filters: [FilterType] = []

  var category: PresetCategory

  /// Languages to look for when reading text out of images, as BCP-47 tags.
  /// Empty lets Vision work it out, which is right for most documents.
  var ocrLanguages: [String] = []

  /// Convert preset to an ordered list of operations
  func toOperations() -> [Operation] {
    var ops: [Operation] = []

    if let format = targetFormat {
      ops.append(.convertFormat(to: format))
    }
    if let resize = resize {
      ops.append(.resize(
        width: resize.width,
        height: resize.height,
        fitMode: resize.fitMode
      ))
    }
    if let quality = quality {
      ops.append(.quality(level: quality))
    }
    ops.append(contentsOf: filters.map { .filter(type: $0) })
    if targetFormat?.conforms(to: .plainText) == true {
      ops.append(.recognizeText(languages: ocrLanguages))
    }

    return ops
  }
}

extension RulePreset {
  /// Decode tolerantly: a preset saved by an older version has none of the
  /// fields added since, and the synthesized decoder does not fall back to a
  /// property's default - it fails. That would strand every preset already in
  /// Application Support each time a field is added, so absence is handled
  /// here once instead of being rediscovered later.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    targetFormat = try container.decodeIfPresent(UTType.self, forKey: .targetFormat)
    resize = try container.decodeIfPresent(ResizeSpec.self, forKey: .resize)
    quality = try container.decodeIfPresent(Int.self, forKey: .quality)
    filters = try container.decodeIfPresent([FilterType].self, forKey: .filters) ?? []
    category = try container.decodeIfPresent(PresetCategory.self, forKey: .category) ?? .custom
    ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? []
  }
}

struct ResizeSpec: Codable, Hashable, Sendable {
  var width: Int?
  var height: Int?
  var fitMode: ResizeFitMode = .proportional
}

enum PresetCategory: String, Codable, CaseIterable, Sendable {
  case image = "image"
  case video = "video"
  case audio = "audio"
  case document = "document"
  case custom = "custom"

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
