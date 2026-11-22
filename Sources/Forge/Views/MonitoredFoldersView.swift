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
                       actionTitle: model.usablePresets.isEmpty ? nil : "Add Folder",
                       action: model.usablePresets.isEmpty ? nil : { showAdd = true })
      } else {
        List {
          ForEach(model.folders) { folder in
            FolderRow(folder: folder)
          }
          .onDelete { model.deleteFolders(at: $0) }
        }
      }
    }
    .navigationTitle("Folders")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { showAdd = true } label: { Label("Add Folder", systemImage: "plus") }
          .disabled(model.usablePresets.isEmpty)
      }
    }
    .sheet(isPresented: $showAdd) { AddFolderSheet() }
  }
}

/// One watched folder as a sentence: folder → preset, what happens, a switch.
private struct FolderRow: View {
  @EnvironmentObject private var model: AppModel
  let folder: MonitoredFolder

  private var preset: RulePreset? { model.presets.first { $0.id == folder.ruleId } }

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 6) {
        Image(systemName: folder.isActive ? "folder.fill" : "folder")
          .font(.title2).foregroundStyle(folder.isActive ? Color.accentColor : .secondary)
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
        Image(systemName: preset?.category.icon ?? "questionmark")
          .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
          .frame(width: Metrics.iconSize + 4, height: Metrics.iconSize + 4)
          .background(folder.isActive ? Color.accentColor : .secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(folder.arrivalSentence).font(.system(size: Metrics.bodyText, weight: .semibold))
        Text(folder.detail(presetName: model.presetName(for: folder.ruleId)))
          .font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Toggle("", isOn: Binding(
        get: { folder.isActive },
        set: { model.toggleFolder(folder, active: $0) }
      ))
      .toggleStyle(.switch).labelsHidden()
      .help(folder.isActive ? "Stop watching" : "Watch again")
      Menu {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
        Divider()
        Button("Remove", role: .destructive) { remove() }
      } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
    .padding(.vertical, 6)
    .contextMenu {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
      Button("Remove", role: .destructive) { remove() }
    }
  }

  private func remove() {
    guard let index = model.folders.firstIndex(where: { $0.id == folder.id }) else { return }
    model.deleteFolders(at: IndexSet(integer: index))
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
            ForEach(model.usablePresets) { Text($0.name).tag(Optional($0.id)) }
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
    .translucentSheet()
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
