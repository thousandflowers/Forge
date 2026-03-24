import Foundation
import UniformTypeIdentifiers

/// File-based persistence using JSON in Application Support
actor PersistenceManager {
  static let shared = PersistenceManager()

  private let fileManager = FileManager.default
  private let presetsDir: URL
  private let foldersFile: URL
  private let historyFile: URL
  private let settingsFile: URL

  private init() {
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!.appendingPathComponent("Shift")

    try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)

    self.presetsDir = appSupport.appendingPathComponent("Presets")
    self.foldersFile = appSupport.appendingPathComponent("MonitoredFolders.json")
    self.historyFile = appSupport.appendingPathComponent("History.json")
    self.settingsFile = appSupport.appendingPathComponent("Settings.json")

    try? fileManager.createDirectory(at: presetsDir, withIntermediateDirectories: true, attributes: nil)
  }

  // MARK: - Presets

  func savePreset(_ preset: RulePreset) async throws {
    let fileURL = presetsDir.appendingPathComponent("\(preset.id.uuidString).json")
    let data = try JSONEncoder().encode(preset)
    try data.write(to: fileURL, options: .atomic)
  }

  func loadPreset(id: UUID) async throws -> RulePreset? {
    let fileURL = presetsDir.appendingPathComponent("\(id.uuidString).json")
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(RulePreset.self, from: data)
  }

  func loadAllPresets() async throws -> [RulePreset] {
    let files = try fileManager.contentsOfDirectory(at: presetsDir, includingPropertiesForKeys: nil)
    let presets = try files.compactMap { file in
      try? Data(contentsOf: file).decode(RulePreset.self)
    }
    return presets
  }

  func deletePreset(id: UUID) async throws {
    let fileURL = presetsDir.appendingPathComponent("\(id.uuidString).json")
    try fileManager.removeItem(at: fileURL)
  }

  // MARK: - Monitored Folders

  func saveMonitoredFolders(_ folders: [MonitoredFolder]) async throws {
    let data = try JSONEncoder().encode(folders)
    try data.write(to: foldersFile, options: .atomic)
  }

  func loadMonitoredFolders() async throws -> [MonitoredFolder] {
    guard fileManager.fileExists(atPath: foldersFile.path) else { return [] }
    let data = try Data(contentsOf: foldersFile)
    return try JSONDecoder().decode([MonitoredFolder].self, from: data)
  }

  // MARK: - History

  func appendHistory(_ entry: ProcessingHistory) async throws {
    var history = (try? loadHistory()) ?? []
    history.append(entry)
    // Keep last 1000 entries
    if history.count > 1000 {
      history = Array(history.suffix(1000))
    }
    let data = try JSONEncoder().encode(history)
    try data.write(to: historyFile, options: .atomic)
  }

  func loadHistory() async throws -> [ProcessingHistory] {
    guard fileManager.fileExists(atPath: historyFile.path) else { return [] }
    let data = try Data(contentsOf: historyFile)
    return try JSONDecoder().decode([ProcessingHistory].self, from: data)
  }

  // MARK: - Settings

  func loadSettings() async throws -> AppSettings {
    guard fileManager.fileExists(atPath: settingsFile.path) else {
      return AppSettings()
    }
    let data = try Data(contentsOf: settingsFile)
    return try JSONDecoder().decode(AppSettings.self, from: data)
  }

  func saveSettings(_ settings: AppSettings) async throws {
    let data = try JSONEncoder().encode(settings)
    try data.write(to: settingsFile, options: .atomic)
  }
}

// MARK: - Codable support for custom types

extension URL: Codable {
  public convenience init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let url = URL(string: string) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid URL string")
    }
    self.init(fileURLWithPath: url.path)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.path)
  }
}

extension UTType: Codable {
  public convenience init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let identifier = try container.decode(String.self)
    self.init(identifier)!
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.identifier)
  }
}
