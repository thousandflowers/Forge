import SwiftUI

struct ContentView: View {
  @StateObject private var viewModel = ContentViewModel()

  var body: some View {
    TabView {
      BatchProcessingView()
        .tabItem {
          Label("Process", systemImage: "square.and.arrow.down")
        }

      MonitoredFoldersView()
        .tabItem {
          Label("Folders", systemImage: "folder")
        }

      PresetsView()
        .tabItem {
          Label("Presets", systemImage: "slider.horizontal.3")
        }

      HistoryView()
        .tabItem {
          Label("History", systemImage: "clock")
        }

      SettingsView()
        .tabItem {
          Label("Settings", systemImage: "gear")
        }
    }
    .frame(minWidth: 900, minHeight: 600)
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK", role: .cancel) { }
    } message: {
      Text(viewModel.errorMessage ?? "Unknown error")
    }
  }
}

// MARK: - ViewModel

final class ContentViewModel: ObservableObject {
  @Published var showError = false
  @Published var errorMessage: String?

  init() {
    // Initialize app
  }

  func showError(_ message: String) {
    self.errorMessage = message
    self.showError = true
  }
}
