import Foundation
import UniformTypeIdentifiers

/// A named preset containing a set of operations to apply
struct RulePreset: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  var name: String
  var description: String

  var targetFormat: UTType?
  var resize: ResizeSpec?
  var quality: Int?        // 1-100
  var targetSize: Int64?   // bytes (max size)
  var filters: [FilterType]

  var icon: String?
  var category: PresetCategory
  var applicableFileTypes: [UTType]?  // nil = all types

  init(
    id: UUID = UUID(),
    name: String,
    description: String,
    targetFormat: UTType? = nil,
    resize: ResizeSpec? = nil,
    quality: Int? = nil,
    targetSize: Int64? = nil,
    filters: [FilterType] = [],
    icon: String? = nil,
    category: PresetCategory,
    applicableFileTypes: [UTType]? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.targetFormat = targetFormat
    self.resize = resize
    self.quality = quality
    self.targetSize = targetSize
    self.filters = filters
    self.icon = icon
    self.category = category
    self.applicableFileTypes = applicableFileTypes
  }

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
    if let size = targetSize {
      ops.append(.compress(targetSize: size))
    }
    ops.append(contentsOf: filters.map { .filter(type: $0) })

    return ops
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
