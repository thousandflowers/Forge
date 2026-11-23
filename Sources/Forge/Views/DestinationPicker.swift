import SwiftUI
import AppKit

/// Where converted files go, as Quick convert and the maker both ask it.
struct DestinationPicker: View {
  @Binding var mode: DestinationMode
  @Binding var url: URL?
  let fileCount: Int

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(DestinationMode.allCases, id: \.self) { option in
        Chip(title(option), selected: mode == option) { choose(option) }
      }
      if mode != .overwrite {
        Button { pickFolder() } label: {
          Label(url.map(MonitoredFolder.abbreviated) ?? "Choose a folder…", systemImage: "folder")
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 5)
      }
    }
  }

  private func title(_ option: DestinationMode) -> String {
    option == .overwrite && fileCount > 1 ? "Replace the originals" : option.displayName
  }

  /// Copy to… and Move to… are questions until a folder answers them.
  private func choose(_ option: DestinationMode) {
    let wasOn = mode == option
    mode = option
    if option != .overwrite, wasOn || url == nil { pickFolder() }
  }

  private func pickFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    if panel.runModal() == .OK { url = panel.url }
  }
}
