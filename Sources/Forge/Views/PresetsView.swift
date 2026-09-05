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
                onShare: { share(preset) },
                onDelete: { model.deletePreset(preset) }
              )
                .onTapGesture { editorItem = EditorItem(preset: preset) }
                .contextMenu {
                  Button("Edit") { editorItem = EditorItem(preset: preset) }
                  Button("Duplicate") { model.duplicatePreset(preset) }
                  Button("Share…") { share(preset) }
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
        // Sharing hangs off each card: a single button up here could only
        // ever mean "all of them", which is never what somebody handing a
        // preset to a friend wants.
        Button { importPresets() } label: { Label("Import Presets…", systemImage: "square.and.arrow.down") }
        Button { editorItem = EditorItem(preset: nil) } label: { Label("New Preset", systemImage: "plus") }
      }
    }
    .sheet(item: $editorItem) { item in
      PresetEditorView(preset: item.preset) { model.savePreset($0) }
    }
  }

  /// One preset to one file, named after it, so what lands in somebody's
  /// Downloads says which preset it is.
  private func share(_ preset: RulePreset) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(preset.name).json"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.export([preset], to: url)
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
  /// Hand this one preset to somebody. Its own button, on its own card.
  var onShare: (() -> Void)? = nil
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
        if let onShare {
          Button(action: onShare) {
            Image(systemName: "square.and.arrow.up")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Share “\(preset.name)”")
          .accessibilityLabel(Text("Share \(preset.name)"))
        }
        Button(role: .destructive, action: onDelete) {
          Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Delete “\(preset.name)”")
        .accessibilityLabel(Text("Delete \(preset.name)"))
      }
      HStack(spacing: 6) {
        Text(preset.name).font(.headline).lineLimit(1)
        if !deliverable {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("This Mac cannot write \(preset.targetFormat.flatMap(FormatCatalog.fileExtension(for:))?.uppercased() ?? "that format"). Edit or delete this preset.")
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
      return (FormatCatalog.fileExtension(for: to) ?? "fmt").uppercased()
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
    case .limitSize(let bytes):
      return "≤\(Int64(bytes).formatted(.byteCount(style: .file)))"
    }
  }
}
