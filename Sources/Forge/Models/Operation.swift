import Foundation
import UniformTypeIdentifiers

// MARK: - Operation

/// Individual transformation operation to apply to a file
enum Operation: Codable, Hashable, Identifiable, Sendable {
  case convertFormat(to: UTType)
  case resize(width: Int?, height: Int?, fitMode: ResizeFitMode)
  case quality(level: Int)           // 1-100
  case filter(type: FilterType)
  /// Read the text out of an image. Empty languages lets Vision decide.
  case recognizeText(languages: [String])

  /// A short name for the action, as the editor lists it.
  var title: String {
    switch self {
    case .convertFormat: return "Convert format"
    case .resize: return "Resize"
    case .quality: return "Set quality"
    case .filter: return "Apply filter"
    case .recognizeText: return "Read text"
    }
  }

  var symbol: String {
    switch self {
    case .convertFormat: return "arrow.triangle.2.circlepath"
    case .resize: return "aspectratio"
    case .quality: return "dial.medium"
    case .filter: return "camera.filters"
    case .recognizeText: return "text.viewfinder"
    }
  }

  var id: String {
    switch self {
    case .convertFormat: return "convert"
    case .resize: return "resize"
    case .quality: return "quality"
    case .filter: return "filter"
    case .recognizeText: return "ocr"
    }
  }
}

// MARK: - Codable

extension Operation {
  private enum CodingKeys: String, CodingKey {
    case kind, format, width, height, fitMode, level, filter, languages
  }

  private enum Kind: String, Codable {
    case convertFormat, resize, quality, filter, recognizeText
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .convertFormat:
      self = .convertFormat(to: try container.decode(UTType.self, forKey: .format))
    case .resize:
      self = .resize(
        width: try container.decodeIfPresent(Int.self, forKey: .width),
        height: try container.decodeIfPresent(Int.self, forKey: .height),
        fitMode: try container.decodeIfPresent(ResizeFitMode.self, forKey: .fitMode) ?? .proportional
      )
    case .quality:
      self = .quality(level: try container.decode(Int.self, forKey: .level))
    case .filter:
      self = .filter(type: try container.decode(FilterType.self, forKey: .filter))
    case .recognizeText:
      self = .recognizeText(languages: try container.decodeIfPresent([String].self, forKey: .languages) ?? [])
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .convertFormat(let to):
      try container.encode(Kind.convertFormat, forKey: .kind)
      try container.encode(to, forKey: .format)
    case .resize(let width, let height, let fitMode):
      try container.encode(Kind.resize, forKey: .kind)
      try container.encodeIfPresent(width, forKey: .width)
      try container.encodeIfPresent(height, forKey: .height)
      try container.encode(fitMode, forKey: .fitMode)
    case .quality(let level):
      try container.encode(Kind.quality, forKey: .kind)
      try container.encode(level, forKey: .level)
    case .filter(let type):
      try container.encode(Kind.filter, forKey: .kind)
      try container.encode(type, forKey: .filter)
    case .recognizeText(let languages):
      try container.encode(Kind.recognizeText, forKey: .kind)
      try container.encode(languages, forKey: .languages)
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
