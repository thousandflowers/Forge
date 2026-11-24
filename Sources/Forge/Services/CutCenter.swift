import AppKit
import SwiftUI

/// The windows things are cut in: one for each file.
@MainActor
final class CutCenter: NSObject, NSWindowDelegate {
  typealias Save = @MainActor (ProcessableFile, RulePreset) async throws -> [URL]

  private var windows: [URL: NSWindow] = [:]
  private let errand: Errand
  private var watching: NSObjectProtocol?
  var isOpen: Bool { !windows.isEmpty }

  init(errand: Errand? = nil) {
    self.errand = errand ?? Errand()
    super.init()
    watching = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
      let window = note.object as? NSWindow
      MainActor.assumeIsolated { self?.cameForward(window) }
    }
  }

  deinit {
    if let watching { NotificationCenter.default.removeObserver(watching) }
  }

  func open(_ file: ProcessableFile, save: @escaping Save) {
    if let window = windows[file.url] { return front(window) }
    guard let model = CutModel(file: file) else { return }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: model.hasPicture ? 680 : 280),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = file.fileName
    window.representedURL = file.url
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentViewController = NSHostingController(rootView: CutView(
      model: model, save: { try await save(file, $0) }, close: { [weak window] in window?.close() }
    ))
    window.setContentSize(NSSize(width: 860, height: model.hasPicture ? 680 : 280))
    window.center()
    windows[file.url] = window
    front(window)
  }

  func windowWillClose(_ notification: Notification) {
    guard let closed = notification.object as? NSWindow else { return }
    windows = windows.filter { $0.value !== closed }
    if windows.isEmpty {
      // Out of the way first, or the next window of Forge's comes forward after.
      if NSApp.isActive, !closed.isKeyWindow { errand.stay() }
      isLeaving = true
      closed.orderOut(nil)
      errand.end()
      isLeaving = false
    }
    // The view stops its film when it goes, and it goes with its window.
    closed.contentViewController = nil
  }

  private var isLeaving = false

  /// One of Forge's other windows, gone to while something is being cut.
  private func cameForward(_ window: NSWindow?) {
    guard let window, isOpen, !isLeaving, NSApp.isActive, window.canBecomeMain, window.sheetParent == nil, !(window is NSPanel),
          !windows.values.contains(where: { $0 === window }) else { return }
    errand.stay()
  }

  private func front(_ window: NSWindow) {
    errand.begin()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
