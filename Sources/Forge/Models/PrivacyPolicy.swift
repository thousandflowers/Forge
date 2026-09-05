import Foundation

/// How much of what a file says about the person who made it survives a
/// conversion.
///
/// A photograph carries where it was taken, which camera took it, which lens,
/// and often the serial number of both. A PDF carries who wrote it and what
/// wrote it. None of that is the picture or the document, and all of it travels
/// when the file is sent to somebody.
///
/// What is never dropped, at any level: the colour profile and the orientation.
/// Those are not information about a person, they are what makes the file look
/// like itself - drop the profile and the colours shift, drop the orientation
/// and the photograph arrives on its side.
enum PrivacyPolicy: String, Codable, Sendable, Hashable, CaseIterable {
  /// Carry everything across, which is what a conversion should do when
  /// nobody asked otherwise.
  case keepAll
  /// Take out where it was made, and nothing else.
  case stripLocation
  /// Take out everything that identifies a person, a device or a moment.
  case stripAll

  var title: String {
    switch self {
    case .keepAll: return "Keep all metadata"
    case .stripLocation: return "Remove the location"
    case .stripAll: return "Remove identifying metadata"
    }
  }

  var summary: String {
    switch self {
    case .keepAll:
      return "Everything the original says about itself is carried across."
    case .stripLocation:
      return "Where the file was made is removed. Everything else stays."
    case .stripAll:
      return "Location, device, serial numbers, author and timestamps are removed. "
        + "The colour profile and the orientation stay: without them the file no longer looks like itself."
    }
  }

  var symbol: String {
    switch self {
    case .keepAll: return "tag"
    case .stripLocation: return "location.slash"
    case .stripAll: return "eye.slash"
    }
  }

  /// Whether this removes anything at all.
  var removesSomething: Bool { self != .keepAll }
}
