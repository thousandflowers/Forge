import Foundation
import CoreServices

/// Watches one folder and reports files that have finished arriving.
///
/// Every piece of mutable state lives on `queue`. The FSEvents callback fires
/// there, and so does the settle timer, so the caller's thread never touches
/// the same storage they do.
final class MonitoredFolderWatcher {
  typealias FileAddedHandler = @Sendable (URL) async -> Void

  /// How long a file must stay unchanged before it counts as finished.
  private static let settleInterval: TimeInterval = 1.0
  /// How often to re-check a file that is still growing.
  private static let pollInterval: TimeInterval = 0.5

  private let queue = DispatchQueue(label: "com.eugeniozamengo.Forge.watcher", qos: .utility)

  /// Everything below is `queue`-only.
  private var stream: FSEventStreamRef?
  private var root: URL?
  private var includeSubfolders = false
  private var handler: FileAddedHandler?
  /// Files seen but not yet settled, with the size they were last seen at.
  private var pending: [String: (size: Int64, since: Date)] = [:]
  private var timer: DispatchSourceTimer?

  deinit {
    // `deinit` cannot wait on the queue without risking a deadlock, and by the
    // time it runs nothing else holds a reference, so tear the stream down here.
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    timer?.cancel()
  }

  func startWatching(folder: MonitoredFolder, handler: @escaping FileAddedHandler) throws {
    try queue.sync {
      teardown()

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
      self.root = folder.url
      self.includeSubfolders = folder.includeSubfolders
      self.handler = handler
    }
  }

  func stop() {
    queue.sync { teardown() }
  }

  // MARK: - Queue-only

  private func teardown() {
    dispatchPrecondition(condition: .onQueue(queue))
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
    timer?.cancel()
    timer = nil
    pending.removeAll()
    root = nil
    handler = nil
  }

  private func handleEvent(path: String, flags: FSEventStreamEventFlags) {
    dispatchPrecondition(condition: .onQueue(queue))
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
    dispatchPrecondition(condition: .onQueue(queue))
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
    dispatchPrecondition(condition: .onQueue(queue))
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
