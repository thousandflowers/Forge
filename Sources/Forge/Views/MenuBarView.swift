import AppKit
import SwiftUI

/// The menu bar item: convert something without going to the window first.
///
/// It shares the model with the window, so a preset saved there is here
/// immediately, and a conversion started here lands in the same history.
struct MenuBarView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Group {
      if model.usablePresets.isEmpty {
        Text("No presets turned on")
      } else {
        ForEach(model.usablePresets) { preset in
          Button(preset.name) { convert(with: preset) }
            .disabled(!model.canDeliver(preset))
        }
      }

      Divider()

      if let last = model.history.first {
        Text("Last: \(last.fileURL.lastPathComponent) — \(last.status.displayName)")
        // Why, when it failed: it used to be in History and nowhere else.
        if last.status != .completed, let reason = last.errorMessage {
          Text(reason)
        }
      }

      Button(model.dropZone.isShown ? "Hide Drop Zone" : "Show Drop Zone") { model.dropZone.toggle() }
      Button("Open Forge") {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: MenuBarView.windowID)
      }
      Button("Quit Forge") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
  }

  static let windowID = "forge.main"

  /// Pick files, pick where they go, convert. The same three questions the
  /// window asks, without the window.
  private func convert(with preset: RulePreset) {
    NSApp.activate(ignoringOtherApps: true)

    let files = NSOpenPanel()
    files.allowsMultipleSelection = true
    files.canChooseDirectories = false
    files.prompt = "Convert"
    // Both panels were titled "Open" and said nothing else.
    files.message = "Choose the files to convert with “\(preset.name)”."
    guard files.runModal() == .OK, !files.urls.isEmpty else { return }

    let destination = NSOpenPanel()
    destination.canChooseDirectories = true
    destination.canChooseFiles = false
    destination.prompt = "Save Into"
    destination.message = "Choose the folder the converted files go into."
    guard destination.runModal() == .OK, let folder = destination.url else { return }

    model.convertFromMenuBar(files.urls, with: preset, into: folder)
  }
}
