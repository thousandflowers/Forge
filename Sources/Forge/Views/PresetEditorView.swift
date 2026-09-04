import SwiftUI
import UniformTypeIdentifiers

/// Builds a preset by stacking actions, the way Shortcuts does.
///
/// The old editor was a form with one slot per idea: one format, one resize,
/// one quality. Order was fixed, a second filter was impossible, and a new kind
/// of action meant a new row nailed to the form. A preset is a list now, and
/// this edits the list.
struct PresetEditorView: View {
  @Environment(\.dismiss) private var dismiss
  private let existing: RulePreset?
  private let onSave: (RulePreset) -> Void

  @State private var name: String
  @State private var description: String
  @State private var category: PresetCategory
  @State private var actions: [Action]
  @State private var selection: Action.ID?

  init(preset: RulePreset?, onSave: @escaping (RulePreset) -> Void) {
    self.existing = preset
    self.onSave = onSave
    _name = State(initialValue: preset?.name ?? "")
    _description = State(initialValue: preset?.description ?? "")
    _category = State(initialValue: preset?.category ?? .image)
    _actions = State(initialValue: (preset?.actions ?? []).map(Action.init))
  }

  var body: some View {
    VStack(spacing: 0) {
      details
      Divider()
      actionList
      Divider()
      footer
    }
    .frame(width: 520, height: 620)
  }

  private var details: some View {
    Form {
      TextField("Name", text: $name)
      TextField("Description", text: $description)
      Picker("Category", selection: $category) {
        ForEach(PresetCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
    }
    .formStyle(.grouped)
    .frame(height: 130)
  }

  @ViewBuilder
  private var actionList: some View {
    if actions.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: "square.stack.3d.up")
          .font(.system(size: 34, weight: .light))
          .foregroundStyle(.secondary)
        Text("No actions yet").font(.headline)
        Text("Add one below. They run top to bottom.")
          .font(.callout).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(selection: $selection) {
        ForEach($actions) { $action in
          ActionRow(action: $action)
            .padding(.vertical, 2)
        }
        .onMove { actions.move(fromOffsets: $0, toOffset: $1) }
        .onDelete { actions.remove(atOffsets: $0) }
      }
      .listStyle(.inset)
    }
  }

  private var footer: some View {
    HStack {
      Menu {
        ForEach(ActionKind.allCases) { kind in
          Button {
            actions.append(Action(kind.blank))
          } label: {
            Label(kind.blank.title, systemImage: kind.blank.symbol)
          }
        }
      } label: {
        Label("Add Action", systemImage: "plus")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      if let selection, let index = actions.firstIndex(where: { $0.id == selection }) {
        Button {
          actions.remove(at: index)
          self.selection = nil
        } label: {
          Label("Remove", systemImage: "minus")
        }
      }

      Spacer()
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") { save() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .padding()
  }

  private func save() {
    onSave(
      RulePreset(
        id: existing?.id ?? UUID(),
        name: name.trimmingCharacters(in: .whitespaces),
        description: description,
        category: category,
        actions: actions.map(\.operation)
      )
    )
    dismiss()
  }
}

/// An action with a stable identity, so a list can move it around without the
/// rows swapping their contents underneath the user.
struct Action: Identifiable, Hashable {
  let id = UUID()
  var operation: Operation

  init(_ operation: Operation) { self.operation = operation }
}

/// The kinds of action that can be added, and a blank of each.
enum ActionKind: String, CaseIterable, Identifiable {
  case convertFormat, resize, quality, filter, recognizeText, encode
  var id: String { rawValue }

  var blank: Operation {
    switch self {
    case .convertFormat: return .convertFormat(to: .jpeg)
    case .resize: return .resize(width: 1280, height: 720, fitMode: .proportional)
    case .quality: return .quality(level: 85)
    case .filter: return .filter(type: .grayscale)
    case .recognizeText: return .recognizeText(languages: [])
    case .encode: return .encode(codec: Codec.available.first ?? .h264)
    }
  }
}

/// One row: what the action is, and the few settings it needs.
private struct ActionRow: View {
  @Binding var action: Action

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(action.operation.title, systemImage: action.operation.symbol)
        .font(.callout.weight(.medium))
      settings
        .padding(.leading, 22)
    }
  }

