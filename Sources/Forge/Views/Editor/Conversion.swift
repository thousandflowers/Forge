import SwiftUI

/// Files the maker was opened with, from Quick convert: the same maker, with
/// something to convert once at the end of it.
struct EditorConversion {
  /// How the maker was left: the chain, and where the files go.
  struct Outcome {
    let chain: RulePreset
    let mode: DestinationMode
    let destination: URL?
  }

  let sources: [ProcessableFile]
  let fitMode: ResizeFitMode
  let mode: DestinationMode
  let destination: URL?
  let onBack: (Outcome) -> Void
  let onConvert: (Outcome) -> Void

  var kind: ConvertKind? {
    let kinds = Set(sources.compactMap { ConvertKind(fileType: $0.fileType) })
    return kinds.count == 1 ? kinds.first : nil
  }

  var category: PresetCategory { kind?.presetCategory ?? .custom }

  /// What every one of these files can become, whatever kinds they are. A CSV
  /// and a picture have nothing in common, and are offered nothing.
  var formats: [OutputFormat] {
    let byKind = Dictionary(grouping: sources) { ConvertKind(fileType: $0.fileType) }
    let offers = byKind.map { kind, files in kind?.outputGroups(for: files).flatMap(\.formats) ?? [] }
    guard let first = offers.first else { return [] }
    return first.filter { format in offers.allSatisfy { $0.contains(format) } }
  }

  /// The one file by name, or how many.
  var title: String {
    sources.count == 1 ? sources[0].fileName : "\(sources.count) \(kind?.plural ?? "files")"
  }
}

/// The maker's top bar when it was opened with files in it.
struct ConversionBar: View {
  let title: String
  /// What the conversion would be called as a preset.
  let suggestedName: String
  /// Why Convert is off, or nil.
  let blocked: String?
  /// Why it cannot be kept either, or nil.
  let unsound: String?
  /// Off while the Preview's big view is up: Esc is its.
  let escGoesBack: Bool
  let back: () -> Void
  let save: (String) -> Void
  let convert: () -> Void

  @State private var naming = false
  @State private var name = ""
  @State private var saved: String?

  var body: some View {
    HStack(spacing: 16) {
      Button("‹ Quick convert", action: back)
        .keyboardShortcut(escGoesBack ? .cancelAction : nil)
        .accessibilityLabel(Text("Back to Quick convert"))
      Spacer()
      VStack(spacing: 4) {
        Text("Convert \(title)").font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
        Text(saved.map { "Saved as “\($0)”." } ?? "This time only. Save it to use it again.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: 440)
      Spacer()
      if let blocked { Text(blocked).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
      Button("Save as Preset…") { name = suggestedName; naming = true }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(unsound != nil)
      Button("Convert", action: convert)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(blocked != nil)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .alert("Save as a preset", isPresented: $naming) {
      TextField("Name", text: $name)
      Button("Save") {
        let kept = name.trimmingCharacters(in: .whitespaces)
        guard !kept.isEmpty else { return }
        save(kept)
        saved = kept
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It shows in Presets and in Quick convert.")
    }
  }
}

/// Between which two things on the canvas a block goes in.
enum InsertPoint {
  /// Before the question at this place in the list.
  case question(Int)
  /// Before this step, at any depth.
  case step(UUID)

  /// The blocks that would land exactly here. Questions come before every
  /// step, so they are offered only where they would end up; the main line's
  /// formats and naming have blocks of their own.
  func offers(for category: PresetCategory, in steps: [Action]) -> [LibraryEntry] {
    LibraryEntry.all(for: category).filter { entry in
      switch (self, entry.kind) {
      case (.question, .question): return true
      case (.question, _), (.step, .template): return false
      case (.step, .step): return true
      case (.step(let id), .question): return steps.first?.id == id
      case (.step(let id), .formats): return !steps.contains { $0.id == id }
      }
    }
  }
}

/// The + on the line between two blocks.
struct InsertButton: View {
  let entries: [LibraryEntry]
  let insert: (LibraryEntry) -> Void

  var body: some View {
    Menu {
      ForEach(LibraryEntry.Group.allCases, id: \.self) { group in
        let inGroup = entries.filter { $0.group == group }
        if !inGroup.isEmpty {
          Section(group.rawValue) {
            ForEach(inGroup) { entry in Button(entry.title) { insert(entry) } }
          }
        }
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)
        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [3])))
        .contentShape(Circle())
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .help("Add a block here")
    .accessibilityLabel(Text("Add a block here"))
  }
}
