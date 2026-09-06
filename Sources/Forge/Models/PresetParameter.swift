import Foundation

/// Something a preset asks for instead of deciding.
///
/// A preset with no parameters is a setting: it does the same thing every time.
/// One with parameters is a shape — "make it fit under a size you choose" — and
/// the answer is given at conversion time. The answer can also be spent in the
/// output's name, which is what turns `holiday.png` into `holiday_10MB.jpg`.
struct PresetParameter: Codable, Hashable, Identifiable, Sendable {

  /// What is being asked for. Each kind knows the action it becomes, so a
  /// parameter cannot ask for something no processor would honour.
  enum Kind: String, Codable, CaseIterable, Sendable {
    case maxFileSize
    case width
    case quality

    var title: String {
      switch self {
      case .maxFileSize: return "Maximum size"
      case .width: return "Width"
      case .quality: return "Quality"
      }
    }

    var unit: String {
      switch self {
      case .maxFileSize: return "MB"
      case .width: return "px"
      case .quality: return ""
      }
    }

    /// Sensible bounds for the field that asks, so the question cannot be
    /// answered with something the processors would refuse.
    var range: ClosedRange<Double> {
      switch self {
      case .maxFileSize: return 0.1...2000
      case .width: return 16...16384
      case .quality: return 1...100
      }
    }

    var suggestedDefault: Double {
      switch self {
      case .maxFileSize: return 10
      case .width: return 1920
      case .quality: return 80
      }
    }
  }

  /// Where the answer comes from: a question put once per batch, or the
  /// file's own name (`holiday_10MB.jpg` says ten megabytes).
  enum Source: String, Codable, CaseIterable, Sendable {
    case prompt
    case fileName

    var title: String {
      switch self {
      case .prompt: return "Asked each time"
      case .fileName: return "From the file name"
      }
    }
  }

  /// The name this answer goes by in a filename template, as `{key}`.
  var key: String
  /// How the question is put.
  var label: String
  var kind: Kind
  var defaultValue: Double
  var source: Source

  var id: String { key }

  init(key: String, label: String, kind: Kind, defaultValue: Double? = nil, source: Source = .prompt) {
    self.key = key
    self.label = label
    self.kind = kind
    self.defaultValue = defaultValue ?? kind.suggestedDefault
    self.source = source
  }

  /// What the file's name would have to say to answer this.
  var nameExample: String {
    switch kind {
    case .maxFileSize: return "holiday_10MB.jpg"
    case .width: return "holiday_1920px.jpg"
    case .quality: return "holiday_q80.jpg"
    }
  }

  /// The action this becomes once answered.
  func operation(for value: Double) -> Operation {
    switch kind {
    case .maxFileSize:
      // Megabytes as people mean them on a file listing, which is what the
      // Finder shows: a thousand thousand bytes, not 1024 squared.
      return .limitSize(bytes: Int(value * 1_000_000))
    case .width:
      return .resize(width: Int(value), height: nil, fitMode: .proportional)
    case .quality:
      return .quality(level: Int(value))
    }
  }

  /// How the answer reads in a filename: `10MB`, `1920px`, `Q80`.
  func token(for value: Double) -> String {
    switch kind {
    case .maxFileSize:
      let rounded = value.rounded()
      let number = value == rounded ? String(Int(rounded)) : String(format: "%.1f", value)
      return "\(number)MB"
    case .width:
      return "\(Int(value))px"
    case .quality:
      return "Q\(Int(value))"
    }
  }
}

extension PresetParameter {
  private enum CodingKeys: String, CodingKey { case key, label, kind, defaultValue, source }

  /// `source` is newer than the parameters already saved, so it may be absent.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(Kind.self, forKey: .kind)
    self.init(
      key: try c.decode(String.self, forKey: .key),
      label: try c.decodeIfPresent(String.self, forKey: .label) ?? kind.title,
      kind: kind,
      defaultValue: try c.decodeIfPresent(Double.self, forKey: .defaultValue),
      source: try c.decodeIfPresent(Source.self, forKey: .source) ?? .prompt
    )
  }
}
