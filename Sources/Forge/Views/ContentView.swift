import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var section: AppSection? = .process

  var body: some View {
    NavigationSplitView {
      List(AppSection.allCases, selection: $section) { item in
        Label(item.title, systemImage: item.icon)
          .tag(item)
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
      .navigationTitle("Forge")
    } detail: {
      detail
    }
    .task { await model.bootstrap() }
    .alert(
      "Forge ran into a problem",
      isPresented: Binding(
        get: { model.lastError != nil },
        set: { if !$0 { model.lastError = nil } }
      ),
      presenting: model.lastError
    ) { _ in
      Button("OK", role: .cancel) { model.lastError = nil }
    } message: { message in
      Text(message)
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch section ?? .process {
    case .process:  BatchProcessingView()
    case .presets:  PresetsView()
    case .folders:  MonitoredFoldersView()
    case .history:  HistoryView()
    case .settings: SettingsView()
    }
  }
}
