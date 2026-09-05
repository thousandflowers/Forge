import Foundation

/// A size written into a file's own name.
///
/// Renaming `holiday.jpg` to `holiday_10MB.jpg` is an instruction: come out
/// under ten megabytes. It beats what the preset says, because it was typed
/// onto that one file for this one conversion — and it needs no preset at all,
/// which is the point.
enum SizeInName {

  /// The units people write, and what each is worth. Bytes as a file listing
  /// counts them: a thousand thousand, not 1024 squared, because that is the
  /// number macOS shows and the number somebody is copying.
  private static let units: [(suffix: String, bytes: Double)] = [
    ("gb", 1_000_000_000),
    ("mb", 1_000_000),
    ("kb", 1_000),
    ("g", 1_000_000_000),
    ("m", 1_000_000),
    ("k", 1_000),
  ]

  /// The ceiling a filename asks for, or nil if it asks for nothing.
  ///
  /// Read from the end of the name, so `holiday_2024_5MB` works and
  /// `10MB_notes` — where the size is the subject rather than the instruction —
  /// does not. `NameTokens` reads the rest of what a name can say.
  static func ceiling(in fileName: String) -> Int? {
    NameTokens.read(fileName).ceiling
  }

  /// The size one piece of a name asks for, or nil if that piece is not a size.
  ///
  /// The piece rather than the name: a name can carry more than one
  /// instruction, and which pieces to look at is `NameTokens`' business.
  static func bytes(in token: String) -> Int? {
    let token = token.lowercased().replacingOccurrences(of: ",", with: ".")
    for unit in units where token.hasSuffix(unit.suffix) {
      let number = String(token.dropLast(unit.suffix.count))
      guard !number.isEmpty, let value = Double(number), value > 0 else { continue }
      let bytes = value * unit.bytes
      guard bytes >= 1 else { continue }
      return Int(bytes)
    }
    return nil
  }

  /// The chain with that ceiling in it, if the name asked for one.
  static func applying(to operations: [Operation], from fileName: String) -> [Operation] {
    NameTokens.applying(to: operations, from: fileName)
  }
}
