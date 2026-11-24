import Foundation

/// Runs a watched folder in the foreground until interrupted.
///
/// The app does this with a window attached; here there is nowhere to show an
/// error, so every outcome is printed as it happens.
actor WatchRunner {
  private let preset: RulePreset
  private let mode: DestinationMode
  private let destination: URL?
  private let coordinator: ProcessingCoordinator

  /// Files this run has written, so a destination inside the watched folder
  /// does not feed itself.
  private var produced: Set<String> = []
  /// The other saved presets: a file renamed to carry one's trigger word asks
  /// for that preset, here as in the app.
  private let others: [RulePreset]
  private let onlyWhenRenamed: Bool
  private var running: [UUID: Task<Void, Never>] = [:]
  private var folderIsGone = false

  init(
    preset: RulePreset, mode: DestinationMode, destination: URL?, settings: AppSettings,
    others: [RulePreset] = [], onlyWhenRenamed: Bool = false
  ) {
    self.others = others
    self.onlyWhenRenamed = onlyWhenRenamed
    self.preset = preset
    self.mode = mode
    self.destination = destination
    self.coordinator = ProcessingCoordinator(settings: settings)
  }

  func run(folder: MonitoredFolder) async throws {
    let watcher = MonitoredFolderWatcher()
    memory.remember(folder.url, subfolders: folder.includeSubfolders)
    try watcher.startWatching(
      folder: folder,
      onGone: { [weak self] in Task { await self?.folderWentAway() } }
    ) { [weak self] url in
      await self?.handle(url)
    }
    defer { watcher.stop() }

    let target = folder.url.lastPathComponent
    FileHandle.standardError.write(Data("Watching \(target). Press Ctrl-C to stop.\n".utf8))

    // Nothing else drives this process, so hold it open until interrupted, or
    // until there is nothing left to watch.
    while !Task.isCancelled, !folderIsGone {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // Whatever is still converting is stopped and waited for, so that it
    // clears up after itself: leaving at once left the scratch files of a
    // long PDF behind, seventy-six of them in one measurement.
    let unfinished = Array(running.values)
    unfinished.forEach { $0.cancel() }
    for task in unfinished { await task.value }

    if folderIsGone {
      throw CLIError("\(target) was moved or deleted, so nothing more can arrive in it. Stopped.")
    }
  }

  private let memory = RenameMemory()

  private func folderWentAway() { folderIsGone = true }

  private func handle(_ url: URL) async {
    let id = UUID()
    let task = Task { await convert(url) }
    running[id] = task
    await task.value
    running[id] = nil
  }

  private func convert(_ url: URL) async {
    let path = url.standardizedFileURL.path
    let renamed = memory.wasRenamed(url)
    guard !produced.contains(path) else { return }

    let preset: RulePreset
    switch Arrival.of(url, folderPreset: self.preset, presets: others, onlyWhenRenamed: onlyWhenRenamed, renamed: renamed) {
    case .leave: return
    case .run(let chosen): preset = chosen
    case .ask(let request):
      // There is no window here to ask in. A preset's questions have defaults
      // to fall back on; a bare `_asksize` has nothing to go on.
      guard !request.preset.parameters.isEmpty else {
        FileHandle.standardError.write(
          Data("left       \(url.lastPathComponent): it asks, and only the app can put the question\n".utf8)
        )
        return
      }
      preset = request.preset
    }
    guard let file = try? ProcessableFile(url: url) else { return }

    do {
      let entry = try await coordinator.processFile(
        file,
        with: preset,
        destinationMode: mode,
        destinationURL: destination
      ) { _ in }
      // Every file it wrote, not only the first: a preset that splits, or a
      // PDF with several pages, writes several, and the ones not remembered
      // were picked up as new arrivals and converted again, without end.
      for output in entry.outputs {
        produced.insert(output.standardizedFileURL.path)
        print(output.path)
      }
    } catch ProcessingError.unreadableFormat, ProcessingError.unsupportedConversion, ProcessingError.unknownType {
      // A watched folder receives whatever is dropped in it.
    } catch is CancellationError {
      // Stopped on the way out; it has cleared up after itself.
    } catch {
      FileHandle.standardError.write(
        Data("failed     \(url.lastPathComponent): \(error.localizedDescription)\n".utf8)
      )
    }
  }
}
