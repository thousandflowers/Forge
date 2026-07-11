import SwiftUI
import UniformTypeIdentifiers

/// Single source of truth for the app: presets, monitored folders, history,
/// settings, and the processing coordinator. Injected via `.environmentObject`.
@MainActor
final class AppModel: ObservableObject {
  @Published var presets: [RulePreset] = []
  @Published var folders: [MonitoredFolder] = []
  @Published var history: [ProcessingHistory] = []
  @Published var settings: AppSettings

  let coordinator: ProcessingCoordinator
  private let persistence = PersistenceManager.shared
  private var watchers: [UUID: MonitoredFolderWatcher] = [:]

  init() {
    let loaded = AppSettings.load()
    self.settings = loaded
    self.coordinator = ProcessingCoordinator(registry: ProcessorRegistry(), settings: loaded)
  }

  /// Load persisted state on launch; seed default presets on first run.
  func bootstrap() async {
    let loadedPresets = (try? await persistence.loadAllPresets()) ?? []
    if loadedPresets.isEmpty {
      presets = Self.defaultPresets
      for preset in presets { try? await persistence.savePreset(preset) }
    } else {
      presets = loadedPresets.sorted { $0.name < $1.name }
    }
    folders = (try? await persistence.loadMonitoredFolders()) ?? []
    await refreshHistory()
    for folder in folders where folder.isActive { startWatcher(folder) }
  }

  // MARK: - Presets

  func savePreset(_ preset: RulePreset) {
    if let i = presets.firstIndex(where: { $0.id == preset.id }) {
      presets[i] = preset
    } else {
      presets.append(preset)
    }
    presets.sort { $0.name < $1.name }
    Task { try? await persistence.savePreset(preset) }
  }

  func deletePreset(_ preset: RulePreset) {
    presets.removeAll { $0.id == preset.id }
    Task { try? await persistence.deletePreset(id: preset.id) }
  }

  func duplicatePreset(_ preset: RulePreset) {
    let copy = RulePreset(
      name: "\(preset.name) copy",
      description: preset.description,
      targetFormat: preset.targetFormat,
      resize: preset.resize,
      quality: preset.quality,
      targetSize: preset.targetSize,
      filters: preset.filters,
      icon: preset.icon,
      category: preset.category,
      applicableFileTypes: preset.applicableFileTypes
    )
    savePreset(copy)
  }

  // MARK: - Folders

  func addFolder(url: URL, presetID: UUID, mode: DestinationMode, destination: URL?) {
    let folder = MonitoredFolder(url: url, ruleId: presetID, destinationMode: mode, destinationURL: destination, isActive: true)
    folders.append(folder)
    persistFolders()
    startWatcher(folder)
  }

  func toggleFolder(_ folder: MonitoredFolder, active: Bool) {
    guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
    folders[i].isActive = active
    persistFolders()
    if active { startWatcher(folders[i]) } else { stopWatcher(folders[i]) }
  }

  func deleteFolders(at offsets: IndexSet) {
    for index in offsets { stopWatcher(folders[index]) }
    folders.remove(atOffsets: offsets)
    persistFolders()
  }

  func presetName(for id: UUID) -> String {
    presets.first { $0.id == id }?.name ?? "Unknown preset"
  }

  private func persistFolders() {
    let snapshot = folders
    Task { try? await persistence.saveMonitoredFolders(snapshot) }
  }

  // MARK: - History

  func refreshHistory() async {
    let loaded = (try? await persistence.loadHistory()) ?? []
    history = loaded.sorted { $0.timestamp > $1.timestamp }
  }

  func clearHistory() {
    history.removeAll()
    Task { try? await persistence.clearHistory() }
  }

  // MARK: - Settings

  func saveSettings() {
    try? settings.save()
  }

  // MARK: - Watchers

  private func startWatcher(_ folder: MonitoredFolder) {
    guard watchers[folder.id] == nil else { return }
    let watcher = MonitoredFolderWatcher()
    do {
      try watcher.startWatching(folder: folder) { [weak self] url in
        await self?.processIncoming(url, folder: folder)
      }
      watchers[folder.id] = watcher
    } catch {
      // Watching is best-effort; folder config is still saved.
    }
  }

  private func stopWatcher(_ folder: MonitoredFolder) {
    watchers[folder.id]?.stopWatching(folder: folder)
    watchers[folder.id] = nil
  }

  private func processIncoming(_ url: URL, folder: MonitoredFolder) async {
    guard let preset = presets.first(where: { $0.id == folder.ruleId }),
          let file = try? ProcessableFile(url: url) else { return }
    _ = try? await coordinator.processFile(
      file, with: preset,
      destinationMode: folder.destinationMode,
      destinationURL: folder.destinationURL
    ) { _ in }
    await refreshHistory()
  }

  // MARK: - Default presets (first run)

  static var defaultPresets: [RulePreset] {
    [
      RulePreset(name: "Web JPEG", description: "Optimized JPEG for the web (quality 80).",
                 targetFormat: .jpeg, quality: 80, category: .image),
      RulePreset(name: "Instagram Square", description: "1080×1080 JPEG, center-cropped.",
                 targetFormat: .jpeg, resize: ResizeSpec(width: 1080, height: 1080, fitMode: .cropCenter),
                 quality: 85, category: .image),
      RulePreset(name: "PNG → JPEG", description: "Convert PNG images to compact JPEG.",
                 targetFormat: .jpeg, quality: 75, category: .image),
      RulePreset(name: "Video 720p (MP4)", description: "Re-encode video to 1280×720 H.264.",
                 targetFormat: .mpeg4Movie, resize: ResizeSpec(width: 1280, height: 720, fitMode: .proportional),
                 category: .video),
      RulePreset(name: "Audio → MP3", description: "Convert audio tracks to MP3.",
                 targetFormat: .mp3, category: .audio),
      RulePreset(name: "PDF → JPEG", description: "Export PDF pages as JPEG images.",
                 targetFormat: .jpeg, category: .document),
    ]
  }
}
