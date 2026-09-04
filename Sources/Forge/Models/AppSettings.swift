import Foundation
import UniformTypeIdentifiers

/// User-configurable settings.
///
/// Only settings that change what Forge does live here. The screen used to
/// offer a memory threshold, a metadata toggle, a notifications switch and a
/// processor switch, none of which were read anywhere.
struct AppSettings: Codable, Sendable, Equatable {
  /// How many files convert at once. Range 1-8.
  var maxConcurrentNative: Int = 2

  /// Keep a copy of the original before an in-place conversion replaces it.
  var createBackupBeforeOverwrite: Bool = true

  /// Post a notification when a batch finishes.
  var notifyWhenFinished: Bool = true

  // MARK: - What everything starts from
  //
  // A preference here is what Forge does when a preset does not say otherwise.
  // Every one of them can be overridden on the preset, and again on the batch:
  // general, then specific, then this once.

  /// What resizing means when nobody says: fit inside, fill and crop, stretch,
  /// or pad out to the exact box.
  var defaultFitMode: ResizeFitMode = .proportional

  /// The quality used when a preset names none. 1-100.
  var defaultQuality: Int = 80

  /// How an output file is named. `{name}` is the original's name without its
  /// extension; a preset's parameters are available by their own keys, so a
  /// preset asking for a size ceiling under the key `maxsize` can be named
  /// `{name}_{maxsize}` and produce `holiday_10MB.jpg`.
  var nameTemplate: String = "{name}"

  /// The chain a preset asked for, with the general preferences filled in
  /// wherever it did not say. A preference is only a preference if something
  /// actually reads it when nobody overrides it.
  ///
  /// - Parameter writing: what the chain ends up writing. Quality is only put
  ///   in for images: an audio encoder reads a quality as a bitrate, and Apple
  ///   Lossless refuses a bitrate outright — a general preference must not turn
  ///   a working conversion into a failure.
  func applyingDefaults(to operations: [Operation], writing target: UTType?) -> [Operation] {
    guard let target, FormatCatalog.isWritableImage(target) else { return operations }

    let saysQuality = operations.contains { if case .quality = $0 { return true } else { return false } }
    guard !saysQuality else { return operations }

    return operations + [.quality(level: defaultQuality)]
  }

  // MARK: - Persistence

  private static let settingsKey = "ForgeSettings"

  static func load() -> AppSettings {
    guard let data = UserDefaults.standard.data(forKey: settingsKey),
          let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
      return AppSettings()
    }
    return settings
  }

  func save() throws {
    let data = try JSONEncoder().encode(self)
    UserDefaults.standard.set(data, forKey: Self.settingsKey)
  }
}
