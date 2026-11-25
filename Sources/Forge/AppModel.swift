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

  /// The questions files ask by their names, one at a time.
  let asks = AskCenter()
  /// What was done without being asked.
  let results = ResultCenter()
  private lazy var clipboard = ClipboardLighter(coordinator: coordinator)
  private let dragMenu = DragMenu()
  private let cuts = CutCenter()
  let dropZone = DropZone()
  let running = Running()
  let signs = WorkSigns()
  private lazy var notchSign = NotchSign(signs)
  private let notchZone = NotchZone()
  private var inHand: Set<String> = []
  private var watchedPlaces: [Automatic.Place: URL] = [:]
  private var automatic: [Automatic.Place: MonitoredFolderWatcher] = [:]

  /// Brings the window back, once there has been one.
  var showWindow: (() -> Void)?

  /// The last thing that went wrong, for the UI to show. Saving a preset or
  /// starting a watcher used to fail in silence, leaving the screen claiming
  /// everything had worked.
  @Published var lastError: String?

  /// Files put on the Convert screen by something other than a drop - a row in
  /// history asking to be run again. Cleared as soon as that screen takes them.
  @Published var pending: PendingConversion?
  /// Files opened from outside the window - the Dock icon, Open With. They are
  /// a drop that happened somewhere else, and the Convert screen takes them as
  /// one, adding to what is already there.
  @Published var opened: [URL] = []
  /// The sidebar section on screen; the View menu's ⌘1…⌘7 set it.
  @Published var section: AppSection? = .process
  /// The preset being written, when the editor is up. It covers the whole
  /// window, so the window owns it rather than the Presets screen.
  @Published var presetEditor: PresetEditorRequest?

  let coordinator: ProcessingCoordinator
  private let persistence: PersistenceManager
  private var watchers: [UUID: MonitoredFolderWatcher] = [:]
  private var memories: [UUID: RenameMemory] = [:]
  private let turns = Turns()
  private let handRenames = HandRenames()
  /// What was put back, and from what: done again, it is meant.
  private var putBack: [UInt64: String] = [:]

  /// Files Forge has just written. A watched folder that also receives the
  /// output would otherwise convert its own results forever.
  private var produced: Set<String> = []
  /// The same paths in the order they were written, so the oldest can go first.
  private var producedOrder: [String] = []
  private static let producedLimit = 512

  /// - Parameter persistence: where presets, folders and history live. Tests
  ///   pass a scratch store; anything else writing to the real one is a bug
  ///   that shows up as junk presets in somebody's app.
  init(persistence: PersistenceManager = .shared) {
    let loaded = AppSettings.load()
    self.settings = loaded
    self.persistence = persistence
    let coordinator = ProcessingCoordinator(settings: loaded, persistence: persistence)
    self.coordinator = coordinator
    asks.preview = { file, preset, folder in try await coordinator.preview(file, with: preset, into: folder) }
    dragMenu.preview = asks.preview
    asks.cut = { [weak self] file in self?.cut(file) }
    running.ended = { [weak self] in Task { await self?.refreshHistory() } }
    running.heard = { [weak self] in self?.signs.hear($0) }
    let running = running
    Task { await running.listen(to: coordinator) }
  }

  /// Load persisted state on launch; seed default presets on first run.
  func bootstrap() async {
    Claims.sweep(root: persistence.root)
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
    startAutomatic()
    startDragMenu()
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

    // A folder watching with this preset would have gone on looking active and
    // done nothing at all with what landed in it, which is the worst of both.
    let orphaned = folders.filter { $0.ruleId == preset.id && $0.isActive }
    guard !orphaned.isEmpty else { return }

    for folder in orphaned {
      stopWatcher(folder)
      if let index = folders.firstIndex(where: { $0.id == folder.id }) {
        folders[index].isActive = false
      }
    }
    persistFolders()
    lastError = orphaned.count == 1
      ? "“\(orphaned[0].displayName)” was watching with “\(preset.name)”, so it has been switched off."
      : "\(orphaned.count) watched folders were using “\(preset.name)”, so they have been switched off."
  }

  func duplicatePreset(_ preset: RulePreset) {
    savePreset(preset.duplicate())
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
        let imported = (try await self?.persistence.importPresets(from: url) ?? []).map(\.withoutFilesOfItsOwn)
        guard let self else { return }
        // The same file imported twice used to leave two identical presets.
        for preset in imported where !Self.isAlreadyHere(preset, in: self.presets) {
          var copy = preset
          copy.id = UUID()
          self.savePreset(copy)
        }
      } catch {
        self?.report(error, doing: "importing presets")
      }
    }
  }

  /// A preset with this name that already does exactly the same.
  nonisolated static func isAlreadyHere(_ preset: RulePreset, in presets: [RulePreset]) -> Bool {
    presets.contains { $0.name == preset.name && $0.actions == preset.actions }
  }

  // MARK: - Folders

  func addFolder(
    url: URL, presetID: UUID, mode: DestinationMode, destination: URL?,
    includeSubfolders: Bool, onlyWhenRenamed: Bool = false
  ) {
    // Two watchers on one folder convert everything twice, and the second copy
    // arrives named "photo 2.jpeg" with nothing to say where it came from.
    let path = url.standardizedFileURL.path
    if folders.contains(where: { $0.url.standardizedFileURL.path == path }) {
      lastError = "“\(url.lastPathComponent)” is already being watched."
      return
    }
    if let covering = folders.first(where: {
      $0.includeSubfolders && path.hasPrefix($0.url.standardizedFileURL.path + "/")
    }) {
      lastError = "“\(url.lastPathComponent)” is already inside “\(covering.displayName)”, "
        + "which watches its subfolders - everything in it would be converted twice."
      return
    }

    let folder = MonitoredFolder(
      url: url,
      ruleId: presetID,
      destinationMode: mode,
      destinationURL: destination,
      isActive: true,
      includeSubfolders: includeSubfolders,
      onlyWhenRenamed: onlyWhenRenamed
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

  /// The Desktop and the downloads, for the names that say what they want and
  /// for nothing else.
  func watchForNames() {
    for place in [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory] {
      guard let url = FileManager.default.urls(for: place, in: .userDomainMask).first,
            !folders.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else { continue }
      addFolder(
        url: url, presetID: Self.noPreset, mode: Automatic.mode(for: settings),
        destination: settings.createBackupBeforeOverwrite ? nil : url, includeSubfolders: false, onlyWhenRenamed: true
      )
    }
  }

  var watchesForNames: Bool {
    [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory].allSatisfy { place in
      guard let url = FileManager.default.urls(for: place, in: .userDomainMask).first else { return true }
      return folders.contains { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
    }
  }

  /// A folder that does what names say and nothing of its own.
  nonisolated static let noPreset = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

  func setOnlyWhenRenamed(_ folder: MonitoredFolder, _ on: Bool) {
    guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
    folders[index].onlyWhenRenamed = on
    persistFolders()
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
      // A tool the user installed writes it - the default Audio to MP3 preset
      // goes to ffmpeg, and warning that this Mac cannot write MP3 was false.
      || ExternalBridge.canWrite(format)
  }

  func presetName(for id: UUID) -> String {
    if id == Self.noPreset { return "What the name says" }
    return presets.first { $0.id == id }?.name ?? "Unknown preset"
  }

  // MARK: - Trying it out

  private static let lessonID = UUID(uuidString: "00000000-0000-0000-0000-00000000F0F0")!

  /// Where the folder to try things in is made. Nothing has to be allowed there.
  var lessonRoot: URL { persistence.root }

  /// Watched for as long as it lasts, and forgotten with it.
  func startLesson(in url: URL) {
    endLesson()
    var folder = MonitoredFolder(url: url, ruleId: Self.noPreset, destinationMode: Automatic.mode(for: settings), destinationURL: settings.createBackupBeforeOverwrite ? nil : url)
    folder.id = Self.lessonID
    folder.onlyWhenRenamed = true
    folders.append(folder)
    startWatcher(folder)
  }

  func endLesson() {
    guard let folder = folders.first(where: { $0.id == Self.lessonID }) else { return }
    stopWatcher(folder)
    folders.removeAll { $0.id == Self.lessonID }
  }

  private func persistFolders() {
    let snapshot = folders.filter { $0.id != Self.lessonID }
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
    // Some of them, rather than none, used to disappear without a word.
    if files.count < urls.count {
      // Compared the way ProcessableFile stores its URL: absolute and
      // standardised, or a relative path that opened fine is listed as missed.
      let opened = Set(files.map(\.url))
      let missed = urls.filter { !opened.contains($0.absoluteURL.standardizedFileURL) }
      lastError = BatchViewModel.describe(missed)
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
        guard case .finished(_, let status, _, let outputs, let reason) = event else { return }
        Task { @MainActor in
          outputs.forEach(self.remember)
          // A conversion started from the menu bar that fails has no row to
          // turn red. It said nothing unless notifications were on.
          if status == .failed, let reason { self.lastError = reason }
        }
      }

      await self.refreshHistory()
      if self.settings.notifyWhenFinished {
        await Notifier.batchFinished(converted: report.converted, failed: report.failed)
      }
    }
  }

  // MARK: - Running something from history

  /// Keep a one-off conversion as a preset.
  ///
  /// Saved through the ordinary path, so what comes out is a preset like any
  /// other: editable, exportable, and eventually publishable to the Gallery.
  func savePreset(from entry: ProcessingHistory) {
    guard var preset = entry.savedPreset else {
      lastError = "That run was recorded before Forge kept the steps, so there is nothing to save."
      return
    }
    preset.position = (presets.map(\.position).max() ?? 0) + 1
    // A run that was not a saved preset - the command line, a batch set up by
    // hand - has no name worth keeping: "command line (from history)". It is
    // named for what it does: "PNG → JPEG, 400 × 300, Q70".
    if !presets.contains(where: { $0.id == entry.ruleId }) {
      preset.name = ProcessingHistory.describedName(for: entry.fileURL, actions: preset.actions)
    }
    savePreset(preset)
    // And shown: nothing on the History screen changed, so there was no way
    // to tell it had been saved.
    section = .presets
  }

  func open(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    opened += urls
    // A file handed over with the window closed has nowhere to be seen.
    let isShown = NSApp?.windows.contains { $0.isVisible && $0.identifier?.rawValue == MenuBarView.windowID } ?? true
    if !isShown { showWindow?() }
  }

  /// Run the same chain on the same files.
  ///
  /// The originals may have moved, been renamed or been converted in place
  /// since. What is still there is run; what is gone is named rather than
  /// skipped in silence.
  func rerun(_ entry: ProcessingHistory) {
    guard let preset = entry.rerunPreset else {
      lastError = "That run was recorded before Forge kept the steps, so it cannot be repeated."
      return
    }

    let sources = Self.split([entry.fileURL])
    if let missing = Self.describeMissing(sources.missing) { lastError = missing }
    guard !sources.here.isEmpty else { return }

    // A conversion with no folder recorded replaced its original, so repeating
    // it means replacing again - which the Convert screen asks about. Where a
    // folder was recorded the copy is repeated, never the move: removing an
    // original a second time is not something to infer from a row.
    pending = PendingConversion(
      files: sources.here,
      preset: preset,
      destination: entry.destinationFolder,
      mode: entry.destinationFolder == nil ? .overwrite : .copyTo
    )
  }

  /// Run the same chain on files chosen now. Nothing stale can be in it, so
  /// there is nothing to check.
  func reapply(_ entry: ProcessingHistory, to urls: [URL]) {
    guard let preset = entry.rerunPreset else {
      lastError = "That run was recorded before Forge kept the steps, so it cannot be repeated."
      return
    }
    guard !urls.isEmpty else { return }
    pending = PendingConversion(
      files: urls,
      preset: preset,
      destination: entry.destinationFolder,
      mode: .copyTo
    )
  }

  /// Which of these files are still where they were.
  nonisolated static func split(_ urls: [URL]) -> (here: [URL], missing: [URL]) {
    var here: [URL] = []
    var missing: [URL] = []
    for url in urls {
      if FileManager.default.fileExists(atPath: url.path) { here.append(url) } else { missing.append(url) }
    }
    return (here, missing)
  }

  /// The ones that are gone, named. "Some files were skipped" is not something
  /// anybody can act on.
  nonisolated static func describeMissing(_ urls: [URL]) -> String? {
    guard !urls.isEmpty else { return nil }
    if urls.count == 1 {
      return "\(urls[0].lastPathComponent) is not where it was, so it was left out."
    }
    let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
    let rest = urls.count > 3 ? " and \(urls.count - 3) more" : ""
    return "\(names)\(rest) are not where they were, so they were left out."
  }

  // MARK: - History

  /// Put a past conversion back the way it was before it.
  @discardableResult
  func undo(_ entry: ProcessingHistory, discard: (URL) throws -> Void = Undo.trash) -> Bool {
    // Before it lands: to a watched folder an original put back is a file
    // arriving, whose name still asks for what was just undone.
    remember(entry.fileURL)
    do {
      if let restored = try Undo.run(entry, discard: discard) { remember(restored) }
    } catch {
      report(error, doing: "undoing “\(entry.fileURL.lastPathComponent)”")
      return false
    }
    Task { [weak self] in
      do { try await self?.persistence.markUndone(entry.id) } catch { self?.report(error, doing: "updating history") }
      await self?.refreshHistory()
    }
    return true
  }

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
    startAutomatic()
    startDragMenu()
  }

  // MARK: - In hand

  private func startDragMenu() {
    dragMenu.suggest = { [weak self] in self?.suggestions(for: $0) ?? [] }
    asks.suggest = dragMenu.suggest
    ResultHand.more = { [weak self] in self?.dragMenu.present($0) }
    dropZone.take = { [weak self] in self?.dragMenu.present($0) }
    notchZone.take = { [weak self] in self?.dragMenu.present($0, outOf: self?.notchZone.here()) }
    dragMenu.notch = settings.notchZone ? notchZone : nil
    dragMenu.answersKeys = settings.dragMenu
    dragMenu.keys = settings.dragMenuKeys
    dragMenu.ignored = Set(settings.dragMenuIgnored)
    dragMenu.convert = { [weak self] file, preset in try await self?.convertInHand(file, with: preset) ?? [] }
    dragMenu.cut = { [weak self] file in self?.cut(file) }
    dragMenu.join = { [weak self] files, kind in
      guard let self else { throw CancellationError() }
      let made = try await self.coordinator.join(files, as: kind)
      self.remember(made)
      Task { await self.refreshHistory() }
      return made
    }
    signs.place = settings.workSign
    notchSign.follow()
    settings.dragMenu || settings.notchZone ? dragMenu.start() : dragMenu.stop()
  }

  func suggestions(for files: [ProcessableFile]) -> [RulePreset] {
    Suggestions.presets(for: files, from: presets, chosen: settings.menuPresets, history: history)
  }

  /// Open a window to cut this file in.
  func cut(_ file: ProcessableFile) {
    cuts.open(file) { [weak self] file, preset in try await self?.convertInHand(file, with: preset) ?? [] }
  }

  /// From the Finder's menu: as many windows as there are files to cut.
  func cut(_ urls: [URL]) {
    let files = urls.compactMap { try? ProcessableFile(url: $0) }.filter { CutModel(file: $0) != nil }
    if files.isEmpty { lastError = "Forge cannot cut any of these files." }
    files.prefix(Self.mostWindows).forEach(cut)
  }

  private static let mostWindows = 8

  /// Beside the original, which stays.
  private func convertInHand(_ file: ProcessableFile, with preset: RulePreset) async throws -> [URL] {
    defer { Task { await refreshHistory() } }
    let progress = AskSession.progress
    let entry = try await coordinator.processFile(
      file, with: preset, destinationMode: .copyTo, destinationURL: file.url.deletingLastPathComponent()
    ) { progress?($0) }
    entry.outputs.forEach(remember)
    return entry.outputs
  }

  // MARK: - Without being asked

  /// Start what is allowed and stop what is not.
  func startAutomatic() {
    if settings.lighterClipboard {
      clipboard.start { [weak self] made in
        self?.results.show(ResultCard(
          title: "Copied picture", file: made.file, before: made.before, after: made.after,
          undo: { self?.clipboard.undo(made) ?? false },
          gone: { self?.clipboard.discard(made) }
        ))
      }
    } else {
      clipboard.stop()
    }

    if settings.convertsRenames {
      handRenames.start { [weak self] url, before in Task { await self?.renamedByHand(url, before: before) } }
    } else {
      handRenames.stop()
    }

    for place in Automatic.Place.allCases {
      guard place.isWanted(settings) else {
        automatic.removeValue(forKey: place)?.stop()
        continue
      }
      // Where captures go can be changed while Forge is open.
      if watchedPlaces[place] != place.folder { automatic.removeValue(forKey: place)?.stop() }
      guard automatic[place] == nil else { continue }
      watchedPlaces[place] = place.folder
      let watcher = MonitoredFolderWatcher()
      let folder = MonitoredFolder(url: place.folder, ruleId: UUID(), destinationMode: .copyTo)
      automatic[place] = watcher
      watcher.start(folder: folder, begun: { [weak self] error in
        guard let error else { return }
        Task { @MainActor in
          guard let self, self.automatic[place] === watcher else { return }
          self.automatic[place] = nil
          self.report(error, doing: "watching “\(folder.displayName)”")
        }
      }) { [weak self] url in await self?.takeAutomatically(url, in: place) }
    }
  }

  /// Given another extension in the Finder. In a watched folder that is the
  /// folder's to hear.
  func renamedByHand(_ url: URL, before: String) async {
    let isWatched = folders.contains { folder in
      guard folder.isActive else { return false }
      let parent = url.deletingLastPathComponent().standardizedFileURL.path, root = folder.url.standardizedFileURL.path
      return parent == root || folder.includeSubfolders && parent.hasPrefix(root + "/")
    }
    guard let meaning = await Task.detached(operation: { Retype.meant(by: url, before: before) }).value else { return }
    let job: Retype
    switch meaning {
    case .stay(let stay): return keep(url, as: stay)
    // Spelt right, it is the folder's; a slip the folder would not have known.
    case .become(let become) where isWatched && become.to.lowercased() == url.pathExtension.lowercased(): return
    case .become(let become): job = become
    }
    let before = Self.size(of: url)
    do {
      let entry = try await turns.take(of: settings.maxConcurrentNative) { [weak self] in try await self?.becomes(url, job) }
      await refreshHistory()
      guard let entry, let output = entry.outputURL else { return }
      results.show(ResultCard(title: output.lastPathComponent, file: output, before: before, after: Self.size(of: output), isSomethingElse: entry.isSomethingElse == true, undo: { [weak self] in
        self?.undo(entry) ?? false
      }))
    } catch is CancellationError {
      await refreshHistory()
    } catch {
      report(error, doing: "converting “\(url.lastPathComponent)”")
      await refreshHistory()
    }
  }

  private static func size(of file: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64) ?? 0
  }

  /// Nothing that name could mean: the file is given back the one that was true.
  /// Whoever insists is left to it.
  private func keep(_ url: URL, as job: Retype) {
    let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
    if let number, putBack[number] == job.to.lowercased() { return }
    do {
      let file = try job.putBack(url)
      if let number { putBack[number] = job.to.lowercased() }
      memories.values.forEach { $0.know(file) }
      remember(file)
      NSSound.beep()
      results.show(ResultCard(
        title: "Kept as \(file.lastPathComponent).", file: file, before: 0, after: 0, note: job.whyNot,
        undo: { (try? FileManager.default.moveItem(at: file, to: url)) != nil }
      ))
    } catch {
      report(error, doing: "converting “\(url.lastPathComponent)”")
    }
  }

  /// Where it is, as whoever renamed it there expects.
  private func becomes(_ url: URL, _ job: Retype, puttingBack: (URL) -> Void = { _ in }) async throws -> ProcessingHistory? {
    // Its turn may have been a while coming, and it may be called something else.
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let file = try job.putBack(url)
    puttingBack(file)
    remember(file)
    let snapshot = settings
    await coordinator.update(settings: snapshot)
    let entry = try await coordinator.processFile(
      try ProcessableFile(url: file), with: job.preset,
      destinationMode: Automatic.mode(for: snapshot), destinationURL: file.deletingLastPathComponent()
    ) { _ in }
    entry.outputs.forEach(remember)
    return entry
  }

  private func takeAutomatically(_ url: URL, in place: Automatic.Place) async {
    let path = url.standardizedFileURL.path
    guard inHand.insert(path).inserted else { return }
    defer { inHand.remove(path) }
    guard !wroteThis(url), !isSpokenFor(url), let file = try? ProcessableFile(url: url),
          let preset = await Automatic.preset(for: file, in: place, settings: settings) else { return }
    // The same answer about backups here and there, or an original could be
    // replaced by somebody who thinks it is kept.
    let snapshot = settings
    await coordinator.update(settings: snapshot)
    do {
      let entry = try await coordinator.processFile(
        file, with: preset, destinationMode: Automatic.mode(for: snapshot), destinationURL: url.deletingLastPathComponent()
      ) { _ in }
      entry.outputs.forEach(remember)
      await refreshHistory()
      guard let output = entry.outputURL else { return }
      let after = ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int64) ?? 0
      results.show(ResultCard(title: output.lastPathComponent, file: output, before: file.fileSize, after: after, isSomethingElse: entry.isSomethingElse == true, undo: { [weak self] in
        self?.undo(entry) ?? false
      }))
    } catch ProcessingError.leftAlone {
      await refreshHistory()
    } catch is CancellationError {
      await refreshHistory()
    } catch {
      report(error, doing: "converting “\(url.lastPathComponent)”")
      await refreshHistory()
    }
  }

  /// A folder somebody set up, or a word in the name, says what happens to it.
  private func isSpokenFor(_ url: URL) -> Bool {
    let parent = url.deletingLastPathComponent().standardizedFileURL.path
    return folders.contains { folder in
      let path = folder.url.standardizedFileURL.path
      guard folder.isActive, path == parent || (folder.includeSubfolders && parent.hasPrefix(path == "/" ? path : path + "/")) else { return false }
      return Arrival.of(
        url, folderPreset: presets.first { $0.id == folder.ruleId }, presets: presets, onlyWhenRenamed: folder.onlyWhenRenamed
      ) != .leave
    }
  }

  // MARK: - Watchers

  private func startWatcher(_ folder: MonitoredFolder) {
    guard watchers[folder.id] == nil else { return }
    let watcher = MonitoredFolderWatcher()
    let memory = RenameMemory()
    watchers[folder.id] = watcher
    memories[folder.id] = memory
    watcher.start(
      folder: folder,
      onGone: { [weak self] in Task { @MainActor in self?.stoppedWatching(folder) } },
      begun: { [weak self] error in
        guard let error else { return memory.remember(folder.url, subfolders: folder.includeSubfolders) }
        Task { @MainActor in
          guard let self, self.watchers[folder.id] === watcher else { return }
          self.couldNotWatch(folder, error)
        }
      }
    ) { [weak self] url in
      await self?.processIncoming(url, folder: folder)
    }
  }

  /// A folder that shows as active but is not being watched is worse than an
  /// error message, so say so and turn it back off.
  private func couldNotWatch(_ folder: MonitoredFolder, _ error: Error) {
    stopWatcher(folder)
    report(error, doing: "watching “\(folder.displayName)”")
    if let index = folders.firstIndex(where: { $0.id == folder.id }) {
      folders[index].isActive = false
    }
  }

  /// The folder was moved or deleted. It went on showing as watched, and
  /// nothing said that nothing would arrive in it again.
  private func stoppedWatching(_ folder: MonitoredFolder) {
    stopWatcher(folder)
    if let index = folders.firstIndex(where: { $0.id == folder.id }) {
      folders[index].isActive = false
    }
    lastError = "“\(folder.displayName)” was moved or deleted, so Forge has stopped watching it."
  }

  private func stopWatcher(_ folder: MonitoredFolder) {
    watchers[folder.id]?.stop()
    watchers[folder.id] = nil
    memories[folder.id] = nil
  }

  private func processIncoming(_ url: URL, folder: MonitoredFolder) async {
    // Known from now on even where Forge wrote it: it may be renamed next.
    let before = memories[folder.id]?.nameBefore(url)
    if let before, let job = await Task.detached(operation: { Retype.wanted(of: url, before: before) }).value {
      return await retype(url, job, in: folder)
    }
    let renamed = before != nil
    guard !wroteThis(url) else { return }
    // Asked of the folder as it is now: the watcher was handed a copy, and the
    // settings may have changed since.
    guard let folder = folders.first(where: { $0.id == folder.id }), folder.isActive else { return }
    let arrival = Arrival.of(
      url,
      folderPreset: presets.first { $0.id == folder.ruleId },
      presets: presets,
      onlyWhenRenamed: folder.onlyWhenRenamed,
      renamed: renamed
    )
    guard arrival != .leave, let file = try? ProcessableFile(url: url) else {
      return // nothing asked for, or not something Forge converts
    }

    let preset: RulePreset
    switch arrival {
    case .leave: return
    case .run(let chosen): preset = chosen
    case .ask(let request):
      asks.ask(request, from: folder.id, about: file) { [weak self] file, preset in
        // Where it goes is asked when it goes: the question may have been up
        // for minutes, and the folder switched off or pointed elsewhere since.
        guard let self, let now = self.folders.first(where: { $0.id == folder.id }), now.isActive else { return [] }
        var preset = preset
        preset.isAnswered = true
        return try await self.convertArrival(file, with: preset, in: now)
      }
      return
    }

    do {
      try await turns.take(of: settings.maxConcurrentNative) { [weak self] in _ = try await self?.convertArrival(file, with: preset, in: folder) }
    } catch is CancellationError {
      // nothing to say
    } catch ProcessingError.unreadableFormat, ProcessingError.unsupportedConversion, ProcessingError.unknownType,
            ProcessingError.leftAlone {
      // A watched folder receives whatever is dropped in it. Files the preset
      // cannot convert are recorded in history; interrupting the user for each
      // one is not useful.
    } catch {
      report(error, doing: "converting “\(url.lastPathComponent)”")
    }

    await refreshHistory()
  }

  /// Given another extension, and to become what it says: where it is, as
  /// whoever renamed it there expects.
  private func retype(_ url: URL, _ job: Retype, in folder: MonitoredFolder) async {
    do {
      try await turns.take(of: settings.maxConcurrentNative) { [weak self] in try await self?.retypeNow(url, job, in: folder) }
    } catch is CancellationError {
      // nothing to say
    } catch {
      report(error, doing: "converting “\(url.lastPathComponent)”")
    }
    await refreshHistory()
  }

  private func retypeNow(_ url: URL, _ job: Retype, in folder: MonitoredFolder) async throws {
    guard let folder = folders.first(where: { $0.id == folder.id }), folder.isActive else { return }
    let memory = memories[folder.id]
    try await becomes(url, job) { memory?.know($0) }?.outputs.forEach { memory?.know($0) }
  }

  private func convertArrival(_ file: ProcessableFile, with preset: RulePreset, in folder: MonitoredFolder) async throws -> [URL] {
    // The same answer about backups here and there, or an original could be
    // replaced by somebody who thinks it is kept.
    let snapshot = settings
    await coordinator.update(settings: snapshot)
    // A folder watched for names was never asked how: it does what is safe now.
    let isForNames = folder.ruleId == Self.noPreset
    let entry = try await coordinator.processFile(
      file,
      with: preset,
      destinationMode: isForNames ? Automatic.mode(for: snapshot) : folder.destinationMode,
      destinationURL: isForNames ? file.url.deletingLastPathComponent() : folder.destinationURL
    ) { [progress = AskSession.progress] in progress?($0) }
    // Every file it wrote, not only the first: the second one lands in the
    // same watched folder and would be converted again.
    entry.outputs.forEach(remember)
    Task { await refreshHistory() }
    return entry.outputs
  }

  /// Remember a file Forge wrote, keeping the set from growing without bound.
  ///
  /// The oldest are forgotten, not all of them: emptying the set meant a file
  /// written a moment earlier stopped being recognised as Forge's own, and a
  /// watched folder would convert it again.
  /// Whether this is a file Forge wrote, which is how a watched folder that
  /// also receives the output avoids converting its own results.
  func wroteThis(_ url: URL) -> Bool {
    produced.contains(url.standardizedFileURL.path)
  }

  func remember(_ url: URL) {
    let path = url.standardizedFileURL.path
    guard !produced.contains(path) else { return }

    if producedOrder.count >= Self.producedLimit {
      let forget = producedOrder.removeFirst()
      produced.remove(forget)
    }
    produced.insert(path)
    producedOrder.append(path)
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

  /// A conversion the Convert screen has been handed rather than dropped.
  struct PendingConversion: Equatable {
    let files: [URL]
    let preset: RulePreset
    let destination: URL?
    let mode: DestinationMode
    /// History's run-again replaces the list; files dropped on a preset join it.
    var replacesList = true
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
