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
  /// When the file held what the cache holds. The `forge` command and the app
  /// write the same file: a cache trusted blindly hid the command's runs, and
  /// the app's next write threw them away.
  private var cachedStamp: Date?

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

  // MARK: - History

  func appendHistory(_ entry: ProcessingHistory) async throws {
    var history: [ProcessingHistory]
    do {
      history = try loadHistory()
    } catch is DecodingError {
      // A History file nothing can read used to fail every conversion after
      // it, for ever: the output was written, and then reported as failed
      // because the record of it could not be added. It is set aside - not
      // thrown away, somebody may want to look - and history starts again.
      setAsideUnreadableHistory()
      history = []
    }
    history.append(entry)
    // Keep last 1000 entries
    if history.count > 1000 {
      history = Array(history.suffix(1000))
    }
    let data = try JSONEncoder().encode(history)
    try data.write(to: historyFile, options: .atomic)
    cachedHistory = history
    cachedStamp = historyStamp()
  }

  private func setAsideUnreadableHistory() {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let aside = root.appendingPathComponent("History.unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).json")
    try? fileManager.moveItem(at: historyFile, to: aside)
    cachedHistory = nil
    cachedStamp = nil
  }

  func loadHistory() throws -> [ProcessingHistory] {
    let stamp = historyStamp()
    if let cachedHistory, stamp == cachedStamp { return cachedHistory }
    guard fileManager.fileExists(atPath: historyFile.path) else {
      cachedHistory = []
      cachedStamp = nil
      return []
    }
    let data = try Data(contentsOf: historyFile)
    let history = try JSONDecoder().decode([ProcessingHistory].self, from: data)
    cachedHistory = history
    cachedStamp = stamp
    return history
  }

  /// The file's modification time: one stat per append instead of a read.
  private func historyStamp() -> Date? {
    (try? fileManager.attributesOfItem(atPath: historyFile.path))?[.modificationDate] as? Date
  }

  func clearHistory() async throws {
    if fileManager.fileExists(atPath: historyFile.path) {
      try fileManager.removeItem(at: historyFile)
    }
    cachedHistory = []
    cachedStamp = nil
  }
}

// URL and UTType already conform to Codable via Foundation
