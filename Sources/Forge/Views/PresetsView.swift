import SwiftUI

struct PresetsView: View {
  @StateObject private var viewModel = PresetsViewModel()

  var body: some View {
    VStack {
      HStack {
        Text("Presets")
          .font(.title)
        Spacer()
        Button("Add Preset") {
          viewModel.showEditor = true
        }
      }
      .padding()

      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
          ForEach(viewModel.presets) { preset in
            PresetCardView(preset: preset)
              .contextMenu {
                Button("Edit") { viewModel.edit(preset) }
                Button("Duplicate") { viewModel.duplicate(preset) }
                Button("Delete", role: .destructive) { viewModel.delete(preset) }
              }
          }
        }
      }
    }
    .sheet(isPresented: $viewModel.showEditor) {
      PresetEditorView()
    }
    .padding()
  }
}

struct PresetCardView: View {
  let preset: RulePreset

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: preset.category.icon)
          .foregroundColor(.blue)
        Spacer()
        Text(preset.category.rawValue.capitalized)
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Text(preset.name)
        .font(.headline)

      Text(preset.description)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(2)

      Divider()

      HStack(spacing: 12) {
        if let format = preset.targetFormat {
          Label(format.preferredFilenameExtension ?? format.identifier, systemImage: "doc")
            .font(.caption)
        }
        if let resize = preset.resize {
          Label("\(resize.width ?? 0)×\(resize.height ?? 0)", systemImage: "arrow.up.left.and.arrow.down.right")
            .font(.caption)
        }
        if let quality = preset.quality {
          Label("\(quality)%", systemImage: "slider.horizontal.3")
            .font(.caption)
        }
      }
    }
    .padding()
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
  }
}

final class PresetsViewModel: ObservableObject {
  @Published var presets: [RulePreset] = []
  @Published var showEditor = false

  init() {
    // Load presets
  }

  func edit(_ preset: RulePreset) {}
  func duplicate(_ preset: RulePreset) {}
  func delete(_ preset: RulePreset) {}
}
