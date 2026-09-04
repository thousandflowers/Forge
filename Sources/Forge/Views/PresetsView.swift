import SwiftUI

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
              PresetCard(preset: preset, deliverable: model.canDeliver(preset))
                .onTapGesture { editorItem = EditorItem(preset: preset) }
                .contextMenu {
                  Button("Edit") { editorItem = EditorItem(preset: preset) }
                  Button("Duplicate") { model.duplicatePreset(preset) }
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
      ToolbarItem(placement: .primaryAction) {
        Button { editorItem = EditorItem(preset: nil) } label: { Label("New Preset", systemImage: "plus") }
      }
    }
    .sheet(item: $editorItem) { item in
      PresetEditorView(preset: item.preset) { model.savePreset($0) }
    }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: preset.category.icon)
          .foregroundStyle(.tint)
          .font(.title3)
        Spacer()
        Text(preset.category.rawValue.capitalized)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 2)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
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
  }

  /// One chip per action, in the order they run, so the card shows the chain
  /// rather than a summary of fields that no longer exist.
  private var chips: [String] {
    preset.actions.map(Self.chip)
  }

  private static func chip(_ action: Operation) -> String {
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
    }
  }
}
