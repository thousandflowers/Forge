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

  /// The last thing that went wrong, for the UI to show. Saving a preset or
  /// starting a watcher used to fail in silence, leaving the screen claiming
  /// everything had worked.
  @Published var lastError: String?

  let coordinator: ProcessingCoordinator
  private let persistence = PersistenceManager.shared
  private var watchers: [UUID: MonitoredFolderWatcher] = [:]

  /// Files Forge has just written. A watched folder that also receives the
  /// output would otherwise convert its own results forever.
  private var produced: Set<String> = []
  private static let producedLimit = 512

  init() {
    let loaded = AppSettings.load()
    self.settings = loaded
    self.coordinator = ProcessingCoordinator(settings: loaded)
  }

  /// Load persisted state on launch; seed default presets on first run.
  func bootstrap() async {
    do {
      let loadedPresets = try await persistence.loadAllPresets()
      if loadedPresets.isEmpty {
        presets = Self.defaultPresets
        for preset in presets { try await persistence.savePreset(preset) }
      } else {
        presets = loadedPresets.sorted { $0.name < $1.name }
      }
      folders = try await persistence.loadMonitoredFolders()
    } catch {
      report(error, doing: "loading your presets and folders")
    }

    warnAboutUnwritablePresets()

    await refreshHistory()
    for folder in folders where folder.isActive { startWatcher(folder) }
  }

  // MARK: - Presets

  func savePreset(_ preset: RulePreset) {
    if let index = presets.firstIndex(where: { $0.id == preset.id }) {
      presets[index] = preset
    } else {
      presets.append(preset)
    }
    presets.sort { $0.name < $1.name }
    persist({ try await $0.savePreset(preset) }, doing: "saving “\(preset.name)”")
  }

  func deletePreset(_ preset: RulePreset) {
    presets.removeAll { $0.id == preset.id }
    persist({ try await $0.deletePreset(id: preset.id) }, doing: "deleting “\(preset.name)”")
  }

  func duplicatePreset(_ preset: RulePreset) {
    savePreset(
      RulePreset(
        name: "\(preset.name) copy",
        description: preset.description,
        targetFormat: preset.targetFormat,
        resize: preset.resize,
        quality: preset.quality,
        filters: preset.filters,
        category: preset.category,
      )
    )
  }

  // MARK: - Folders

  func addFolder(url: URL, presetID: UUID, mode: DestinationMode, destination: URL?, includeSubfolders: Bool) {
    let folder = MonitoredFolder(
      url: url,
      ruleId: presetID,
      destinationMode: mode,
      destinationURL: destination,
      isActive: true,
      includeSubfolders: includeSubfolders
    )
    folders.append(folder)
    persistFolders()
    startWatcher(folder)
  }

  func toggleFolder(_ folder: MonitoredFolder, active: Bool) {
    guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
    folders[index].isActive = active
    persistFolders()
    if active { startWatcher(folders[index]) } else { stopWatcher(folders[index]) }
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
    persist({ try await $0.saveMonitoredFolders(snapshot) }, doing: "saving your monitored folders")
  }

  // MARK: - History

  func refreshHistory() async {
    do {
      history = try await persistence.loadHistory().sorted { $0.timestamp > $1.timestamp }
    } catch {
      report(error, doing: "loading history")
    }
  }

  func clearHistory() {
    history.removeAll()
    persist({ try await $0.clearHistory() }, doing: "clearing history")
  }

  // MARK: - Settings

  func saveSettings() {
    do {
      try settings.save()
    } catch {
      report(error, doing: "saving settings")
    }
    // The coordinator holds its own copy, so it has to be told.
    let snapshot = settings
    Task { await coordinator.update(settings: snapshot) }
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
      // A folder that shows as active but is not being watched is worse than
      // an error message, so say so and turn it back off.
      report(error, doing: "watching “\(folder.displayName)”")
      if let index = folders.firstIndex(where: { $0.id == folder.id }) {
        folders[index].isActive = false
      }
    }
  }

  private func stopWatcher(_ folder: MonitoredFolder) {
    watchers[folder.id]?.stop()
    watchers[folder.id] = nil
  }

  private func processIncoming(_ url: URL, folder: MonitoredFolder) async {
    guard !produced.contains(url.standardizedFileURL.path) else { return }
    guard let preset = presets.first(where: { $0.id == folder.ruleId }) else { return }

    let file: ProcessableFile
    do {
      file = try ProcessableFile(url: url)
    } catch {
      return // not something Forge converts; nothing to report
    }

    do {
      let entry = try await coordinator.processFile(
        file,
        with: preset,
        destinationMode: folder.destinationMode,
        destinationURL: folder.destinationURL
      ) { _ in }
      if let output = entry.outputURL { remember(output) }
    } catch is CancellationError {
      // nothing to say
    } catch ProcessingError.unreadableFormat, ProcessingError.unsupportedConversion, ProcessingError.unknownType {
      // A watched folder receives whatever is dropped in it. Files the preset
      // cannot convert are recorded in history; interrupting the user for each
      // one is not useful.
    } catch {
      report(error, doing: "converting “\(url.lastPathComponent)”")
    }

    await refreshHistory()
  }

  /// Remember a file Forge wrote, keeping the set from growing without bound.
  func remember(_ url: URL) {
    if produced.count >= Self.producedLimit { produced.removeAll() }
    produced.insert(url.standardizedFileURL.path)
  }

  /// Presets saved by an older version can target a format this machine cannot
  /// write - an "Audio to MP3" preset, for one, since AVFoundation has no MP3
  /// encoder. Saying so once beats letting every conversion fail.
  private func warnAboutUnwritablePresets() {
    let broken = presets.filter { preset in
      guard let format = preset.targetFormat else { return false }
      return !FormatCatalog.isWritableImage(format)
        && FormatCatalog.audioFormatID(for: format) == nil
        && !FormatCatalog.isWritableVideo(format)
    }
    // Never speak over a real failure: this is advice, not an error.
    guard !broken.isEmpty, lastError == nil else { return }

    let names = broken.map { "“\($0.name)”" }.joined(separator: ", ")
    lastError = broken.count == 1
      ? "The preset \(names) targets a format macOS cannot write. Edit or delete it in Presets."
      : "These presets target formats macOS cannot write: \(names). Edit or delete them in Presets."
  }

  // MARK: - Errors

  private func persist(
    _ work: @escaping (PersistenceManager) async throws -> Void,
    doing action: String
  ) {
    let persistence = self.persistence
    Task { [weak self] in
      do {
        try await work(persistence)
      } catch {
        self?.report(error, doing: action)
      }
    }
  }

  private func report(_ error: Error, doing action: String) {
    lastError = "Something went wrong \(action): \(error.localizedDescription)"
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
      // AAC in an M4A container, not MP3: AVFoundation has no MP3 encoder, and
      // the old preset produced AAC in a file named `.mp3`.
      RulePreset(name: "Audio → M4A", description: "Convert audio tracks to AAC in an M4A container.",
                 targetFormat: UTType("com.apple.m4a-audio") ?? .mpeg4Audio, category: .audio),
      RulePreset(name: "PDF → JPEG", description: "Export every PDF page as a JPEG image.",
                 targetFormat: .jpeg, category: .document),
    ]
  }
}
