import AppKit

/// The keys that bring the menu up over a file being dragged. Only the ones
/// that can be held without typing anything: the rest cannot be seen without
/// being let into everything that is typed.
struct HoldKeys: OptionSet, Codable, Hashable, Sendable {
  let rawValue: Int

  static let shift = HoldKeys(rawValue: 1)
  static let control = HoldKeys(rawValue: 2)
  static let option = HoldKeys(rawValue: 4)
  static let command = HoldKeys(rawValue: 8)
  static let globe = HoldKeys(rawValue: 16)

  struct Key: Identifiable {
    let keys: HoldKeys
    let symbol: String
    let name: String
    let flag: NSEvent.ModifierFlags
    var id: Int { keys.rawValue }
  }

  static let all = [
    Key(keys: .globe, symbol: "fn", name: "Globe", flag: .function),
    Key(keys: .control, symbol: "⌃", name: "Control", flag: .control),
    Key(keys: .option, symbol: "⌥", name: "Option", flag: .option),
    Key(keys: .shift, symbol: "⇧", name: "Shift", flag: .shift),
    Key(keys: .command, symbol: "⌘", name: "Command", flag: .command),
  ]

  static let usual: HoldKeys = .shift

  /// What is being held, and nothing about Caps Lock.
  init(_ flags: NSEvent.ModifierFlags) {
    self = Self.all.reduce(into: []) { if flags.contains($1.flag) { $0.insert($1.keys) } }
  }

  init(rawValue: Int) { self.rawValue = rawValue }

  /// Exactly these: ⇧⌘ is somebody else's shortcut.
  func areHeld(_ flags: NSEvent.ModifierFlags) -> Bool { !isEmpty && HoldKeys(flags) == self }

  var symbols: String { Self.all.filter { contains($0.keys) }.map(\.symbol).joined() }

  /// With that key in or out. The last one stays: no key at all would be a
  /// menu on every drag, or on none.
  func toggling(_ key: HoldKeys) -> HoldKeys {
    let toggled = symmetricDifference(key)
    return toggled.isEmpty ? self : toggled
  }

  /// Anything unreadable is the usual key, not a menu that cannot be had.
  init(from decoder: Decoder) throws {
    let known = Self.all.reduce(into: HoldKeys()) { $0.formUnion($1.keys) }
    let read = HoldKeys(rawValue: try decoder.singleValueContainer().decode(Int.self)).intersection(known)
    self = read.isEmpty ? .usual : read
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
