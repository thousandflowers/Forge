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

  /// How much of what a file says about its maker survives a conversion, when
  /// nothing more specific says otherwise.
  ///
  /// Defaults to keeping everything: a conversion that quietly drops what the
  /// original said is a conversion that lost something, and this is a choice
  /// rather than a default anybody should have made for them.
  var privacy: PrivacyPolicy = .keepAll

  /// How an output file is named. `{name}` is the original's name without its
  /// extension; a preset's parameters are available by their own keys, so a
  /// preset asking for a size ceiling under the key `maxsize` can be named
  /// `{name}_{maxsize}` and produce `holiday_10MB.jpg`.
  var nameTemplate: String = "{name}"

  /// Whether the window follows the Mac's appearance or picks one. Sheets and
  /// panels are translucent either way.
  var appearance: Appearance = .system

  /// The chain a preset asked for, with the general preferences filled in
  /// wherever it did not say. A preference is only a preference if something
  /// actually reads it when nobody overrides it.
  ///
  /// - Parameter writing: what the chain ends up writing. Quality is only put
  ///   in for images: an audio encoder reads a quality as a bitrate, and Apple
  ///   Lossless refuses a bitrate outright — a general preference must not turn
  ///   a working conversion into a failure.
  func applyingDefaults(to operations: [Operation], writing target: UTType?) -> [Operation] {
    var chain = operations

    // The privacy level applies to everything with metadata in it, which is
    // every kind of file here - unlike quality, which is only meaningful where
    // something is re-encoded.
    let saysPrivacy = chain.contains { if case .stripMetadata = $0 { return true } else { return false } }
    if !saysPrivacy, privacy.removesSomething {
      chain.append(.stripMetadata(policy: privacy))
    }

    guard let target, FormatCatalog.isWritableImage(target) else { return chain }

    let saysQuality = chain.contains { if case .quality = $0 { return true } else { return false } }
    guard !saysQuality else { return chain }

    return chain + [.quality(level: defaultQuality)]
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

extension AppSettings {
  private enum CodingKeys: String, CodingKey {
    case maxConcurrentNative, createBackupBeforeOverwrite, notifyWhenFinished
    case defaultFitMode, defaultQuality, privacy, nameTemplate, appearance
  }

  /// Every key is optional on the way in. A setting added in a later version
  /// must not make an older settings file unreadable and throw the rest away.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let fresh = AppSettings()
    self.init()
    maxConcurrentNative = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentNative) ?? fresh.maxConcurrentNative
    createBackupBeforeOverwrite = try c.decodeIfPresent(Bool.self, forKey: .createBackupBeforeOverwrite) ?? fresh.createBackupBeforeOverwrite
    notifyWhenFinished = try c.decodeIfPresent(Bool.self, forKey: .notifyWhenFinished) ?? fresh.notifyWhenFinished
    defaultFitMode = try c.decodeIfPresent(ResizeFitMode.self, forKey: .defaultFitMode) ?? fresh.defaultFitMode
    defaultQuality = try c.decodeIfPresent(Int.self, forKey: .defaultQuality) ?? fresh.defaultQuality
    privacy = try c.decodeIfPresent(PrivacyPolicy.self, forKey: .privacy) ?? fresh.privacy
    nameTemplate = try c.decodeIfPresent(String.self, forKey: .nameTemplate) ?? fresh.nameTemplate
    appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? fresh.appearance
  }
}
