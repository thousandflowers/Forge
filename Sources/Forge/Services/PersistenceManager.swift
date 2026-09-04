import Foundation
import UniformTypeIdentifiers

/// File-based persistence using JSON in Application Support
actor PersistenceManager {
  static let shared = PersistenceManager()

  private let fileManager = FileManager.default
  private let presetsDir: URL
  private let foldersFile: URL
  private let historyFile: URL

  /// Root of everything Forge stores for the user.
  static var supportDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Forge")
  }


  /// The root this instance stores under. Tests point it at a scratch
  /// directory so a test run cannot touch the files the app is keeping for the
  /// person using it.
  nonisolated let root: URL

  init(root: URL = PersistenceManager.supportDirectory) {
    self.root = root

    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)

    self.presetsDir = root.appendingPathComponent("Presets")
    self.foldersFile = root.appendingPathComponent("MonitoredFolders.json")
    self.historyFile = root.appendingPathComponent("History.json")

    try? fileManager.createDirectory(at: presetsDir, withIntermediateDirectories: true, attributes: nil)
  }

  /// Copies of files taken before an in-place conversion replaces them.
  nonisolated var backupsDirectory: URL { root.appendingPathComponent("Backups") }

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
      let data = try Data(contentsOf: file)
      return try JSONDecoder().decode(RulePreset.self, from: data)
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
    var history = (try? await loadHistory()) ?? []
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

  func clearHistory() async throws {
    if fileManager.fileExists(atPath: historyFile.path) {
      try fileManager.removeItem(at: historyFile)
    }
  }

}

// URL and UTType already conform to Codable via Foundation
