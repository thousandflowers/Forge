import Foundation
import UniformTypeIdentifiers

/// File-based persistence using JSON in Application Support
actor PersistenceManager {
  static let shared = PersistenceManager()

  private let fileManager = FileManager.default
  private let presetsDir: URL
  private let foldersFile: URL
  private let historyFile: URL

  /// The log in memory. Appending used to re-read and re-decode the whole file
  /// for every single converted file, which turned a large batch quadratic.
  private var cachedHistory: [ProcessingHistory]?

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
    // Skip anything that will not decode. One stray file used to take every
    // preset down with it and leave the app looking freshly installed.
    return files.compactMap { file in
      guard file.pathExtension == "json",
            let data = try? Data(contentsOf: file) else { return nil }
      return try? JSONDecoder().decode(RulePreset.self, from: data)
    }
  }

  func deletePreset(id: UUID) async throws {
    let fileURL = presetsDir.appendingPathComponent("\(id.uuidString).json")
    try fileManager.removeItem(at: fileURL)
  }

  /// Write presets to a file the user chose, for sharing or keeping.
  func export(_ presets: [RulePreset], to url: URL) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(presets).write(to: url, options: .atomic)
  }

  /// Read presets from a file. Accepts one preset or a list of them, since
  /// people share both.
  func importPresets(from url: URL) async throws -> [RulePreset] {
    let data = try Data(contentsOf: url)
    if let many = try? JSONDecoder().decode([RulePreset].self, from: data) { return many }
    return [try JSONDecoder().decode(RulePreset.self, from: data)]
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

  // MARK: - Extensions

  /// Where fetched tools live: one folder per tool, one folder per version
  /// inside it. Under the same root as everything else Forge keeps, so
  /// removing that folder removes the lot.
  nonisolated var extensionsDirectory: URL { root.appendingPathComponent("Extensions") }

  private var extensionsFile: URL { root.appendingPathComponent("Extensions.json") }

  func saveInstalledExtensions(_ installed: [InstalledExtension]) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(installed).write(to: extensionsFile, options: .atomic)
  }

  func loadInstalledExtensions() async throws -> [InstalledExtension] {
    Self.readInstalledExtensions(under: root)
  }

  /// The same list, read without waiting on the actor.
  ///
  /// `ExternalTools.locate` is synchronous and is called from everywhere,
  /// including code that decides whether to offer a conversion at all. The
  /// file is only ever written atomically, so reading it from outside is
  /// reading one whole version of it or the previous one, never half of each.
  nonisolated func installedExtensionsSnapshot() -> [InstalledExtension] {
    Self.readInstalledExtensions(under: root)
  }

  private static func readInstalledExtensions(under root: URL) -> [InstalledExtension] {
    let file = root.appendingPathComponent("Extensions.json")
    guard let data = try? Data(contentsOf: file) else { return [] }
    return (try? JSONDecoder().decode([InstalledExtension].self, from: data)) ?? []
  }

  // MARK: - History

  func appendHistory(_ entry: ProcessingHistory) async throws {
    var history = try cachedHistory ?? loadHistory()
    history.append(entry)
    // Keep last 1000 entries
    if history.count > 1000 {
      history = Array(history.suffix(1000))
    }
    let data = try JSONEncoder().encode(history)
    try data.write(to: historyFile, options: .atomic)
    cachedHistory = history
  }

  func loadHistory() throws -> [ProcessingHistory] {
    if let cachedHistory { return cachedHistory }
    guard fileManager.fileExists(atPath: historyFile.path) else { return [] }
    let data = try Data(contentsOf: historyFile)
    let history = try JSONDecoder().decode([ProcessingHistory].self, from: data)
    cachedHistory = history
    return history
  }

  func clearHistory() async throws {
    if fileManager.fileExists(atPath: historyFile.path) {
      try fileManager.removeItem(at: historyFile)
    }
    cachedHistory = []
  }
}

// URL and UTType already conform to Codable via Foundation
