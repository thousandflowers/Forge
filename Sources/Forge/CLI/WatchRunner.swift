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

  init(preset: RulePreset, mode: DestinationMode, destination: URL?, settings: AppSettings) {
    self.preset = preset
    self.mode = mode
    self.destination = destination
    self.coordinator = ProcessingCoordinator(settings: settings)
  }

  func run(folder: MonitoredFolder) async throws {
    let watcher = MonitoredFolderWatcher()
    try watcher.startWatching(folder: folder) { [weak self] url in
      await self?.handle(url)
    }
    defer { watcher.stop() }

    let target = folder.url.lastPathComponent
    FileHandle.standardError.write(Data("Watching \(target). Press Ctrl-C to stop.\n".utf8))

    // Nothing else drives this process, so hold it open until interrupted.
    while !Task.isCancelled {
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
  }

  private func handle(_ url: URL) async {
    let path = url.standardizedFileURL.path
    guard !produced.contains(path) else { return }

    guard let file = try? ProcessableFile(url: url) else { return }

    do {
      let entry = try await coordinator.processFile(
        file,
        with: preset,
        destinationMode: mode,
        destinationURL: destination
      ) { _ in }
      if let output = entry.outputURL {
        produced.insert(output.standardizedFileURL.path)
        print(output.path)
      }
    } catch ProcessingError.unreadableFormat, ProcessingError.unsupportedConversion, ProcessingError.unknownType {
      // A watched folder receives whatever is dropped in it.
    } catch {
      FileHandle.standardError.write(
        Data("failed     \(url.lastPathComponent): \(error.localizedDescription)\n".utf8)
      )
    }
  }
}
