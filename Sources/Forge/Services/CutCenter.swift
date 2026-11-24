import AppKit
import SwiftUI

/// The windows things are cut in: one for each file.
@MainActor
final class CutCenter: NSObject, NSWindowDelegate {
  typealias Save = @MainActor (ProcessableFile, RulePreset) async throws -> [URL]

  private var windows: [URL: NSWindow] = [:]
  var isOpen: Bool { !windows.isEmpty }

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
    // The view stops its film when it goes, and it goes with its window.
    closed.contentViewController = nil
  }

  private func front(_ window: NSWindow) {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}
