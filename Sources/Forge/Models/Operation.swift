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
  /// Encode with a specific codec, where the container allows more than one.
  case encode(codec: Codec)
  /// Come out no larger than this many bytes, whatever it takes.
  ///
  /// Unlike quality, this is a promise about the result rather than a setting
  /// handed to the encoder: the file is written, measured, and written again
  /// lower until it fits.
  case limitSize(bytes: Int)
  /// Leave out what the file says about the person, the device and the moment.
  ///
  /// A step in the chain like any other, so it can come from Settings, from a
  /// preset, from a batch, or from the filename - and so history records that
  /// it happened.
  case stripMetadata(policy: PrivacyPolicy)
  /// One of two chains, decided per file: too big goes one way, the rest the
  /// other.
  case when(Condition, then: [Operation], otherwise: [Operation])
  /// Every branch on its own copy of the file. One preset, several outputs,
  /// each down its own path.
  case split([Branch])
  /// The arms of a split rejoin here: what follows runs on every copy, the
  /// copies staying separate files. A marker for the editor; the chain runs
  /// the same with or without it.
  case join
  /// The copies from a split become one file.
  case merge(MergeKind)

  /// A short name for the action, as the editor lists it.
  var title: String {
    switch self {
    case .when(let condition, _, _): return "If \(condition.summary)"
    case .split(let branches): return "Split into \(branches.count) copies"
    case .join: return "Paths rejoin"
    case .merge(let kind): return "Merge into \(kind.title)"
    case .convertFormat: return "Convert format"
    case .resize(_, _, let mode): return mode == .cropCenter ? "Crop" : "Resize"
    case .quality: return "Set quality"
    case .filter: return "Apply filter"
    case .recognizeText: return "Read text"
    case .encode: return "Choose codec"
    case .limitSize: return "Fit within a size"
    case .stripMetadata: return "Remove metadata"
    }
  }

  var symbol: String {
    switch self {
    case .convertFormat: return "arrow.triangle.2.circlepath"
    case .resize(_, _, let mode): return mode == .cropCenter ? "crop" : "aspectratio"
    case .quality: return "dial.medium"
    case .filter: return "camera.filters"
    case .recognizeText: return "text.viewfinder"
    case .encode: return "cpu"
    case .limitSize: return "arrow.down.right.and.arrow.up.left"
    case .stripMetadata(let policy): return policy.symbol
    case .when: return "arrow.triangle.branch"
    case .split: return "square.split.2x1"
    case .join: return "arrow.triangle.merge"
    case .merge: return "doc.on.doc"
    }
  }

  var id: String {
    switch self {
    case .convertFormat: return "convert"
    case .resize: return "resize"
    case .quality: return "quality"
    case .filter: return "filter"
    case .recognizeText: return "ocr"
    case .encode: return "codec"
    case .limitSize: return "limitSize"
    case .stripMetadata: return "privacy"
    case .when: return "when"
    case .split: return "split"
    case .join: return "join"
    case .merge: return "merge"
    }
  }

  /// Whether this is a fork in the chain rather than a step that changes a file.
  var isLogic: Bool {
    switch self {
    case .when, .split, .join, .merge: return true
    default: return false
    }
  }

  /// Every step under this one, branches included, in order. For anything
  /// that reads a chain flat: what format it writes, which chips to show.
  var leaves: [Operation] {
    switch self {
    case .when(_, let then, let otherwise): return (then + otherwise).flatMap(\.leaves)
    case .split(let branches): return branches.flatMap { $0.actions.flatMap(\.leaves) }
    case .join, .merge: return []
    default: return [self]
    }
  }
}

/// What the copies from a split become when they are merged.
enum MergeKind: String, Codable, CaseIterable, Sendable {
  case pdf

  var title: String {
    switch self {
    case .pdf: return "one PDF"
    }
  }
}

/// One path out of a split: a name, so its output can be told apart, and
/// the steps down it.
struct Branch: Codable, Hashable, Sendable {
  var name: String
  var actions: [Operation] = []
}

/// Something true or false about a file before it is converted.
struct Condition: Codable, Hashable, Sendable {
  enum Subject: String, Codable, CaseIterable, Sendable {
    case longestSide, width, height, fileSize, fileExtension

    var title: String {
      switch self {
      case .longestSide: return "Longest side"
      case .width: return "Width"
      case .height: return "Height"
      case .fileSize: return "File size"
      case .fileExtension: return "Extension"
      }
    }

    var unit: String {
      switch self {
      case .longestSide, .width, .height: return "px"
      case .fileSize: return "MB"
      case .fileExtension: return ""
      }
    }

    var isNumeric: Bool { self != .fileExtension }
  }

  enum Comparison: String, Codable, CaseIterable, Sendable {
    case greaterThan, lessThan, equals, differs

    var title: String {
      switch self {
      case .greaterThan: return "is more than"
      case .lessThan: return "is less than"
      case .equals: return "is"
      case .differs: return "is not"
      }
    }
  }

  var subject: Subject = .longestSide
  var comparison: Comparison = .greaterThan
  /// Pixels or megabytes, depending on the subject.
  var value: Double = 2000
  /// The extension, for `.fileExtension`.
  var text: String = "png"

  /// Whether the file passes. A measure the file cannot give - a video's
  /// width before its tracks are read - fails rather than guesses.
  func holds(for file: ProcessableFile) -> Bool {
    switch subject {
    case .fileExtension:
      let same = file.url.pathExtension.lowercased() == text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
      return comparison == .differs ? !same : same
    case .fileSize:
      return compare(Double(file.fileSize) / 1_000_000)
    case .width:
      guard let size = file.dimensions else { return false }
      return compare(Double(size.width))
    case .height:
      guard let size = file.dimensions else { return false }
      return compare(Double(size.height))
    case .longestSide:
      guard let size = file.dimensions else { return false }
      return compare(Double(max(size.width, size.height)))
    }
  }

