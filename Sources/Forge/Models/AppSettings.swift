import Foundation

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
