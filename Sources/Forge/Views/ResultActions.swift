import AppKit
import SwiftUI

/// What can be done with files that have just been made.
struct ResultActions: View {
  let urls: [URL]

  var body: some View {
    Menu {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
      if let more = ResultHand.more { Button("Do More with It…") { more(urls) } }
      Button("Open") { urls.forEach { NSWorkspace.shared.open($0) } }
      Divider()
      Button(urls.count == 1 ? "Copy" : "Copy \(urls.count) Files") { ResultHand.copy(urls) }
      Button(urls.count == 1 ? "Copy Path" : "Copy Paths") { ResultHand.copyPaths(urls) }
      Button("AirDrop…") { ResultHand.airDrop(urls) }
      Divider()
      if let first = urls.first { Button("Open Terminal Here") { ResultHand.terminal(at: first) } }
      Button("Copy To…") { ResultHand.put(urls, moving: false) }
      Button("Move To…") { ResultHand.put(urls, moving: true) }
    } label: {
      Label("What to do with it", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(urls.isEmpty)
    .help("Copy, AirDrop, move…")
    .accessibilityLabel(Text("What to do with it"))
  }
}

@MainActor
enum ResultHand {
  /// The menu again, over what has just been made: smaller still, another
  /// format, under a size.
  static var more: (([URL]) -> Void)?

  static func terminal(at url: URL) {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
    NSWorkspace.shared.open([url.deletingLastPathComponent()], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
  }

  static func copy(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
  }

  static func copyPaths(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
  }

  static func airDrop(_ urls: [URL]) {
    NSApp.activate(ignoringOtherApps: true)
    guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
      NSSound.beep()
      return
    }
    service.perform(withItems: urls)
  }

  static func put(_ urls: [URL], moving: Bool) {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = moving ? "Move" : "Copy"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    do { try place(urls, in: folder, moving: moving) } catch { NSAlert(error: error).runModal() }
  }

  /// Beside what is there, and never over it.
  static func place(_ urls: [URL], in folder: URL, moving: Bool) throws {
    let manager = FileManager.default
    for url in urls {
      var target = folder.appendingPathComponent(url.lastPathComponent)
      var attempt = 2
      while manager.fileExists(atPath: target.path) {
        let stem = url.deletingPathExtension().lastPathComponent
        target = folder.appendingPathComponent(url.pathExtension.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(url.pathExtension)")
        attempt += 1
      }
      if moving { try manager.moveItem(at: url, to: target) } else { try manager.copyItem(at: url, to: target) }
    }
  }
}
