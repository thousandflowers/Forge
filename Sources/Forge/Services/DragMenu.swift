import AppKit
import SwiftUI

/// The menu over a file that is being dragged, wherever it is dragged from.
///
/// Only the mouse is listened to, and the keys are looked at rather than
/// listened to, so no permission is needed for any of it.
@MainActor
final class DragMenu {
  /// What is looked at while something is being dragged.
  struct Hand {
    var changeCount: () -> Int = { NSPasteboard(name: .drag).changeCount }
    var files: () -> [URL] = {
      let found = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      return found as? [URL] ?? []
    }
    var flags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// Whose window it is being dragged from.
    var app: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var isDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 == 1 }
  }

  var keys = HoldKeys.usual
  /// Apps it keeps out of: ones that mean something else by the keys.
  var ignored: Set<String> = []
  var convert: AskCenter.Convert = { _, _ in [] }
  var preview: AskCenter.Preview?
  var join: AskCenter.Join?
  var suggest: (([ProcessableFile]) -> [RulePreset])?
  var cut: (@MainActor (ProcessableFile) -> Void)?

  /// The menu this drag brought up, until the drag is over.
  private(set) var session: AskSession?

  var isWatching: Bool { timer != nil }

  private static let interval: TimeInterval = 0.05
  /// The button is up before the drop is delivered.
  private static let grace: TimeInterval = 0.6

  private let hand: Hand
  private let shows: Bool
  private var monitors: [Any] = []
  private var timer: Timer?
  private var seen: Int
  private var drag = 0
  private var isReading = false
  /// Every menu that is up. Without a panel where there is no screen.
  private(set) var open: [(session: AskSession, panel: AskPanel?)] = []

  init(hand: Hand = Hand(), shows: Bool = true) {
    self.hand = hand
    self.shows = shows
    seen = hand.changeCount()
  }

  func start() {
    guard monitors.isEmpty else { return }
    seen = hand.changeCount()
    monitors = [
      NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged]) { [weak self] event in
        let isDrag = event.type == .leftMouseDragged
        MainActor.assumeIsolated { if isDrag { self?.dragged() } else { self?.pressed() } }
      },
      // Forge's own windows, which the other one does not hear.
      NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
        MainActor.assumeIsolated { self?.pressed(in: event.window) }
        return event
      },
    ].compactMap { $0 }
  }

  func stop() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    finishWatching()
    if let session { close(session) }
  }

  /// What the pasteboard holds before anything is dragged is an old drag's.
  /// And a menu left waiting goes when the click is somewhere else.
  func pressed(in window: NSWindow? = nil) {
    for menu in open where !menu.session.isWorking && !(window.map { menu.panel?.owns($0) ?? false } ?? false) { close(menu.session) }
    guard timer == nil else { return }
    seen = hand.changeCount()
  }

  func dragged() {
    guard timer == nil, hand.changeCount() != seen else { return }
    seen = hand.changeCount()
    if let app = hand.app(), ignored.contains(app) { return }
    drag += 1
    let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.look() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// One look at the keys and the button, for as long as the drag lasts.
  func look() {
    guard hand.isDown() else { return released() }
    guard session == nil, !isReading, keys.areHeld(hand.flags()) else { return }
    let urls = hand.files()
    guard !urls.isEmpty else { return }
    isReading = true
    let this = drag
    Task {
      let files = await Task.detached { urls.compactMap { try? ProcessableFile(url: $0) }.filter { ConvertKind(fileType: $0.fileType) != nil } }.value
      // Let go of, or dragging something else by now.
      guard this == drag, timer != nil else { return }
      if !files.isEmpty { show(files) }
    }
  }

  /// Dropped on a choice: that choice. Anywhere else on the menu: it stays, to
  /// be answered with a click.
  func dropped(on tile: DropTiles.Tile?, of dropped: AskSession) -> Bool {
    guard session === dropped, case .asking = dropped.state else { return false }
    session = nil
    if let tile {
      dropped.choose(tile.answer, for: tile.question)
      if tile.answer != .cut { dropped.start() }
    }
    return true
  }

  private func released() {
    finishWatching()
    guard let left = session else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) { [weak self] in
      // Answered with a click in the meantime, it is no longer waiting.
      guard let self, self.session === left, case .asking = left.state else { return }
      self.close(left)
    }
  }

  private func finishWatching() {
    timer?.invalidate()
    timer = nil
    isReading = false
    seen = hand.changeCount()
  }

  private func show(_ files: [ProcessableFile]) {
    let session = AskSession(
      request: AskRequest(word: .everything, over: nil), file: files[0], convert: convert, preview: preview
    )
    session.files = files
    session.join = join
    session.suggest = suggest
    session.cut = cut
    session.onClose = { [weak self, weak session] in
      if let session { self?.close(session) }
    }
    // The one before, let go of a moment ago and not yet gone.
    if let before = self.session { close(before) }
    self.session = session
    guard shows else { return open.append((session, nil)) }
    let tiles = DropTiles()
    let panel = AskPanel(session: session, tiles: tiles) { [weak self, weak session] in
      if let session { self?.close(session) }
    }
    tiles.isLive = true
    tiles.drop = { [weak self, weak session, weak panel, weak tiles] tile in
      guard let self, let session, self.dropped(on: tile, of: session) else { return false }
      tiles?.isLive = false
      panel?.takeKeys()
      return true
    }
    open.append((session, panel))
    panel.appear(takingKeys: false)
    session.measure()
  }

  /// The menu for files let go of somewhere, rather than held.
  func present(_ urls: [URL]) {
    Task {
      let files = await Task.detached { urls.compactMap { try? ProcessableFile(url: $0) }.filter { ConvertKind(fileType: $0.fileType) != nil } }.value
      guard !files.isEmpty else { NSSound.beep(); return }
      let session = AskSession(request: AskRequest(word: .everything, over: nil), file: files[0], convert: convert, preview: preview)
      session.files = files
      session.join = join
      session.suggest = suggest
      session.cut = cut
      session.onClose = { [weak self, weak session] in if let session { self?.close(session) } }
      guard shows else { return open.append((session, nil)) }
      let panel = AskPanel(session: session) { [weak self, weak session] in if let session { self?.close(session) } }
      open.append((session, panel))
      panel.appear()
      session.measure()
    }
  }

  private func close(_ session: AskSession) {
    if self.session === session { self.session = nil }
    session.stop()
    open.first { $0.session === session }?.panel?.close()
    open.removeAll { $0.session === session }
  }
}

/// Where the choices are, for a file held over them.
@MainActor
final class DropTiles: ObservableObject {
  struct Tile: Hashable {
    let question: AskRequest.Question
    let answer: AskRequest.Answer
  }

  /// The one under the file.
  @Published private(set) var over: Tile?
  /// From the top left, as SwiftUI counts.
  var frames: [Tile: CGRect] = [:]
  /// Whether a drag brought this menu up and is still going.
  @Published var isLive = false
  var drop: (Tile?) -> Bool = { _ in false }

  /// The choices meet halfway: between two of them is still one of them.
  private static let reach: CGFloat = 4

  func tile(at point: CGPoint) -> Tile? {
    frames.first { $0.value.insetBy(dx: -Self.reach, dy: -Self.reach).contains(point) }?.key
  }

  func move(to point: CGPoint?) {
    over = point.flatMap(tile)
  }

  /// Never a move or a delete: whoever is being dragged from keeps its file.
  static func operation(of offered: NSDragOperation) -> NSDragOperation {
    [.copy, .generic, .link].first { offered.contains($0) } ?? []
  }
}
