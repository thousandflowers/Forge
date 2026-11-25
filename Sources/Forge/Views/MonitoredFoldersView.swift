import SwiftUI
import AppKit

struct MonitoredFoldersView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showAdd = false

  var body: some View {
    Group {
      if model.folders.isEmpty {
        EmptyStateView(icon: "folder.badge.gearshape", title: "No watched folders",
                       message: "Rename a file on the Desktop to clip_mute.mp4, and it is done. Or add a folder, and Forge converts what is dropped into it.",
                       actionTitle: "Watch my Desktop and Downloads for names",
                       action: { model.watchForNames() })
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
  @State private var confirmingRemoval = false

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 6) {
        BlockIcon(symbol: "folder.fill", tint: folder.isActive ? .accentColor : .gray, size: 30)
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
        // Without a preset it is the name that says.
        BlockIcon(
          symbol: folder.ruleId == AppModel.noPreset ? "character.cursor.ibeam" : preset?.category.icon ?? "questionmark",
          tint: folder.isActive ? preset?.category.tint ?? .orange : .gray, size: 30
        )
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
        onlyWhenRenamed
        Divider()
        Button("Remove…", role: .destructive) { confirmingRemoval = true }
      } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More")
    }
    .padding(.vertical, 6)
    .contextMenu {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
      onlyWhenRenamed
      Button("Remove…", role: .destructive) { confirmingRemoval = true }
    }
    // Deleting a preset asks; so does clearing the history. This went at once.
    .confirmationDialog("Stop watching “\(folder.displayName)”?", isPresented: $confirmingRemoval) {
      Button("Remove", role: .destructive) { remove() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Forge stops converting what arrives in it. The folder and everything in it stay where they are.")
    }
  }

  private var onlyWhenRenamed: some View {
    Toggle("Only when renamed", isOn: Binding(
      get: { folder.onlyWhenRenamed },
      set: { model.setOnlyWhenRenamed(folder, $0) }
    ))
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
  @State private var onlyWhenRenamed = false

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
          Toggle(isOn: $onlyWhenRenamed) {
            Text("Only when renamed")
            Text("Leaves every file alone until its name says what it wants: photo_2MB, photo_privacy, photo_ask, or a preset’s own word.")
          }
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
      // One ground, with the buttons under it.
      .scrollContentBackground(.hidden)
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
              includeSubfolders: includeSubfolders,
              onlyWhenRenamed: onlyWhenRenamed
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
    .frame(width: 460, height: 430)
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
