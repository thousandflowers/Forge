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
              PresetCard(preset: preset)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: preset.icon ?? preset.category.icon)
          .foregroundStyle(.tint)
          .font(.title3)
        Spacer()
        Text(preset.category.rawValue.capitalized)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 2)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
      Text(preset.name).font(.headline).lineLimit(1)
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

  private var chips: [String] {
    var c: [String] = []
    if let f = preset.targetFormat { c.append((f.preferredFilenameExtension ?? "fmt").uppercased()) }
    if let r = preset.resize { c.append("\(r.width ?? 0)×\(r.height ?? 0)") }
    if let q = preset.quality { c.append("Q\(q)") }
    if !preset.filters.isEmpty { c.append("\(preset.filters.count) filter\(preset.filters.count == 1 ? "" : "s")") }
    return c
  }
}
