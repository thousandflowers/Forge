import SwiftUI
import AppKit

struct MonitoredFoldersView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showAdd = false

  var body: some View {
    Group {
      if model.folders.isEmpty {
        EmptyStateView(icon: "folder.badge.gearshape", title: "No monitored folders",
                       message: "Add a folder and Forge converts new files dropped into it automatically.",
                       actionTitle: model.presets.isEmpty ? nil : "Add Folder",
                       action: model.presets.isEmpty ? nil : { showAdd = true })
      } else {
        List {
          ForEach(model.folders) { folder in
            HStack(spacing: 12) {
              Image(systemName: folder.isActive ? "folder.fill" : "folder")
                .foregroundStyle(folder.isActive ? Color.accentColor : .secondary)
                .font(.title3)
              VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName).font(.headline)
                Text("\(model.presetName(for: folder.ruleId)) · \(folder.destinationMode.displayName)")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Toggle("", isOn: Binding(
                get: { folder.isActive },
                set: { model.toggleFolder(folder, active: $0) }
              )).labelsHidden()
            }
            .padding(.vertical, 4)
          }
          .onDelete { model.deleteFolders(at: $0) }
        }
      }
    }
    .navigationTitle("Folders")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { showAdd = true } label: { Label("Add Folder", systemImage: "plus") }
          .disabled(model.presets.isEmpty)
      }
    }
    .sheet(isPresented: $showAdd) { AddFolderSheet() }
  }
}

private struct AddFolderSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var folderURL: URL?
  @State private var presetID: UUID?
  @State private var mode: DestinationMode = .copyTo
  @State private var destinationURL: URL?
  @State private var includeSubfolders = false

  private var canAdd: Bool {
    folderURL != nil && presetID != nil && (mode == .overwrite || destinationURL != nil)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Folder to watch") {
          Button { pick(source: true) } label: {
            Label(folderURL?.path ?? "Choose folder…", systemImage: "folder").lineLimit(1)
          }
          Toggle("Include subfolders", isOn: $includeSubfolders)
        }
        Section("Apply") {
          Picker("Preset", selection: $presetID) {
            Text("Choose…").tag(UUID?.none)
            ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
          }
          Picker("Destination", selection: $mode) {
            ForEach(DestinationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          if mode != .overwrite {
            Button { pick(source: false) } label: {
              Label(destinationURL?.path ?? "Choose destination…", systemImage: "tray.and.arrow.down").lineLimit(1)
            }
          }
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Add") {
          if let folderURL, let presetID {
            model.addFolder(
              url: folderURL,
              presetID: presetID,
              mode: mode,
              destination: destinationURL,
              includeSubfolders: includeSubfolders
            )
          }
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canAdd)
        .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 460, height: 420)
    .onAppear { if presetID == nil { presetID = model.presets.first?.id } }
  }

  private func pick(source: Bool) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    if panel.runModal() == .OK {
      if source { folderURL = panel.url } else { destinationURL = panel.url }
    }
  }
}
