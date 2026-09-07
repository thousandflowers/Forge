import SwiftUI
import UniformTypeIdentifiers

struct LibraryEntry: Identifiable {
  enum Group: String, CaseIterable {
    case output = "Comes out"
    case ask = "Asks"
    case transform = "Changes"
    case encode = "Encodes"
    case privacy = "Privacy"
    case logic = "Logic"

    /// One colour per group, the way Shortcuts colours its actions.
    var color: Color {
      switch self {
      // The system's own colours, the ones Shortcuts paints its actions
      // with: alive on the small icon squares, and they follow light and dark.
      case .logic: return .indigo
      case .output: return .blue
      case .ask: return .purple
      case .transform: return .orange
      case .encode: return .green
      case .privacy: return .pink
      }
    }
  }

  enum Kind {
    case formats
    case template
    case question(PresetParameter.Kind)
    case step(ActionKind)
  }

  let kind: Kind
  let group: Group
  let title: String
  let symbol: String
  let summary: String

  /// Two blocks can share a title - "Quality" is both a question and a step -
  /// so the group is part of the identity.
  var id: String { "\(group.rawValue)/\(title)" }

  /// Everything the library offers for a kind of preset, in the order it is
  /// shown. Built from the same lists the app runs on, so a new step kind
  /// shows up here without a second list to keep in step.
  static func all(for category: PresetCategory) -> [LibraryEntry] {
    var entries: [LibraryEntry] = [
      LibraryEntry(kind: .formats, group: .output, title: "Comes out as", symbol: "arrow.triangle.2.circlepath", summary: "Which formats the files are written in"),
      LibraryEntry(kind: .template, group: .output, title: "Names files", symbol: "textformat", summary: "What the finished files are called"),
    ]
    entries += PresetParameter.Kind.allCases.map {
      LibraryEntry(kind: .question($0), group: .ask, title: $0.title, symbol: "questionmark.circle", summary: "Asked every time the preset runs")
    }
    entries += ActionKind.allCases.filter { $0.suits(category) }.map {
      LibraryEntry(kind: .step($0), group: $0.libraryGroup, title: $0.title, symbol: $0.symbol, summary: $0.summary)
    }
    return entries
  }
}

extension ActionKind {
  var libraryGroup: LibraryEntry.Group {
    switch self {
    case .crop, .resize, .filter, .recognizeText: return .transform
    case .quality, .limitSize, .encode: return .encode
    case .privacy: return .privacy
    case .when, .split, .join, .merge: return .logic
    }
  }

  var summary: String {
    switch self {
    case .crop: return "Fill a box and cut what does not fit"
    case .resize: return "Fit inside a box, keeping the shape"
    case .quality: return "How much to compress"
    case .limitSize: return "Stay under a size you choose"
    case .filter: return "Grayscale, sepia, blur, sharpen, invert"
    case .recognizeText: return "Read the words in it into text"
    case .encode: return "Which codec writes the file"
    case .privacy: return "What the file stops saying about you"
    case .when: return "One path if the file passes a test, another if not"
    case .split: return "Several copies, each down its own path"
    case .join: return "The copies carry on together, still separate files"
    case .merge: return "The copies become one file, a page each"
    }
  }
}

/// An action with a stable identity, so a list can move it around without the
/// rows swapping their contents underneath the user. A fork carries its
/// branches as trees of the same, so every step everywhere can be dragged.

enum ActionKind: String, CaseIterable, Identifiable {
  case crop, resize, quality, limitSize, filter, recognizeText, encode, privacy, when, split, join, merge
  var id: String { rawValue }

  var title: String {
    switch self {
    case .crop: return "Crop"
    case .resize: return "Resize"
    case .quality: return "Quality"
    case .limitSize: return "Fit within a size"
    case .filter: return "Filter"
    case .recognizeText: return "Read the text"
    case .encode: return "Codec"
    case .privacy: return "Remove metadata"
    case .when: return "If…"
    case .split: return "Split into copies"
    case .join: return "Join the paths"
    case .merge: return "Merge into one file"
    }
  }

  var symbol: String {
    switch self {
    case .crop: return "crop"
    case .resize: return "aspectratio"
    case .quality: return "dial.medium"
    case .limitSize: return "arrow.down.right.and.arrow.up.left"
    case .filter: return "camera.filters"
    case .recognizeText: return "text.viewfinder"
    case .encode: return "cpu"
    case .privacy: return "eye.slash"
    case .when: return "arrow.triangle.branch"
    case .split: return "square.split.2x1"
    case .join: return "arrow.triangle.merge"
    case .merge: return "doc.on.doc"
    }
  }

  /// What the step starts as. A crop starts square and cropping, because a
  /// crop that fits inside is a resize by another name.
  func blank(for category: PresetCategory) -> Operation {
    switch self {
    case .crop: return .resize(width: 1080, height: 1080, fitMode: .cropCenter)
    case .resize: return .resize(width: 1920, height: nil, fitMode: .proportional)
    case .quality: return .quality(level: ImageProcessor.defaultQuality)
    case .limitSize: return .limitSize(bytes: 10_000_000)
    case .filter: return .filter(type: .grayscale)
    case .recognizeText: return .recognizeText(languages: [])
    case .encode:
      let codecs = category == .audio ? Codec.audioCodecs : Codec.videoCodecs
      return .encode(codec: codecs.first ?? .h264)
    case .privacy: return .stripMetadata(policy: .stripAll)
    case .when: return .when(Condition(), then: [], otherwise: [])
    case .split: return .split([Branch(name: "Copy 1"), Branch(name: "Copy 2")])
    case .join: return .join
    case .merge: return .merge(.pdf)
    }
  }

  /// Which kinds of file this step does anything for, taken from what the
  /// processors honour. Offering a crop on an audio preset would be a step
  /// that runs and changes nothing.
  func suits(_ category: PresetCategory) -> Bool {
    switch self {
    case .crop, .resize:
      return [.image, .video, .document, .custom].contains(category)
    case .quality, .filter:
      return [.image, .video, .document, .custom].contains(category)
    case .limitSize:
      return [.image, .custom].contains(category)
    case .recognizeText:
      return [.image, .video, .document, .custom].contains(category)
    case .encode:
      return [.video, .audio, .custom].contains(category)
    case .privacy:
      // Every kind of file carries something about who made it.
      return true
    case .when, .split, .join, .merge:
      return true
    }
  }
}

