import SwiftUI

struct MonitoredFoldersView: View {
  @StateObject private var viewModel = MonitoredFoldersViewModel()

  var body: some View {
    VStack {
      HStack {
        Text("Monitored Folders")
          .font(.title)
        Spacer()
        Button("Add Folder") {
          viewModel.addFolder()
        }
      }
      .padding()

      if viewModel.folders.isEmpty {
        Spacer()
        Text("No monitored folders.\nAdd a folder to automatically process incoming files.")
          .multilineTextAlignment(.center)
          .foregroundColor(.secondary)
        Spacer()
      } else {
        List {
          ForEach(viewModel.folders) { folder in
            HStack {
              Image(systemName: folder.isActive ? "folder.fill" : "folder")
                .foregroundColor(folder.isActive ? .blue : .gray)
              VStack(alignment: .leading) {
                Text(folder.displayName)
                  .font(.headline)
                Text("Preset: \(folder.ruleId.uuidString)")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              Spacer()
              Toggle("", isOn: Binding(
                get: { folder.isActive },
                set: { newValue in viewModel.toggleFolder(folder, isActive: newValue) }
              ))
              .labelsHidden()
            }
          }
          .onDelete(perform: viewModel.deleteFolder)
        }
      }
    }
    .padding()
  }
}

final class MonitoredFoldersViewModel: ObservableObject {
  @Published var folders: [MonitoredFolder] = []

  init() {
    // Load from persistence
  }

  func addFolder() {
    // Show open panel
  }

  func toggleFolder(_ folder: MonitoredFolder, isActive: Bool) {
    // Update and save
  }

  func deleteFolder(at offsets: IndexSet) {
    folders.remove(atOffsets: offsets)
    // Persist change (WIP)
  }
}
