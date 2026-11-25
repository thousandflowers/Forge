import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PresetsView: View {
  @EnvironmentObject private var model: AppModel
  /// The card files are being dragged over, outlined so the drop has a target.
  @State private var dropTarget: UUID?
  /// The preset waiting on a yes before it is deleted.
  @State private var deleting: RulePreset?
  @State private var search = ""

  private var found: [RulePreset] {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return model.presets }
    return model.presets.filter { preset in
      ([preset.name, preset.description] + preset.actions.map(PresetChip.text)).contains { $0.lowercased().contains(needle) }
    }
  }

  var body: some View {
    Group {
      if model.presets.isEmpty {
        EmptyStateView(icon: "slider.horizontal.3", title: "No presets",
                       message: "Create a preset to define how files are converted.",
                       actionTitle: "New Preset") { model.presetEditor = PresetEditorRequest(preset: nil) }
      } else if found.isEmpty {
        EmptyStateView(icon: "magnifyingglass", title: "Nothing matches", message: "No preset of yours fits what you are looking for.")
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
            ForEach(found) { preset in
              PresetCard(
                preset: preset,
                deliverable: model.canDeliver(preset),
                isEnabled: Binding(
                  get: { preset.isEnabled },
                  set: { model.setPreset(preset, enabled: $0) }
                ),
                actions: { actions(for: preset) }
              )
                .onTapGesture { model.presetEditor = PresetEditorRequest(preset: preset) }
                // Files dropped on a preset run through it: they go to the
                // Convert screen with this preset chosen, through the same
                // questions and confirmations as any other run.
                .dropDestination(for: URL.self) { urls, _ in
                  guard !urls.isEmpty else { return false }
                  model.pending = AppModel.PendingConversion(
                    files: urls,
                    preset: preset,
                    destination: urls.first?.deletingLastPathComponent(),
                    mode: .copyTo,
                    replacesList: false
                  )
                  return true
                } isTargeted: { targeted in
                  dropTarget = targeted ? preset.id : (dropTarget == preset.id ? nil : dropTarget)
                }
                .overlay(
                  RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: dropTarget == preset.id ? 2.5 : 0)
                )
                .contextMenu { actions(for: preset) }
            }
          }
          .padding(20)
        }
      }
    }
    .searchable(text: $search, placement: .toolbar, prompt: "Search presets")
    // A preset can be an afternoon's work, and there is no Undo: one click on
    // a small × used to delete it for good.
    .confirmationDialog(
      deleting.map { "Delete “\($0.name)”?" } ?? "",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      if let preset = deleting {
        Button("Delete", role: .destructive) { model.deletePreset(preset); deleting = nil }
        Button("Cancel", role: .cancel) { deleting = nil }
      }
    } message: {
      Text("It cannot be brought back. Share it first to keep a copy.")
    }
    .navigationTitle(model.presetEditor == nil ? "Presets" : (model.presetEditor?.preset?.name ?? "New Preset"))
    // The editor covers the screen, so the screen's own buttons step aside
    // rather than sit above it doing things to a list nobody can see.
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if model.presetEditor == nil {
        // Sharing hangs off each card: a single button up here could only
        // ever mean "all of them", which is never what somebody handing a
        // preset to a friend wants.
        Button { importPresets() } label: { Label("Import Presets…", systemImage: "square.and.arrow.down") }
        Button { model.presetEditor = PresetEditorRequest(preset: nil) } label: { Label("New Preset", systemImage: "plus") }
        }
      }
    }
  }

  @ViewBuilder
  private func actions(for preset: RulePreset) -> some View {
    Button("Edit") { model.presetEditor = PresetEditorRequest(preset: preset) }
    Button("Duplicate") { model.duplicatePreset(preset) }
    Button("Share…") { share(preset) }
    Divider()
    Button("Move Up") { model.movePreset(preset, by: -1) }
      .disabled(model.presets.first?.id == preset.id)
    Button("Move Down") { model.movePreset(preset, by: 1) }
      .disabled(model.presets.last?.id == preset.id)
    Divider()
    Button("Delete…", role: .destructive) { deleting = preset }
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

}

struct PresetCard<Actions: View>: View {
  let preset: RulePreset
  /// False when the target format cannot be written on this Mac.
  var deliverable = true
  /// Off presets stay in the list and are offered nowhere.
  @Binding var isEnabled: Bool
  /// What can be done with it, in the menu on the card.
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        BlockIcon(symbol: preset.category.icon, tint: isEnabled ? preset.category.tint : .gray, size: 30)
        Text(preset.name).font(.headline).lineLimit(1)
        if !deliverable {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("This Mac cannot write \(preset.targetFormat.flatMap(FormatCatalog.fileExtension(for:))?.uppercased() ?? "that format"). Edit or delete this preset.")
        }
        Spacer(minLength: 0)
        Menu(content: actions) { Image(systemName: "ellipsis.circle") }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel(Text("More for \(preset.name)"))
      }
      Text(preset.description)
        .font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        TagRow(texts: preset.actions.map(PresetChip.text))
        Spacer(minLength: 4)
        Toggle("In Convert", isOn: $isEnabled)
          .toggleStyle(.switch)
          .controlSize(.mini)
          .font(.caption)
          .fixedSize()
          .help(isEnabled ? "Offered when you convert" : "Kept, and offered nowhere")
          .accessibilityLabel(Text("Use \(preset.name)"))
      }
    }
    .padding(14)
    .frame(height: 142, alignment: .top)
    .forgeCard(lifts: true)
    .opacity(isEnabled ? 1 : 0.6)
  }
}

/// What a step is, in a word or two.
enum PresetChip {
  static func text(_ action: Operation) -> String {
    switch action {
    case .convertFormat(let to):
      return (FormatCatalog.fileExtension(for: to) ?? "fmt").uppercased()
    case .resize(let width, let height, _):
      switch (width, height) {
      case let (width?, height?): return "\(width) × \(height)"
      case let (width?, nil): return "\(width) wide"
      case let (nil, height?): return "\(height) tall"
      case (nil, nil): return "resize"
      }
    case .stripMetadata(let policy):
      switch policy {
      case .keepAll: return "all metadata"
      case .stripLocation: return "no location"
      case .stripAll: return "no metadata"
      }
    case .when(let condition, _, _):
      return "if \(condition.subject.title.lowercased())"
    case .split(let branches):
      return "\(branches.count) copies"
    case .join:
      return "rejoin"
    case .merge(let kind):
      return kind.title
    case .quality(let level):
      return "Q\(level)"
    case .filter(let type):
      return type.rawValue
    case .recognizeText(let languages):
      return languages.isEmpty ? "OCR" : "OCR \(languages.joined(separator: "/"))"
    case .encode(let codec):
      return codec.title
    case .film(let settings):
      return settings.encoder.title
    case .tool(let tool):
      return tool.title
    case .limitSize(let bytes):
      return "≤\(Int64(bytes).formatted(.byteCount(style: .file)))"
    }
  }
}
