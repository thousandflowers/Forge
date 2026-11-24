import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Files given another extension by hand, where people keep theirs.
///
/// macOS says what was renamed and not by whom. By hand is in the Finder, with a
/// key or the mouse just used; what programs rename, they rename with neither.
@MainActor
final class HandRenames {
  /// What is looked at when something has been renamed.
  struct Hand {
    var isInFinder: () -> Bool = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" }
    var idle: () -> TimeInterval = {
      [CGEventType.keyDown, .leftMouseDown, .leftMouseUp].map {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
      }.min() ?? .infinity
    }
  }

  /// Long enough for the Finder to ask whether the extension is really to change
  /// and for the answer to be told.
  private static let justNow: TimeInterval = 3
  private static let latency: TimeInterval = 0.2

  static var places: [URL] {
    [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .documentDirectory, .picturesDirectory]
      .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
  }

  private let hand: Hand
  private var stream: FSEventStreamRef?
  private var pairs = RenamePairs()
  private var roots: [URL] = []
  private var renamed: @MainActor (_ file: URL, _ before: String) -> Void = { _, _ in }

  var isWatching: Bool { stream != nil }

  init(hand: Hand = Hand()) { self.hand = hand }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }

  func start(in places: [URL]? = nil, renamed: @escaping @MainActor (URL, String) -> Void) {
    self.renamed = renamed
    guard stream == nil else { return }
    // As the events have them: a place reached through a link is told by where it is.
    roots = (places ?? Self.places).map(Self.real)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info, let told = unsafeBitCast(paths, to: NSArray.self) as? [NSDictionary] else { return }
      let watcher = Unmanaged<HandRenames>.fromOpaque(info).takeUnretainedValue()
      let events = (0..<count).compactMap { index -> RenamePairs.Event? in
        let flag = Int(flags[index])
        guard flag & kFSEventStreamEventFlagItemRenamed != 0, flag & kFSEventStreamEventFlagItemIsFile != 0,
              let path = told[index][kFSEventStreamEventExtendedDataPathKey] as? String,
              let number = told[index][kFSEventStreamEventExtendedFileIDKey] as? NSNumber else { return nil }
        return RenamePairs.Event(path: path, file: number.uint64Value)
      }
      MainActor.assumeIsolated { watcher.heard(events) }
    }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
    )
    guard let stream = FSEventStreamCreate(
      nil, callback, &context, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
      // IgnoreSelf: what Forge renames, it renames for its own reasons.
      UInt32(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagUseCFTypes
          | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf
      )
    ) else { return }
    FSEventStreamSetDispatchQueue(stream, .main)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return
    }
    self.stream = stream
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
    pairs = RenamePairs()
  }

  func heard(_ events: [RenamePairs.Event]) {
    for event in events {
      guard let (before, after) = pairs.take(event) else { continue }
      guard isByHand, Self.changesKind(from: before, to: after), Self.isSomebodys(before, under: roots), Self.isSomebodys(after, under: roots) else { continue }
      renamed(URL(fileURLWithPath: after), (before as NSString).lastPathComponent)
    }
  }

  private var isByHand: Bool { hand.isInFinder() && hand.idle() <= Self.justNow }

  /// Foundation takes `/private` off the front, and the events leave it on.
  static func real(_ url: URL) -> URL {
    guard let path = realpath(url.path, nil) else { return url }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
  }

  /// In the same folder: moved as well, it is being put away.
  static func changesKind(from before: String, to after: String) -> Bool {
    let old = URL(fileURLWithPath: before), new = URL(fileURLWithPath: after)
    return old.deletingLastPathComponent() == new.deletingLastPathComponent()
      && !old.pathExtension.isEmpty && !new.pathExtension.isEmpty
      && old.pathExtension.lowercased() != new.pathExtension.lowercased()
  }

  /// Not a part of something: an app's, the system's, or a programmer's.
  static func isSomebodys(_ path: String, under roots: [URL]) -> Bool {
    guard let root = roots.first(where: { path.hasPrefix($0.path + "/") }) else { return false }
    let pieces = path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
    guard !pieces.contains(where: { $0.hasPrefix(".") }) else { return false }
    var folder = root
    for piece in [""] + pieces.dropLast() {
      if !piece.isEmpty { folder.appendPathComponent(piece) }
      if piece == "node_modules" || isPackage(piece) { return false }
      if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return false }
    }
    return true
  }

  private static func isPackage(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory) else { return false }
    return type.conforms(to: .package) || type.conforms(to: .bundle)
  }
}

/// The two halves of a rename, which are told one after the other: what it was
/// called, and what it is.
struct RenamePairs {
  struct Event: Equatable {
    let path: String
    let file: UInt64
  }

  private static let most = 64
  private var halves: [Event] = []

  mutating func take(_ event: Event) -> (before: String, after: String)? {
    guard let index = halves.lastIndex(where: { $0.file == event.file && $0.path != event.path }) else {
      halves.append(event)
      if halves.count > Self.most { halves.removeFirst() }
      return nil
    }
    return (halves.remove(at: index).path, event.path)
  }
}
