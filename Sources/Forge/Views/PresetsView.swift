import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PresetsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var editorItem: EditorItem?

  var body: some View {
    Group {
      if model.presets.isEmpty {
        EmptyStateView(icon: "slider.horizontal.3", title: "No presets",
                       message: "Create a preset to define how files are converted.",
                       actionTitle: "New Preset") { editorItem = EditorItem(preset: nil) }
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
            ForEach(model.presets) { preset in
              PresetCard(
                preset: preset,
                deliverable: model.canDeliver(preset),
                isEnabled: Binding(
                  get: { preset.isEnabled },
                  set: { model.setPreset(preset, enabled: $0) }
                ),
                onDelete: { model.deletePreset(preset) }
              )
                .onTapGesture { editorItem = EditorItem(preset: preset) }
                .contextMenu {
                  Button("Edit") { editorItem = EditorItem(preset: preset) }
                  Button("Duplicate") { model.duplicatePreset(preset) }
                  Divider()
                  Button("Move Up") { model.movePreset(preset, by: -1) }
                    .disabled(model.presets.first?.id == preset.id)
                  Button("Move Down") { model.movePreset(preset, by: 1) }
                    .disabled(model.presets.last?.id == preset.id)
                  Divider()
                  Button("Delete", role: .destructive) { model.deletePreset(preset) }
                }
            }
          }
          .padding(20)
        }
      }
    }
    .navigationTitle("Presets")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          Button("Import Presets…") { importPresets() }
          Button("Export Presets…") { exportPresets() }
            .disabled(model.presets.isEmpty)
        } label: {
          Label("Share", systemImage: "square.and.arrow.up.on.square")
        }
        Button { editorItem = EditorItem(preset: nil) } label: { Label("New Preset", systemImage: "plus") }
      }
    }
    .sheet(item: $editorItem) { item in
      PresetEditorView(preset: item.preset) { model.savePreset($0) }
    }
  }

  private func exportPresets() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Forge Presets.json"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.exportPresets(to: url)
  }

  private func importPresets() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.importPresets(from: url)
  }

  struct EditorItem: Identifiable {
    let id = UUID()
    let preset: RulePreset?
  }
}

struct PresetCard: View {
  let preset: RulePreset
  /// False when the target format cannot be written on this Mac.
  var deliverable = true
  /// Off presets stay in the list and are offered nowhere.
  @Binding var isEnabled: Bool
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: preset.category.icon)
          .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
          .font(.title3)
        Spacer()
        Toggle("", isOn: $isEnabled)
          .toggleStyle(.switch)
          .controlSize(.mini)
          .labelsHidden()
          .help(isEnabled ? "Turn this preset off" : "Turn this preset on")
        Button(role: .destructive, action: onDelete) {
          Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Delete this preset")
      }
      HStack(spacing: 6) {
        Text(preset.name).font(.headline).lineLimit(1)
        if !deliverable {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("This Mac cannot write \(preset.targetFormat?.preferredFilenameExtension?.uppercased() ?? "that format"). Edit or delete this preset.")
        }
      }
      Text(preset.description)
        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !chips.isEmpty {
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          ForEach(chips, id: \.self) { chip in
            Text(chip)
              .font(.caption2)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
          }
        }
      }
    }
    .padding(14)
    .frame(height: 150, alignment: .top)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
    .contentShape(Rectangle())
    .opacity(isEnabled ? 1 : 0.5)
  }

  /// One chip per action, in the order they run, so the card shows the chain
  /// rather than a summary of fields that no longer exist.
  private var chips: [String] {
    preset.actions.map(Self.chip)
  }

  static func chip(_ action: Operation) -> String {
    switch action {
    case .convertFormat(let to):
      return (to.preferredFilenameExtension ?? "fmt").uppercased()
    case .resize(let width, let height, _):
      switch (width, height) {
      case let (width?, height?): return "\(width)×\(height)"
      case let (width?, nil): return "\(width) wide"
      case let (nil, height?): return "\(height) tall"
      case (nil, nil): return "resize"
      }
    case .quality(let level):
      return "Q\(level)"
    case .filter(let type):
      return type.rawValue
    case .recognizeText(let languages):
      return languages.isEmpty ? "OCR" : "OCR \(languages.joined(separator: "/"))"
    case .encode(let codec):
      return codec.title
    }
  }
}
