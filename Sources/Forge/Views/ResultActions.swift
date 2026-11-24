import AppKit
import SwiftUI

/// What can be done with files that have just been made.
struct ResultActions: View {
  let urls: [URL]

  var body: some View {
    Menu {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
      Button("Open") { urls.forEach { NSWorkspace.shared.open($0) } }
      Divider()
      Button(urls.count == 1 ? "Copy" : "Copy \(urls.count) Files") { ResultHand.copy(urls) }
      Button(urls.count == 1 ? "Copy Path" : "Copy Paths") { ResultHand.copyPaths(urls) }
      if ResultHand.canAirDrop(urls) { Button("AirDrop…") { ResultHand.airDrop(urls) } }
      Divider()
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
  static func copy(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
  }

  static func copyPaths(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
  }

  static func canAirDrop(_ urls: [URL]) -> Bool {
    NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: urls) ?? false
  }

  static func airDrop(_ urls: [URL]) {
    NSApp.activate(ignoringOtherApps: true)
    NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
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