  @ViewBuilder
  private var settings: some View {
    switch action.operation {
    case .convertFormat(let to):
      Picker("", selection: Binding(
        get: { OutputFormat(type: to) },
        set: { action.operation = .convertFormat(to: $0.type ?? to) }
      )) {
        Section("Images") { ForEach(OutputFormat.images) { Text($0.label).tag($0) } }
        Section("Audio") { ForEach(OutputFormat.audio) { Text($0.label).tag($0) } }
        Section("Video") { ForEach(OutputFormat.video) { Text($0.label).tag($0) } }
        Section("Documents") { ForEach(OutputFormat.documents) { Text($0.label).tag($0) } }
      }
      .labelsHidden()
      .frame(maxWidth: 200, alignment: .leading)

    case .resize(let width, let height, let mode):
      HStack(spacing: 6) {
        numberField("Width", value: width) {
          action.operation = .resize(width: $0, height: height, fitMode: mode)
        }
        Text("×").foregroundStyle(.secondary)
        numberField("Height", value: height) {
          action.operation = .resize(width: width, height: $0, fitMode: mode)
        }
        Picker("", selection: Binding(
          get: { mode },
          set: { action.operation = .resize(width: width, height: height, fitMode: $0) }
        )) {
          ForEach(ResizeFitMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 130)
      }

    case .quality(let level):
      HStack {
        Slider(
          value: Binding(
            get: { Double(level) },
            set: { action.operation = .quality(level: Int($0)) }
          ),
          in: 1...100,
          step: 1
        )
        Text("\(level)").monospacedDigit().frame(width: 32, alignment: .trailing)
      }

    case .filter(let type):
      Picker("", selection: Binding(
        get: { type },
        set: { action.operation = .filter(type: $0) }
      )) {
        ForEach(FilterType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      .labelsHidden()
      .frame(maxWidth: 200, alignment: .leading)

    case .encode(let codec):
      Picker("", selection: Binding(
        get: { codec },
        set: { action.operation = .encode(codec: $0) }
      )) {
        Section("Video") { ForEach(Codec.videoCodecs, id: \.self) { Text($0.title).tag($0) } }
        Section("Audio") { ForEach(Codec.audioCodecs, id: \.self) { Text($0.title).tag($0) } }
      }
      .labelsHidden()
      .frame(maxWidth: 200, alignment: .leading)

    case .recognizeText(let languages):
      Picker("", selection: Binding(
        get: { languages.first ?? "" },
        set: { action.operation = .recognizeText(languages: $0.isEmpty ? [] : [$0]) }
      )) {
        Text("Detect automatically").tag("")
        ForEach(TextRecognizer.supportedLanguages, id: \.self) { Text($0).tag($0) }
      }
      .labelsHidden()
      .frame(maxWidth: 220, alignment: .leading)
    }
  }

  private func numberField(_ label: String, value: Int?, set: @escaping (Int?) -> Void) -> some View {
    TextField(label, text: Binding(
      get: { value.map(String.init) ?? "" },
      set: { set(Int($0.trimmingCharacters(in: .whitespaces))) }
    ))
    .frame(width: 70)
  }
}

/// The output formats offered, taken from what this machine can really write
/// rather than a list typed out by hand.
struct OutputFormat: Identifiable, Hashable {
  /// `nil` means "keep the source format".
  let type: UTType?

  var id: String { type?.identifier ?? "keep" }

  var label: String {
    guard let type else { return "Keep original" }
    return type.preferredFilenameExtension?.uppercased() ?? type.identifier
  }

  static let keep = OutputFormat(type: nil)

  static var images: [OutputFormat] { Self.sorted(FormatCatalog.writableImageTypes) }
  static var audio: [OutputFormat] { Self.sorted(Set(FormatCatalog.writableAudioTypes.keys)) }
  static var video: [OutputFormat] { Self.sorted(FormatCatalog.writableVideoTypes) }
  static var documents: [OutputFormat] {
    Self.sorted(Set(DocumentText.writable.keys).union([.pdf]))
  }

  private static func sorted(_ types: Set<UTType>) -> [OutputFormat] {
    types.map { OutputFormat(type: $0) }.sorted { $0.label < $1.label }
  }
}