  private func compare(_ measured: Double) -> Bool {
    switch comparison {
    case .greaterThan: return measured > value
    case .lessThan: return measured < value
    case .equals: return measured == value
    case .differs: return measured != value
    }
  }

  /// "longest side is more than 2000 px", as the block titles itself.
  var summary: String {
    let number = value == value.rounded() ? String(Int(value)) : String(value)
    let what = subject.isNumeric ? "\(number) \(subject.unit)" : ".\(text)"
    return "\(subject.title.lowercased()) \(comparison.title) \(what)"
  }
}

/// A chain made flat for one file: the chains that run, and whether what
/// they write is merged into one file afterwards.
struct Resolution {
  var chains: [(branch: String?, actions: [Operation])]
  var merge: MergeKind?
}

extension Array where Element == Operation {
  /// The flat chains this chain becomes for one file: every `when` decided,
  /// every `split` fanned out, a join passed over, a merge noted. One chain
  /// and no branch name is the ordinary case; more than one means more than
  /// one file comes out.
  func resolved(for file: ProcessableFile) -> Resolution {
    var merge: MergeKind?
    var chains: [(branch: String?, actions: [Operation])] = [(nil, [])]
    for operation in self {
      switch operation {
      case .join:
        continue
      case .merge(let kind):
        merge = kind
      case .when(let condition, let then, let otherwise):
        let taken = (condition.holds(for: file) ? then : otherwise).resolved(for: file).chains
        chains = chains.flatMap { chain in taken.map { (Self.join(chain.branch, $0.branch), chain.actions + $0.actions) } }
      case .split(let branches):
        chains = chains.flatMap { chain in
          branches.flatMap { branch in
            branch.actions.resolved(for: file).chains.map { (Self.join(Self.join(chain.branch, branch.name), $0.branch), chain.actions + $0.actions) }
          }
        }
      default:
        chains = chains.map { ($0.branch, $0.actions + [operation]) }
      }
    }
    return Resolution(chains: chains, merge: merge)
  }

  private static func join(_ a: String?, _ b: String?) -> String? {
    [a, b].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "-").nilIfEmpty
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Codable

extension Operation {
  private enum CodingKeys: String, CodingKey {
    case kind, format, width, height, fitMode, level, filter, languages, codec, bytes, privacy
    case condition, then, otherwise, branches, mergeKind
  }

  private enum Kind: String, Codable {
    case convertFormat, resize, quality, filter, recognizeText, encode, limitSize, stripMetadata
    case when, split, join, merge
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
    case .encode:
      self = .encode(codec: try container.decode(Codec.self, forKey: .codec))
    case .limitSize:
      self = .limitSize(bytes: try container.decode(Int.self, forKey: .bytes))
    case .stripMetadata:
      self = .stripMetadata(policy: try container.decode(PrivacyPolicy.self, forKey: .privacy))
    case .when:
      self = .when(
        try container.decode(Condition.self, forKey: .condition),
        then: try container.decodeIfPresent([Operation].self, forKey: .then) ?? [],
        otherwise: try container.decodeIfPresent([Operation].self, forKey: .otherwise) ?? []
      )
    case .split:
      self = .split(try container.decodeIfPresent([Branch].self, forKey: .branches) ?? [])
    case .join:
      self = .join
    case .merge:
      self = .merge(try container.decodeIfPresent(MergeKind.self, forKey: .mergeKind) ?? .pdf)
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
    case .encode(let codec):
      try container.encode(Kind.encode, forKey: .kind)
      try container.encode(codec, forKey: .codec)
    case .limitSize(let bytes):
      try container.encode(Kind.limitSize, forKey: .kind)
      try container.encode(bytes, forKey: .bytes)
    case .stripMetadata(let policy):
      try container.encode(Kind.stripMetadata, forKey: .kind)
      try container.encode(policy, forKey: .privacy)
    case .when(let condition, let then, let otherwise):
      try container.encode(Kind.when, forKey: .kind)
      try container.encode(condition, forKey: .condition)
      try container.encode(then, forKey: .then)
      try container.encode(otherwise, forKey: .otherwise)
    case .split(let branches):
      try container.encode(Kind.split, forKey: .kind)
      try container.encode(branches, forKey: .branches)
    case .join:
      try container.encode(Kind.join, forKey: .kind)
    case .merge(let kind):
      try container.encode(Kind.merge, forKey: .kind)
      try container.encode(kind, forKey: .mergeKind)
    }
  }
}

// MARK: - Supporting Types

enum ResizeFitMode: String, Codable, Hashable, CaseIterable, Sendable {
  case proportional    // Scale to fit within bounds, preserve aspect ratio
  case cropCenter      // Scale to fill, then crop center
  case stretch         // Stretch to exact dimensions (distorts)
  case pad             // Scale to fit, pad with background

  /// What each one does, said the way somebody choosing would say it.
  var title: String {
    switch self {
    case .proportional: return "Fit inside"
    case .cropCenter: return "Fill and crop"
    case .stretch: return "Stretch"
    case .pad: return "Pad out"
    }
  }
}

enum FilterType: String, Codable, Hashable, CaseIterable, Sendable {
  case grayscale
  case sepia
  case blur
  case sharpen
  case invert
}
