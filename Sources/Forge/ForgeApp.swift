import SwiftUI
import AppKit

struct ForgeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    Window("Forge", id: MenuBarView.windowID) {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 880, minHeight: 600)
        .onAppear { delegate.inbox.deliver = { model.open($0) } }
    }
    .commands { SidebarCommands() }

    // A conversion is usually a small errand, and going to the window for it
    // is more ceremony than the errand deserves.
    MenuBarExtra("Forge", systemImage: "hammer") {
      MenuBarView()
        .environmentObject(model)
    }
  }
}

/// Files handed to Forge from outside: dropped on the Dock icon, chosen from
/// Open With, or passed to `open -a Forge`. They are treated exactly like a
/// drop on the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let inbox = OpenedFiles()

  func application(_ application: NSApplication, open urls: [URL]) {
    inbox.receive(urls)
  }
}

/// Holds what arrives before the window does. At launch macOS hands the files
/// over before any view exists, so they wait here until one asks for them.
@MainActor
final class OpenedFiles {
  private var waiting: [URL] = []

  var deliver: (([URL]) -> Void)? {
    didSet { flush() }
  }

  func receive(_ urls: [URL]) {
    waiting += urls
    flush()
  }

  private func flush() {
    guard let deliver, !waiting.isEmpty else { return }
    let urls = waiting
    waiting = []
    deliver(urls)
  }
}
