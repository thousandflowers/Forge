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
    .commands {
      SidebarCommands()
      ForgeCommands(model: model)
    }

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

  func applicationWillFinishLaunching(_ notification: Notification) {
    // What pandoc writes is asked once, by running it. Asked here, in the
    // background, it is known before any window wants it.
    ExternalBridge.warmUp()
  }

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

/// The menu bar's own commands: each one does what the window's button does.
struct ForgeCommands: Commands {
  @ObservedObject var model: AppModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Preset") { model.presetEditor = PresetEditorRequest(preset: nil) }
        .keyboardShortcut("n")
      Button("Add Files…") { addFiles() }
        .keyboardShortcut("o")
    }
    CommandGroup(after: .sidebar) {
      Divider()
      ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
        Button(section.title) { model.section = section }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
      }
    }
  }

  /// Files picked here arrive the way files dropped on the Dock icon do.
  private func addFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if panel.runModal() == .OK { model.open(panel.urls) }
  }
}
