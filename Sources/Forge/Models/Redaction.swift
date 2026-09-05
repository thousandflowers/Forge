import CoreGraphics
import Foundation

/// Something in a picture that might want covering up, and the fact that a
/// person has not yet said so.
///
/// This is assistance, not anonymisation. Vision finds faces it recognises as
/// faces and text it can read; a face turned away, a name in handwriting, a
/// reflection in a window, a plate at an angle - all of those are missed,
/// routinely. Nothing here is ever applied on its own, and no part of the app
/// may describe it as making a file anonymous.
struct RedactionCandidate: Identifiable, Hashable, Sendable {
  let id: UUID
  /// Where it is, in the image's own coordinates: 0-1 from the bottom left,
  /// which is what Vision reports and what Core Image draws in.
  let rect: CGRect
  let kind: Kind
  /// How sure the detector was, as it reported it.
  let confidence: Float
  /// What was read there, when something was.
  let text: String?

  init(id: UUID = UUID(), rect: CGRect, kind: Kind, confidence: Float = 0, text: String? = nil) {
    self.id = id
    self.rect = rect
    self.kind = kind
    self.confidence = confidence
    self.text = text
  }

  enum Kind: Hashable, Sendable {
    case face
    /// Text that was read, with nothing said about what it means.
    case text
    /// Text that Natural Language read as a name, a place or an organisation.
    case name(String)

    var title: String {
      switch self {
      case .face: return "Face"
      case .text: return "Text"
      case .name(let what): return what
      }
    }

    var symbol: String {
      switch self {
      case .face: return "person.crop.square"
      case .text: return "textformat"
      case .name: return "person.text.rectangle"
      }
    }
  }
}

/// How a confirmed region is covered.
enum RedactionStyle: String, CaseIterable, Sendable, Hashable {
  /// A solid block. Nothing survives it, which is the point.
  case blackout
  /// Coarse blocks. Reads as deliberate rather than as damage, and is just as
  /// irreversible in the written file.
  case pixellate

  var title: String {
    switch self {
    case .blackout: return "Black out"
    case .pixellate: return "Pixellate"
    }
  }
}

/// One review: what was found, and what a person has actually agreed to cover.
///
/// The distinction is the whole design. `candidates` is what a detector
/// suggested; `confirmed` is what somebody looked at and said yes to. Only the
/// second ever reaches a file, and a session with nothing confirmed produces
/// nothing at all.
struct RedactionSession: Sendable {
  let source: URL
  var candidates: [RedactionCandidate]
  /// The ones a person has ticked. Deliberately starting empty: a detector's
  /// opinion is not consent, and pre-ticking every box would turn a review into
  /// a formality.
  var confirmed: Set<UUID> = []
  var style: RedactionStyle = .blackout

  init(source: URL, candidates: [RedactionCandidate]) {
    self.source = source
    self.candidates = candidates
  }

  func isConfirmed(_ candidate: RedactionCandidate) -> Bool { confirmed.contains(candidate.id) }

  mutating func toggle(_ candidate: RedactionCandidate) {
    if confirmed.contains(candidate.id) {
      confirmed.remove(candidate.id)
    } else {
      confirmed.insert(candidate.id)
    }
  }

  /// A region somebody drew themselves, which is confirmed by the act of
  /// drawing it.
  mutating func add(_ rect: CGRect) {
    let candidate = RedactionCandidate(rect: rect, kind: .text, confidence: 1)
    candidates.append(candidate)
    confirmed.insert(candidate.id)
  }

  mutating func remove(_ candidate: RedactionCandidate) {
    candidates.removeAll { $0.id == candidate.id }
    confirmed.remove(candidate.id)
  }

  /// The only thing that ever reaches the file.
  var confirmedRegions: [CGRect] {
    candidates.filter { confirmed.contains($0.id) }.map(\.rect)
  }

  var hasSomethingToDo: Bool { !confirmedRegions.isEmpty }
}
