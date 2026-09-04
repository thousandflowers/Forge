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
  /// Only the last underscore-separated piece is read, so `holiday_2024_5MB`
  /// works and `10MB_notes` — where the size is the subject rather than the
  /// instruction — does not.
  static func ceiling(in fileName: String) -> Int? {
    let stem = (fileName as NSString).deletingPathExtension
    guard let piece = stem.split(separator: "_").last.map(String.init), piece != stem else {
      return nil
    }

    let token = piece.lowercased().replacingOccurrences(of: ",", with: ".")
    for unit in units where token.hasSuffix(unit.suffix) {
      let number = String(token.dropLast(unit.suffix.count))
      guard !number.isEmpty, let value = Double(number), value > 0 else { continue }
      let bytes = value * unit.bytes
      guard bytes >= 1 else { continue }
      return Int(bytes)
    }
    return nil
  }

  /// The chain with that ceiling in it, if the name asked for one. A ceiling
  /// already in the chain is replaced: the name is the more specific answer.
  static func applying(to operations: [Operation], from fileName: String) -> [Operation] {
    guard let bytes = ceiling(in: fileName) else { return operations }
    var result = operations.filter { if case .limitSize = $0 { return false } else { return true } }
    result.append(.limitSize(bytes: bytes))
    return result
  }
}
