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
  private let persistence: PersistenceManager
  private var watchers: [UUID: MonitoredFolderWatcher] = [:]

  /// Files Forge has just written. A watched folder that also receives the
  /// output would otherwise convert its own results forever.
  private var produced: Set<String> = []
  private static let producedLimit = 512

  /// - Parameter persistence: where presets, folders and history live. Tests
  ///   pass a scratch store; anything else writing to the real one is a bug
  ///   that shows up as junk presets in somebody's app.
  init(persistence: PersistenceManager = .shared) {
    let loaded = AppSettings.load()
    self.settings = loaded
    self.persistence = persistence
    self.coordinator = ProcessingCoordinator(settings: loaded, persistence: persistence)
  }

  /// Load persisted state on launch; seed default presets on first run.
  func bootstrap() async {
    do {
      let loadedPresets = try await persistence.loadAllPresets()
      if loadedPresets.isEmpty {
        presets = Self.defaultPresets.enumerated().map { index, preset in
          var seeded = preset
          seeded.position = index
          return seeded
        }
        for preset in presets { try await persistence.savePreset(preset) }
      } else {
        presets = Self.ordered(loadedPresets)
      }
      folders = try await persistence.loadMonitoredFolders()
    } catch {
      report(error, doing: "loading your presets and folders")
    }

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
    presets = Self.ordered(presets)
    persist({ try await $0.savePreset(preset) }, doing: "saving “\(preset.name)”")
  }

  /// Add a preset from the gallery, under a new identity so installing the
  /// same one twice gives two, not a silent replacement of yours.
  func install(_ preset: RulePreset) {
    var copy = preset
    copy.id = UUID()
    copy.position = (presets.map(\.position).max() ?? 0) + 1
    savePreset(copy)
  }

  /// Turn a preset off without losing it.
  func setPreset(_ preset: RulePreset, enabled: Bool) {
    guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
    presets[index].isEnabled = enabled
    let updated = presets[index]
    persist({ try await $0.savePreset(updated) }, doing: "saving “\(preset.name)”")
  }

  /// The presets on offer anywhere a conversion is started.
  var usablePresets: [RulePreset] {
    presets.filter(\.isEnabled)
  }

  /// Move a preset one place, and write the new order down.
  func movePreset(_ preset: RulePreset, by offset: Int) {
    guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
    let target = index + offset
    guard presets.indices.contains(target) else { return }

    presets.swapAt(index, target)
    for (position, var preset) in presets.enumerated() {
      preset.position = position
      presets[position] = preset
      persist({ [preset] in try await $0.savePreset(preset) }, doing: "reordering your presets")
    }
  }

  /// By position, then by name for the ones that share one - which is every
  /// preset until somebody moves something.
  nonisolated static func ordered(_ presets: [RulePreset]) -> [RulePreset] {
    presets.sorted {
      $0.position == $1.position ? $0.name < $1.name : $0.position < $1.position
    }
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
        category: preset.category
      )
    )
  }

  /// Write presets to a file, so one of them — or the lot — can be kept or
  /// handed on. Sharing belongs to a preset rather than to the screen it sits
  /// on, so this takes whichever ones were asked for.
  func export(_ chosen: [RulePreset], to url: URL) {
    let doing = chosen.count == 1
      ? "exporting “\(chosen[0].name)”"
      : "exporting your presets"
    persist({ try await $0.export(chosen, to: url) }, doing: doing)
  }

  /// Read presets from a file, giving each a new identity so an import adds
  /// rather than silently replacing what is already there.
  func importPresets(from url: URL) {
    Task { [weak self] in
      do {
        let imported = try await self?.persistence.importPresets(from: url) ?? []
        guard let self else { return }
        for preset in imported {
          var copy = preset
          copy.id = UUID()
          self.savePreset(copy)
        }
      } catch {
        self?.report(error, doing: "importing presets")
      }
    }
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

  /// Whether a preset targets something this machine cannot write - an
  /// "Audio to MP3" preset saved by an older version, for one, since
  /// AVFoundation has no MP3 encoder.
  func canDeliver(_ preset: RulePreset) -> Bool {
    guard let format = preset.targetFormat else { return true }
    return FormatCatalog.isWritableImage(format)
      || FormatCatalog.audioFormatID(for: format) != nil
      || FormatCatalog.isWritableVideo(format)
      || FormatCatalog.isWritableModel(format)
      || DocumentText.canWrite(format)
  }

  func presetName(for id: UUID) -> String {
    presets.first { $0.id == id }?.name ?? "Unknown preset"
  }

  private func persistFolders() {
    let snapshot = folders
    persist({ try await $0.saveMonitoredFolders(snapshot) }, doing: "saving your monitored folders")
  }

  /// Run a conversion started from the menu bar, where there is no progress to
  /// show, so the notification is the whole report.
  func convertFromMenuBar(_ urls: [URL], with preset: RulePreset, into folder: URL) {
    let files = urls.compactMap { try? ProcessableFile(url: $0) }
    guard !files.isEmpty else {
      lastError = "None of those files is one Forge can open."
      return
    }

    Task { [weak self] in
      guard let self else { return }
      let limit = await self.coordinator.maxConcurrentNative
      let report = await Batch.run(
        files,
        preset: preset,
        mode: .copyTo,
        destination: folder,
        limit: limit,
        coordinator: self.coordinator
      ) { event in
        guard case .finished(_, _, let output, _) = event, let output else { return }
        Task { @MainActor in self.remember(output) }
      }

      await self.refreshHistory()
      if self.settings.notifyWhenFinished {
        await Notifier.batchFinished(converted: report.converted, failed: report.failed)
      }
    }
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

  func report(_ error: Error, doing action: String) {
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
