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
  /// What this preset asks for instead of deciding.
  @State private var parameters: [PresetParameter]
  /// Empty means "use the general one from Settings".
  @State private var nameTemplate: String

  init(preset: RulePreset?, onSave: @escaping (RulePreset) -> Void) {
    self.existing = preset
    self.onSave = onSave
    _name = State(initialValue: preset?.name ?? "")
    _description = State(initialValue: preset?.description ?? "")
    _category = State(initialValue: preset?.category ?? .image)
    _actions = State(initialValue: (preset?.actions ?? []).map(Action.init))
    _parameters = State(initialValue: preset?.parameters ?? [])
    _nameTemplate = State(initialValue: preset?.nameTemplate ?? "")
  }

  var body: some View {
    VStack(spacing: 0) {
      details
      Divider()
      questions
      Divider()
      actionList
      Divider()
      footer
    }
    .frame(width: 560, height: 700)
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

  /// What the preset asks before it runs, and what it calls what it writes.
  ///
  /// A preset with no questions is a setting: the same thing every time. One
  /// with questions is a shape — "fit under a size you choose" — and the answer
  /// can be spent in the filename.
  private var questions: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Asks for").font(.headline)
        Spacer()
        Menu {
          ForEach(PresetParameter.Kind.allCases, id: \.self) { kind in
            Button(kind.title) { add(kind) }
          }
        } label: {
          Label("Add Question", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }

      if parameters.isEmpty {
        Text("Nothing. This preset does the same thing every time.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach($parameters) { $parameter in
          HStack(spacing: 8) {
            TextField("Question", text: $parameter.label)
            Text("{").foregroundStyle(.tertiary)
            TextField("key", text: $parameter.key)
              .frame(width: 80)
              .font(.callout.monospaced())
            Text("}").foregroundStyle(.tertiary)
            Text(parameter.kind.unit).foregroundStyle(.secondary).frame(width: 26)
            Button {
              parameters.removeAll { $0.id == parameter.id }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove \(parameter.label)"))
          }
        }
      }

      HStack(spacing: 8) {
        Text("Names files").foregroundStyle(.secondary)
        TextField("{name}", text: $nameTemplate)
      }
      .padding(.top, 4)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  /// A question needs a key nothing else is using, since the key is what a
  /// name template spends.
  private func add(_ kind: PresetParameter.Kind) {
    var key = kind.rawValue.lowercased()
    var attempt = 2
    while parameters.contains(where: { $0.key == key }) {
      key = "\(kind.rawValue.lowercased())\(attempt)"
      attempt += 1
    }
    parameters.append(PresetParameter(key: key, label: kind.title, kind: kind))
  }

  @ViewBuilder
  private var actionList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        formatsBlock

        ForEach($actions) { $action in
          if !$action.wrappedValue.isFormat {
            stepBlock($action)
          }
        }

        // The + belongs under the steps, where the next one would go, not in a
        // corner of the window that has nothing to do with the list.
        Menu {
          ForEach(offeredKinds) { kind in
            Button {
              actions.append(Action(kind.blank(for: category)))
            } label: {
              Label(kind.title, systemImage: kind.symbol)
            }
          }
        } label: {
          Label("Add a step", systemImage: "plus")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .menuStyle(.borderlessButton)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(Color.secondary.opacity(0.3))
        )
      }
      .padding(16)
    }
  }

  /// What the files come out as. One or several: picking a second format does
  /// not replace the first, it makes a second copy — which is how one photo
  /// becomes a JPEG for the web and a PNG to keep.
  private var formatsBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Comes out as", systemImage: "arrow.triangle.2.circlepath")
        .font(.callout.weight(.medium))

      FlowLayout(spacing: 6) {
        chip("Same format", selected: chosenFormats.isEmpty) {
          actions.removeAll { $0.isFormat }
        }
        ForEach(offeredFormats) { format in
          chip(format.label, selected: chosenFormats.contains(format)) { toggle(format) }
        }
      }

      if chosenFormats.count > 1 {
        Text("\(chosenFormats.count) copies of every file, one per format.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
  }

  private func stepBlock(_ action: Binding<Action>) -> some View {
    HStack(alignment: .top, spacing: 8) {
      ActionRow(action: action)
      Spacer(minLength: 0)
      Button {
        actions.removeAll { $0.id == action.wrappedValue.id }
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .accessibilityLabel(Text("Remove \(action.wrappedValue.operation.title)"))
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
  }

  private var chosenFormats: [OutputFormat] {
    actions.compactMap { action in
      guard case .convertFormat(let to) = action.operation else { return nil }
      return OutputFormat(type: to)
    }
  }

  /// The formats worth offering for what this preset is about. An audio preset
  /// has no business listing TIFF.
  private var offeredFormats: [OutputFormat] {
    switch category {
    case .image: return OutputFormat.imagesWithTools + OutputFormat.text
    case .video: return OutputFormat.video + OutputFormat.images + OutputFormat.text
    case .audio: return OutputFormat.audio + OutputFormat.text
    case .document: return OutputFormat.documents + OutputFormat.images + OutputFormat.audio
    case .custom:
      return OutputFormat.images + OutputFormat.audio + OutputFormat.video + OutputFormat.documents
    }
  }

  /// The steps that mean something for this kind of file, so an audio preset
  /// is never offered a crop.
  private var offeredKinds: [ActionKind] {
    ActionKind.allCases.filter { $0.suits(category) }
  }

  private func toggle(_ format: OutputFormat) {
    guard let type = format.type else { return }
    if let index = actions.firstIndex(where: {
      if case .convertFormat(let to) = $0.operation { return to == type } else { return false }
    }) {
      actions.remove(at: index)
    } else {
      actions.insert(Action(.convertFormat(to: type)), at: 0)
    }
  }

  private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.accentColor : Color.secondary.opacity(0.14))
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  private var footer: some View {
    HStack {
      Text(actions.isEmpty ? "Does nothing yet" : "Steps run top to bottom")
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") { save() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        // A preset with no steps could be saved, and converting with it copied
        // the file and reported "1 converted" - work that looks like work.
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || actions.isEmpty)
        .help(actions.isEmpty ? "Add a step first: a preset with none would copy the file and call it a conversion." : "")
    }
    .padding()
  }

  private func save() {
    var preset = RulePreset(
      id: existing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      description: description,
      category: category,
      actions: actions.map(\.operation)
    )
    preset.parameters = parameters.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
    let template = nameTemplate.trimmingCharacters(in: .whitespaces)
    preset.nameTemplate = template.isEmpty ? nil : template

    onSave(preset)
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

/// The steps that can be added, what each one starts as, and which kinds of
/// file it means anything for.
///
/// The format is not here: what a preset comes out as is its own block at the
/// top, because it is the one thing every preset answers and the one thing that
/// can be answered more than once.
enum ActionKind: String, CaseIterable, Identifiable {
  case crop, resize, quality, limitSize, filter, recognizeText, encode, privacy
  var id: String { rawValue }

  var title: String {
    switch self {
    case .crop: return "Crop"
    case .resize: return "Resize"
    case .quality: return "Quality"
    case .limitSize: return "Fit within a size"
    case .filter: return "Filter"
    case .recognizeText: return "Read the text"
    case .encode: return "Codec"
    case .privacy: return "Remove metadata"
    }
  }

  var symbol: String {
    switch self {
    case .crop: return "crop"
    case .resize: return "aspectratio"
    case .quality: return "dial.medium"
    case .limitSize: return "arrow.down.right.and.arrow.up.left"
    case .filter: return "camera.filters"
    case .recognizeText: return "text.viewfinder"
    case .encode: return "cpu"
    case .privacy: return "eye.slash"
    }
  }

  /// What the step starts as. A crop starts square and cropping, because a
  /// crop that fits inside is a resize by another name.
  func blank(for category: PresetCategory) -> Operation {
    switch self {
    case .crop: return .resize(width: 1080, height: 1080, fitMode: .cropCenter)
    case .resize: return .resize(width: 1920, height: nil, fitMode: .proportional)
    case .quality: return .quality(level: ImageProcessor.defaultQuality)
    case .limitSize: return .limitSize(bytes: 10_000_000)
    case .filter: return .filter(type: .grayscale)
    case .recognizeText: return .recognizeText(languages: [])
    case .encode:
      let codecs = category == .audio ? Codec.audioCodecs : Codec.videoCodecs
      return .encode(codec: codecs.first ?? .h264)
    case .privacy: return .stripMetadata(policy: .stripAll)
    }
  }

  /// Which kinds of file this step does anything for, taken from what the
  /// processors honour. Offering a crop on an audio preset would be a step
  /// that runs and changes nothing.
  func suits(_ category: PresetCategory) -> Bool {
    switch self {
    case .crop, .resize:
      return [.image, .video, .document, .custom].contains(category)
    case .quality, .filter:
      return [.image, .video, .document, .custom].contains(category)
    case .limitSize:
      return [.image, .custom].contains(category)
    case .recognizeText:
      return category != .audio || category == .custom
    case .encode:
      return [.video, .audio, .custom].contains(category)
    case .privacy:
      // Every kind of file carries something about who made it.
      return true
    }
  }
}

extension Action {
  /// Format steps live in their own block, so the step list skips them.
  var isFormat: Bool {
    if case .convertFormat = operation { return true }
    return false
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
    case .convertFormat:
      // Handled by the block at the top of the editor, which owns every one
      // of them at once.
      EmptyView()

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
          ForEach(ResizeFitMode.allCases, id: \.self) { Text($0.title).tag($0) }
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

    case .stripMetadata(let policy):
      Picker("", selection: Binding(
        get: { policy },
        set: { action.operation = .stripMetadata(policy: $0) }
      )) {
        ForEach(PrivacyPolicy.allCases.filter(\.removesSomething), id: \.self) {
          Text($0.title).tag($0)
        }
      }
      .labelsHidden()
      .frame(maxWidth: 260, alignment: .leading)

    case .limitSize(let bytes):
      HStack(spacing: 6) {
        TextField("Megabytes", text: Binding(
          get: { String(format: "%g", Double(bytes) / 1_000_000) },
          set: { text in
            let megabytes = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
            action.operation = .limitSize(bytes: Int(max(megabytes, 0) * 1_000_000))
          }
        ))
        .frame(width: 80)
        Text("MB").foregroundStyle(.secondary)
      }

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
    // Not `preferredFilenameExtension`: `public.toml` prefers `cfg`, and a
    // menu offering CFG is a menu nobody finds TOML in.
    return FormatCatalog.fileExtension(for: type)?.uppercased() ?? type.identifier
  }

  static let keep = OutputFormat(type: nil)

  static var images: [OutputFormat] { Self.sorted(FormatCatalog.writableImageTypes) }
  static var audio: [OutputFormat] { Self.sorted(Set(FormatCatalog.writableAudioTypes.keys)) }
  static var video: [OutputFormat] { Self.sorted(FormatCatalog.writableVideoTypes) }
  static var documents: [OutputFormat] {
    Self.sorted(Set(DocumentText.writable.keys).union([.pdf]))
  }

  /// The image formats, plus the ones a tool on this Mac adds. Offered only
  /// where an image processor will do the writing: a PDF asked for WebP goes
  /// to the document processor, which has no idea what cwebp is.
  static var imagesWithTools: [OutputFormat] {
    var types = FormatCatalog.writableImageTypes
    if ExternalTools.locate("cwebp") != nil, let webp = UTType("org.webmproject.webp") {
      types.insert(webp)
    }
    return Self.sorted(types)
  }

  /// Words out of a file: OCR for anything with pixels, transcription for
  /// anything with a soundtrack. One format, because both paths write text.
  static var text: [OutputFormat] { [OutputFormat(type: .plainText)] }

  /// The subtitle formats Forge writes. They are named by extension because
  /// macOS has no types for them - `.srt` is not in the type database at all.
  static var subtitles: [OutputFormat] {
    ["srt", "vtt", "sbv"].compactMap { ext in
      UTType(filenameExtension: ext, conformingTo: .plainText).map { OutputFormat(type: $0) }
    }
  }

  /// Fonts, offered only where the tool that writes them is installed, since
  /// CoreText reads a font's tables and cannot write one.
  static var fonts: [OutputFormat] {
    guard ExternalTools.locate("fonttools") != nil else { return [] }
    return ["ttf", "otf", "woff2"].compactMap { ext in
      UTType(filenameExtension: ext, conformingTo: .font).map { OutputFormat(type: $0) }
    }
  }

  /// What `DataProcessor` writes, which is exactly what it reads: it refuses
  /// any other pairing rather than writing something nothing can open.
  static var data: [OutputFormat] { Self.sorted(Set(DataProcessor.readable)) }

  static var models: [OutputFormat] { Self.sorted(FormatCatalog.writableModelTypes) }

  private static func sorted(_ types: Set<UTType>) -> [OutputFormat] {
    types.map { OutputFormat(type: $0) }.sorted { $0.label < $1.label }
  }
}
