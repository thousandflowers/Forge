import Foundation
import CoreServices

/// Watches one folder and reports files that have finished arriving.
///
/// The previous version reacted to every event flag, including the ones raised
/// by its own output, and called a fixed one-second delay a debounce, so a file
/// still being copied was handed over half-written.
final class MonitoredFolderWatcher {
  typealias FileAddedHandler = @Sendable (URL) async -> Void

  /// How long a file must stay unchanged before it counts as finished.
  private static let settleInterval: TimeInterval = 1.0
  /// How often to re-check a file that is still growing.
  private static let pollInterval: TimeInterval = 0.5

  private let queue = DispatchQueue(label: "com.eugeniozamengo.Forge.watcher", qos: .utility)
  private var stream: FSEventStreamRef?
  private var root: URL?
  private var includeSubfolders = false
  private var handler: FileAddedHandler?

  /// Files seen but not yet settled, with the size they were last seen at.
  private var pending: [String: (size: Int64, since: Date)] = [:]
  private var timer: DispatchSourceTimer?

  deinit { stop() }

  func startWatching(folder: MonitoredFolder, handler: @escaping FileAddedHandler) throws {
    stop()

    self.root = folder.url
    self.includeSubfolders = folder.includeSubfolders
    self.handler = handler

    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let watcher = Unmanaged<MonitoredFolderWatcher>.fromOpaque(info).takeUnretainedValue()
      let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
      for index in 0..<count {
        watcher.handleEvent(path: String(cString: paths[index]), flags: flags[index])
      }
    }

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )

    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      callback,
      &context,
      [folder.url.path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      Self.pollInterval,
      UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
    ) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot watch \(folder.url.lastPathComponent)"
      )
    }

    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      throw ProcessingError.conversionFailed(
        reason: "Cannot start watching \(folder.url.lastPathComponent)"
      )
    }
    self.stream = stream
  }

  func stopWatching(folder: MonitoredFolder) {
    guard root?.path == folder.url.path else { return }
    stop()
  }

  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
    timer?.cancel()
    timer = nil
    queue.async { [weak self] in self?.pending.removeAll() }
    root = nil
    handler = nil
  }

  // MARK: - Events

  /// Called on `queue`, which also owns `pending`.
  private func handleEvent(path: String, flags: FSEventStreamEventFlags) {
    guard Self.isFileArrival(flags) else { return }

    let url = URL(fileURLWithPath: path)
    guard let root, Self.isWithin(url, root: root, includeSubfolders: includeSubfolders) else { return }

    // Forge's own scratch files start with a dot; so do the system's.
    guard !url.lastPathComponent.hasPrefix(".") else { return }
    guard let size = Self.fileSize(url) else { return }

    pending[path] = (size: size, since: Date())
    startTimerIfNeeded()
  }

  /// Only creations and renames bring a new file in. Modifications, removals
  /// and permission changes used to trigger conversions of their own.
  private static func isFileArrival(_ flags: FSEventStreamEventFlags) -> Bool {
    let flags = Int(flags)
    guard flags & kFSEventStreamEventFlagItemIsFile != 0 else { return false }
    guard flags & kFSEventStreamEventFlagItemRemoved == 0 else { return false }
    return flags & kFSEventStreamEventFlagItemCreated != 0
      || flags & kFSEventStreamEventFlagItemRenamed != 0
  }

  private static func isWithin(_ url: URL, root: URL, includeSubfolders: Bool) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return false }
    if includeSubfolders { return true }
    return url.deletingLastPathComponent().standardizedFileURL.path == rootPath
  }

  private static func fileSize(_ url: URL) -> Int64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.size] as? Int64
  }

  private func startTimerIfNeeded() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
    timer.setEventHandler { [weak self] in self?.drainSettled() }
    timer.resume()
    self.timer = timer
  }

  /// Hand over the files whose size has stopped changing. A file still being
  /// copied grows between ticks, so it simply waits another round.
  private func drainSettled() {
    let now = Date()
    var ready: [URL] = []

    for (path, seen) in pending {
      let url = URL(fileURLWithPath: path)
      guard let size = Self.fileSize(url) else {
        pending.removeValue(forKey: path)
        continue
      }
      if size != seen.size {
        pending[path] = (size: size, since: now)
      } else if now.timeIntervalSince(seen.since) >= Self.settleInterval {
        pending.removeValue(forKey: path)
        ready.append(url)
      }
    }

    if pending.isEmpty {
      timer?.cancel()
      timer = nil
    }

    guard let handler, !ready.isEmpty else { return }
    for url in ready {
      Task { await handler(url) }
    }
  }
}
