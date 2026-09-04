import Foundation
import UniformTypeIdentifiers

// MARK: - Operation

/// Individual transformation operation to apply to a file
enum Operation: Codable, Hashable, Identifiable, Sendable {
  case convertFormat(to: UTType)
  case resize(width: Int?, height: Int?, fitMode: ResizeFitMode)
  case quality(level: Int)           // 1-100
  case filter(type: FilterType)

  var id: String {
    switch self {
    case .convertFormat: return "convert"
    case .resize: return "resize"
    case .quality: return "quality"
    case .filter: return "filter"
    }
  }

  // MARK: - Codable

  private enum CodingKeys: String, CodingKey {
    case type, to, width, height, fitMode, level, filter
  }

  private enum OperationType: String, Codable {
    case convertFormat, resize, quality, filter
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(OperationType.self, forKey: .type)

    switch type {
    case .convertFormat:
      let to = try container.decode(UTType.self, forKey: .to)
      self = .convertFormat(to: to)
    case .resize:
      let width = try container.decodeIfPresent(Int.self, forKey: .width)
      let height = try container.decodeIfPresent(Int.self, forKey: .height)
      let mode = try container.decode(ResizeFitMode.self, forKey: .fitMode)
      self = .resize(width: width, height: height, fitMode: mode)
    case .quality:
      let level = try container.decode(Int.self, forKey: .level)
      self = .quality(level: level)
    case .filter:
      let filter = try container.decode(FilterType.self, forKey: .filter)
      self = .filter(type: filter)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .convertFormat(let to):
      try container.encode(OperationType.convertFormat, forKey: .type)
      try container.encode(to, forKey: .to)
    case .resize(let width, let height, let mode):
      try container.encode(OperationType.resize, forKey: .type)
      try container.encodeIfPresent(width, forKey: .width)
      try container.encodeIfPresent(height, forKey: .height)
      try container.encode(mode, forKey: .fitMode)
    case .quality(let level):
      try container.encode(OperationType.quality, forKey: .type)
      try container.encode(level, forKey: .level)
    case .filter(let filter):
      try container.encode(OperationType.filter, forKey: .type)
      try container.encode(filter, forKey: .filter)
    }
  }
}

// MARK: - Supporting Types

enum ResizeFitMode: String, Codable, Hashable, CaseIterable, Sendable {
  case proportional    // Scale to fit within bounds, preserve aspect ratio
  case cropCenter      // Scale to fill, then crop center
  case stretch         // Stretch to exact dimensions (distorts)
  case pad             // Scale to fit, pad with background
}

enum FilterType: String, Codable, Hashable, CaseIterable, Sendable {
  case grayscale
  case sepia
  case blur
  case sharpen
  case invert
}
