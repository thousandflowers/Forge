import Foundation

/// The instructions somebody wrote into a file's own name.
///
/// `holiday_10MB.jpg` says come out under ten megabytes. `contract_privacy.pdf`
/// says take the author details out. `holiday_10MB_privacy.jpg` says both, and
/// that is the reason this exists: reading only the last piece of the name
/// meant the second instruction hid the first.
///
/// Tokens are read from the end and stop at the first piece that is not one.
/// `10MB_notes.jpg` is a file about ten megabytes, not a file to be squeezed
/// into ten - the size has to be the instruction, and an instruction comes at
/// the end.
enum NameTokens {

  struct Read: Equatable {
    /// A ceiling on the finished file, in bytes.
    var ceiling: Int?
    /// How much metadata to leave behind.
    var privacy: PrivacyPolicy?

    var isEmpty: Bool { ceiling == nil && privacy == nil }
  }

  /// What the name asks for.
  static func read(_ fileName: String) -> Read {
    let stem = (fileName as NSString).deletingPathExtension
    let pieces = stem.split(separator: "_").map(String.init)
    // No underscore means no instruction: the whole name is the name.
    guard pieces.count > 1 else { return Read() }

    var read = Read()
    // Never the first piece: a name made only of instructions is a name, and
    // `10MB.jpg` is a file about ten megabytes.
    for piece in pieces.reversed().dropLast() {
      let token = piece.lowercased()
      if token == "privacy" {
        // Typed by hand, about this one file: the most thorough level, since
        // "privacy" is not a request for half of it.
        read.privacy = .stripAll
      } else if let bytes = SizeInName.bytes(in: token) {
        read.ceiling = bytes
      } else {
        // Anything else ends the run. Without this, a date or a word in the
        // middle of a name would be stepped over and whatever came before it
        // read as an instruction.
        break
      }
    }
    return read
  }

  /// The chain with the name's instructions in it.
  ///
  /// They beat what the preset says, because they were typed onto that one file
  /// for this one conversion.
  static func applying(to operations: [Operation], from fileName: String) -> [Operation] {
    let read = read(fileName)
    guard !read.isEmpty else { return operations }

    var result = operations
    if let ceiling = read.ceiling {
      result.removeAll { if case .limitSize = $0 { return true } else { return false } }
      result.append(.limitSize(bytes: ceiling))
    }
    if let privacy = read.privacy {
      result.removeAll { if case .stripMetadata = $0 { return true } else { return false } }
      result.append(.stripMetadata(policy: privacy))
    }
    return result
  }
}
