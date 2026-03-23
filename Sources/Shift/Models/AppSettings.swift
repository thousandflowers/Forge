import Foundation

/// User-configurable application settings
struct AppSettings: Codable, Sendable {
  var nativeProcessorsEnabled: Bool = true
  var externalProcessorsEnabled: Bool = false

  var enabledExternalTools: Set<String> = []

  var maxConcurrentNative: Int = 2  // Range 1-8
  var maxConcurrentExternal: Int = 1  // Range 1-2

  var memoryWarningThresholdMB: Int = 1024

  var preserveOriginalMetadata: Bool = true
  var createBackupBeforeOverwrite: Bool = true
  var backupFolderPath: String?  // Default: ~/Library/Application Support/FileForge/Backups

  var showNotifications: Bool = true

  var tempFolderPath: String = {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
      .first!.appendingPathComponent("FileForge").path
  }()

  var tempFolderURL: URL {
    URL(fileURLWithPath: tempFolderPath)
  }

  // MARK: - Persistence

  private static let settingsKey = "FileForgeSettings"

  static func load() -> AppSettings {
    if let data = UserDefaults.standard.data(forKey: settingsKey),
       let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
      return settings
    }
    return AppSettings()
  }

  func save() throws {
    let data = try JSONEncoder().encode(self)
    UserDefaults.standard.set(data, forKey: Self.settingsKey)
  }
}
