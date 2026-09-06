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
    .preferredColorScheme(model.settings.appearance.colorScheme)
    // A preset is a program, and a program is not written in a sheet: the
    // editor takes the window, sidebar included, the way Shortcuts does.
    .overlay {
      if let request = model.presetEditor {
        PresetEditorView(
          preset: request.preset,
          onSave: { model.savePreset($0) },
          onClose: { model.presetEditor = nil }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: model.presetEditor?.id)
    // Running something again from History is a conversion, so the Convert
    // screen is where it happens.
    .onChange(of: model.pending) { pending in if pending != nil { section = .process } }
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
    case .gallery:  GalleryView()
    case .folders:  MonitoredFoldersView()
    case .capabilities: CapabilitiesView()
    case .history:  HistoryView()
    case .settings: SettingsView()
    }
  }
}
