import SwiftUI
import AppKit

struct ForgeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()
  /// Here rather than in the window, so a closed window keeps its files.
  @StateObject private var batch = BatchViewModel()

  var body: some Scene {
    Window("Forge", id: MenuBarView.windowID) {
      ContentView(batch: batch)
        .environmentObject(model)
        .frame(minWidth: 880, minHeight: 600)
        .onAppear { delegate.inbox.deliver = { model.open($0) } }
    }
    // Files opened from outside come through the delegate, to the window there
    // is. Left to itself SwiftUI opens the scene again for each: the window
    // faded out and came back.
    .handlesExternalEvents(matching: [])
    .commands {
      SidebarCommands()
      ForgeCommands(model: model, batch: batch)
    }

    // A conversion is usually a small errand, and going to the window for it
    // is more ceremony than the errand deserves.
    MenuBarExtra {
      MenuBarView()
        .environmentObject(model)
    } label: {
      // The symbol's own name was what VoiceOver read: "Build" ("Compilazione").
      MenuBarLabel(model: model, delegate: delegate)
    }
  }
}

/// The menu bar's icon, which is there from launch whether or not a window is:
/// so it is what says where files from outside go.
private struct MenuBarLabel: View {
  let model: AppModel
  let delegate: AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(systemName: "hammer")
      .accessibilityLabel(Text("Forge"))
      .onAppear {
        model.showWindow = { openWindow(id: MenuBarView.windowID) }
        delegate.inbox.deliver = { model.open($0) }
        delegate.service.cut = { model.cut($0) }
        delegate.becameActive = { model.startAutomatic() }
      }
  }
}

/// Files handed to Forge from outside: dropped on the Dock icon, chosen from
/// Open With, or passed to `open -a Forge`. They are treated exactly like a
/// drop on the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let inbox = OpenedFiles()
  let service = FinderService()

  func applicationWillTerminate(_ notification: Notification) { ClipboardLighter.leaveNothing() }

  func applicationWillFinishLaunching(_ notification: Notification) {
    // What pandoc writes is asked once, by running it. Asked here, in the
    // background, it is known before any window wants it.
    ExternalBridge.warmUp()
    service.convert = { [inbox] in inbox.receive($0) }
    NSApplication.shared.servicesProvider = service
  }

  var becameActive: () -> Void = {}
  func applicationDidBecomeActive(_ notification: Notification) { becameActive() }

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
  @ObservedObject var batch: BatchViewModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Preset") { model.presetEditor = PresetEditorRequest(preset: nil) }
        .keyboardShortcut("n")
        .disabled(model.presetEditor != nil)
      Button("Add Files…") { addFiles() }
        .keyboardShortcut("o")
      Menu("Start Next Conversion") {
        Button(batch.startsAt == nil ? "✓ Now" : "Now") { batch.startsAt = nil }
        ForEach([15, 60, 180, 480], id: \.self) { minutes in
          Button(minutes < 60 ? "In \(minutes) minutes" : "In \(minutes / 60) \(minutes == 60 ? "hour" : "hours")") {
            batch.startsAt = Date().addingTimeInterval(Double(minutes) * 60)
          }
        }
        if let startsAt = batch.startsAt { Text("At \(startsAt.formatted(date: .omitted, time: .shortened))") }
      }
      Button("Cut…") { cut() }
        .keyboardShortcut("t")
    }
    // Where every Mac app keeps it, as well as in the sidebar.
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") { model.section = .settings }
        .keyboardShortcut(",")
        .disabled(model.presetEditor != nil)
    }
    // The default item put up "Help isn't available for Forge."
    CommandGroup(replacing: .help) {
      Button("Forge Help") { NSWorkspace.shared.open(Self.helpURL) }
    }
    CommandGroup(after: .sidebar) {
      Divider()
      ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
        Button(section.title) { model.section = section }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
          // The editor covers the window: a section changed behind it took the
          // files it was opened with away.
          .disabled(model.presetEditor != nil)
      }
    }
  }

  static let helpURL = URL(string: "https://github.com/thousandflowers/Forge#readme")!

  private func cut() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .movie, .audio]
    panel.message = "Choose a film, a recording or a picture to cut."
    guard panel.runModal() == .OK, let url = panel.url, let file = try? ProcessableFile(url: url) else { return }
    model.cut(file)
  }

  /// Files picked here arrive the way files dropped on the Dock icon do.
  private func addFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if panel.runModal() == .OK { model.open(panel.urls) }
  }
}
