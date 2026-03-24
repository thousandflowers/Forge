import SwiftUI

@main
struct ShiftApp: App {
  @StateObject private var appState = AppState.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(appState)
        .frame(minWidth: 800, minHeight: 600)
    }
  }
}

// Global app state
final class AppState: ObservableObject {
  static let shared = AppState()

  @Published var isProcessing = false
  @Published var activePresets: [RulePreset] = []
  @Published var monitoredFolders: [MonitoredFolder] = []

  private init() {
    // Load presets and settings
    Task {
      await loadPresets()
      await loadMonitoredFolders()
    }
  }

  private func loadPresets() async {
    // TODO: Load from PersistenceManager
  }

  private func loadMonitoredFolders() async {
    // TODO: Load and start watchers
  }
}
