import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  let batch: BatchViewModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var isStill

  var body: some View {
    NavigationSplitView {
      List(AppSection.allCases, selection: $model.section) { item in
        SectionRow(section: item, batch: batch).tag(item)
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
      .navigationTitle("Forge")
    } detail: {
      VStack(spacing: 0) {
        // What scrolls stops under the title bar, which has no ground of its own:
        // touching the top of the window, it would go on up behind it.
        Color.clear.frame(height: 1)
        detail
      }
      // Its own ground came out as a box of another shade, over the edge of the
      // sidebar.
      .toolbarBackground(.hidden, for: .windowToolbar)
    }
    // Covered by the editor, and so out of reach: the grid of presets behind it
    // could still be walked and pressed by VoiceOver, and by anything else
    // that reads the window that way.
    .accessibilityHidden(model.presetEditor != nil)
    .task { await model.bootstrap() }
    .onAppear {
      model.showWindow = { openWindow(id: MenuBarView.windowID) }
      if Lesson.isNew { Lesson.shared.open(model) }
    }
    .preferredColorScheme(model.settings.appearance.colorScheme)
    // A preset is a program, and a program is not written in a sheet: the
    // editor takes the window, sidebar included, the way Shortcuts does.
    .overlay {
      if let request = model.presetEditor {
        PresetEditorView(
          preset: request.preset,
          conversion: request.conversion,
          offer: request.offer,
          onSave: { request.offer == nil ? model.savePreset($0) : model.install($0) },
          onClose: { model.presetEditor = nil }
        )
        .id(request.id)
        // A short way: the whole height of the window was more than is drawn
        // in time.
        .transition(isStill ? .opacity : .offset(y: 16).combined(with: .opacity))
      }
    }
    .animation(Motion.move, value: model.presetEditor?.id)
    // Running something again from History is a conversion, so the Convert
    // screen is where it happens.
    .onChange(of: model.pending) { pending in if pending != nil { model.section = .process } }
    .onChange(of: model.opened) { opened in if !opened.isEmpty { model.section = .process } }
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
    switch model.section ?? .process {
    case .process:  BatchProcessingView(vm: batch)
    case .presets:  PresetsView()
    case .store:    StoreView()
    case .folders:  MonitoredFoldersView()
    case .history:  HistoryView()
    }
  }
}

/// A place in the sidebar, and what is waiting there. What is only there is
/// not counted: a number that never goes away is not read.
private struct SectionRow: View {
  let section: AppSection
  @ObservedObject var batch: BatchViewModel

  var body: some View {
    Label(section.title, systemImage: section.icon)
      .badge(section == .process ? batch.waiting : 0)
  }
}
