import Foundation
import CoreServices

/// Watches a folder for file system events using FSEvents
final class MonitoredFolderWatcher {
  typealias FileAddedHandler = (URL) async -> Void

  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "com.fileforge.watcher", qos: .utility)
  private var watchedPaths: Set<String> = []
  private var handlers: [String: FileAddedHandler] = [:] // path → handler

  deinit {
    stop()
  }

  /// Start watching a folder
  func startWatching(folder: MonitoredFolder, handler: @escaping FileAddedHandler) throws {
    let path = folder.url.path

    // Watch the folder (and subfolders if requested)
    var pathsToWatch = [path]
    if folder.includeSubfolders {
      // For recursive watching, we need to add subdirectories.
      // FSEvents can watch recursively with a flag, but we'll keep simple: just the root
      // Recursive implementation can be added later
    }

    // Create event stream. A @convention(c) callback cannot capture context,
    // so we pass `self` through clientCallBackInfo and recover it inside.
    var streamRef: FSEventStreamRef?

    let callback: FSEventStreamCallback = { (_, clientCallBackInfo, numEvents, eventPaths, _, _) in
      guard let info = clientCallBackInfo else { return }
      let watcher = Unmanaged<MonitoredFolderWatcher>.fromOpaque(info).takeUnretainedValue()
      let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
      for i in 0..<numEvents {
        watcher.handleEvent(path: String(cString: paths[i]))
      }
    }

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )

    streamRef = FSEventStreamCreate(
      kCFAllocatorDefault,
      callback,
      &context,
      pathsToWatch as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      1.0, // latency in seconds
      UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
    )

    guard let stream = streamRef else {
      throw ProcessingError.conversionFailed(reason: "Failed to create FSEventStream")
    }

    FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    FSEventStreamStart(stream)

    self.stream = stream
    self.watchedPaths.insert(path)
    self.handlers[path] = handler
  }

  /// Dispatch a file-system event to the matching folder handler (debounced).
  /// Called from the FSEvents callback thread.
  private func handleEvent(path: String) {
    for (root, handler) in handlers where path.hasPrefix(root) {
      // Debounce - wait for the file to be fully written before handling.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        Task { await handler(URL(fileURLWithPath: path)) }
      }
    }
  }

  /// Stop watching a specific folder
  func stopWatching(folder: MonitoredFolder) {
    let path = folder.url.path
    if let stream = stream, watchedPaths.contains(path) {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      watchedPaths.remove(path)
      handlers.removeValue(forKey: path)
    }
  }

  /// Stop all watches
  func stop() {
    if let stream = stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    watchedPaths.removeAll()
    handlers.removeAll()
  }
}
