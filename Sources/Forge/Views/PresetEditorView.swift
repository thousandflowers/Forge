import SwiftUI
import UniformTypeIdentifiers

/// A request to open the editor: a preset to change, or nil for a new one.
struct PresetEditorRequest: Identifiable {
  let id = UUID()
  let preset: RulePreset?
}

/// The preset editor, laid out the way Shortcuts lays out an automation: the
/// files that come in at the top, the steps they go through stacked under it,
/// and on the right the library of blocks that can be added.
///
/// It takes the whole window. The first block is the input and cannot be
/// removed: a preset with nothing coming in is not a preset.
struct PresetEditorView: View {
  private let existing: RulePreset?
  private let onSave: (RulePreset) -> Void
  private let onClose: () -> Void

  @State private var name: String
  @State private var description: String
  @State private var category: PresetCategory
  /// The formats the files come out as. Kept apart from the steps so the
  /// steps can be reordered by index without the format rows in the way.
  @State private var formats: [OutputFormat]
  @State private var steps: [Action]
  @State private var parameters: [PresetParameter]
  /// Empty means "use the general one from Settings".
  @State private var nameTemplate: String
  @State private var showsFormats: Bool
  @State private var showsTemplate: Bool
  @State private var search = ""

  init(preset: RulePreset?, onSave: @escaping (RulePreset) -> Void, onClose: @escaping () -> Void) {
    self.existing = preset
    self.onSave = onSave
    self.onClose = onClose
    let actions = preset?.actions ?? []
    let chosen = actions.compactMap { action -> OutputFormat? in
      guard case .convertFormat(let to) = action else { return nil }
      return OutputFormat(type: to)
    }
    _name = State(initialValue: preset?.name ?? "")
    _description = State(initialValue: preset?.description ?? "")
    _category = State(initialValue: preset?.category ?? .image)
    _formats = State(initialValue: chosen)
    _steps = State(initialValue: actions.filter { if case .convertFormat = $0 { return false } else { return true } }.map(Action.init))
    _parameters = State(initialValue: preset?.parameters ?? [])
    _nameTemplate = State(initialValue: preset?.nameTemplate ?? "")
    _showsFormats = State(initialValue: !chosen.isEmpty)
    _showsTemplate = State(initialValue: !(preset?.nameTemplate ?? "").isEmpty)
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      Divider()
      HStack(spacing: 0) {
        canvas
        Divider()
        library
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  // MARK: - Top bar

  private var topBar: some View {
    HStack(spacing: 16) {
      Button("Cancel", action: onClose)
        .keyboardShortcut(.cancelAction)

      Spacer()

      VStack(spacing: 2) {
        TextField("Name this preset", text: $name)
          .font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
        TextField("What it does, in a line", text: $description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .textFieldStyle(.plain)
      .frame(maxWidth: 440)

      Spacer()

      Button("Save", action: save)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (steps.isEmpty && formats.isEmpty))
        .help(steps.isEmpty && formats.isEmpty ? "Add a block first: a preset with none would copy the file and call it a conversion." : "")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Canvas

  /// The chain, top to bottom: what comes in, what is asked, what is done,
  /// what comes out, what it is called. Steps can be dragged into order.
  private var canvas: some View {
    List {
      Group {
        inputBlock

        ForEach($parameters) { $parameter in
          questionBlock($parameter)
        }
        .onDelete { parameters.remove(atOffsets: $0) }

        ForEach($steps) { $step in
          stepBlock($step)
        }
        .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
        .onDelete { steps.remove(atOffsets: $0) }

        if showsFormats { formatsBlock }
        if showsTemplate { templateBlock }

        if steps.isEmpty, !showsFormats, parameters.isEmpty {
          Text("Add blocks from the library on the right. They run top to bottom.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
      }
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
  }

  /// The files this preset takes. Always first, never removed.
  private var inputBlock: some View {
    block(title: "Files that come in", symbol: category.icon, remove: nil) {
      HStack(spacing: 10) {
        Picker("Kind", selection: $category) {
          ForEach(PresetCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        Text("Every file of this kind dropped on Forge, or into a folder it watches, goes through the blocks below.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func questionBlock(_ parameter: Binding<PresetParameter>) -> some View {
    block(title: "Asks for", symbol: "questionmark.circle", remove: {
      parameters.removeAll { $0.id == parameter.wrappedValue.id }
    }) {
      HStack(spacing: 8) {
        TextField("Question", text: parameter.label)
        Text("{").foregroundStyle(.tertiary)
        TextField("key", text: parameter.key)
          .frame(width: 80)
          .font(.callout.monospaced())
        Text("}").foregroundStyle(.tertiary)
        Text(parameter.wrappedValue.kind.unit).foregroundStyle(.secondary).frame(width: 26)
      }
    }
  }

  private func stepBlock(_ step: Binding<Action>) -> some View {
    block(title: step.wrappedValue.operation.title, symbol: step.wrappedValue.operation.symbol, remove: {
      steps.removeAll { $0.id == step.wrappedValue.id }
    }) {
      ActionRow(action: step)
        .padding(.leading, 22)
    }
  }

  private var formatsBlock: some View {
    block(title: "Comes out as", symbol: "arrow.triangle.2.circlepath", remove: {
      formats.removeAll()
      showsFormats = false
    }) {
      FlowLayout(spacing: 6) {
        chip("Same format", selected: formats.isEmpty) { formats.removeAll() }
        ForEach(offeredFormats) { format in
          chip(format.label, selected: formats.contains(format)) { toggle(format) }
        }
      }
      if formats.count > 1 {
        Text("\(formats.count) copies of every file, one per format.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var templateBlock: some View {
    block(title: "Names files", symbol: "textformat", remove: {
      nameTemplate = ""
      showsTemplate = false
    }) {
      TemplateField(title: "Names files", template: $nameTemplate, sampleExtension: outputExtension)
    }
  }

  /// The shape every block shares: a titled header, its remove button when
  /// it has one, and the controls underneath.
  private func block<Content: View>(title: String, symbol: String, remove: (() -> Void)?, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(title, systemImage: symbol)
          .font(.callout.weight(.medium))
        Spacer()
        if let remove {
          Button(action: remove) {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .accessibilityLabel(Text("Remove \(title)"))
        }
      }
      content()
    }
    .padding(12)
    .frame(maxWidth: 640, alignment: .leading)
    .frame(maxWidth: .infinity)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
  }

  // MARK: - Library

  /// Every block that can be added, one click each. Grouped by what it is
  /// for, and narrowed by the search field.
  private var library: some View {
    VStack(spacing: 0) {
      TextField("Search blocks", text: $search)
        .textFieldStyle(.roundedBorder)
        .padding(12)
      Divider()
      // A palette, not a list: a List would spend the first click selecting
      // the row and the block would never be added.
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(LibraryEntry.Group.allCases, id: \.self) { group in
            let entries = offered.filter { $0.group == group }
            if !entries.isEmpty {
              VStack(alignment: .leading, spacing: 2) {
                Text(group.rawValue)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 8)
                  .padding(.bottom, 4)
                ForEach(entries) { entry in
                  Button {
                    add(entry)
                  } label: {
                    HStack(spacing: 8) {
                      Image(systemName: entry.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                      VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                        Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                      }
                      Spacer(minLength: 0)
                      Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                  }
                  .buttonStyle(.plain)
                  .disabled(!available(entry))
                  .opacity(available(entry) ? 1 : 0.45)
                  .accessibilityLabel(Text("Add \(entry.title)"))
                }
              }
            }
          }
        }
        .padding(12)
      }
    }
    .frame(width: 280)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
  }

  private var offered: [LibraryEntry] {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    return LibraryEntry.all(for: category).filter {
      needle.isEmpty || $0.title.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)
    }
  }

  /// A block that can only be on the canvas once is offered once.
  private func available(_ entry: LibraryEntry) -> Bool {
    switch entry.kind {
    case .formats: return !showsFormats
    case .template: return !showsTemplate
    case .question, .step: return true
    }
  }

  private func add(_ entry: LibraryEntry) {
    switch entry.kind {
    case .formats: showsFormats = true
    case .template: showsTemplate = true
    case .question(let kind): add(kind)
    case .step(let kind): steps.append(Action(kind.blank(for: category)))
    }
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

  // MARK: - Formats

  private var outputExtension: String {
    formats.compactMap { $0.type.flatMap(FormatCatalog.fileExtension(for:)) }.first ?? "jpeg"
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

  private func toggle(_ format: OutputFormat) {
    if let index = formats.firstIndex(of: format) {
      formats.remove(at: index)
    } else {
      formats.append(format)
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

  // MARK: - Saving

  private func save() {
    var preset = RulePreset(
      id: existing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      description: description,
      category: category,
      actions: formats.compactMap { $0.type.map { Operation.convertFormat(to: $0) } } + steps.map(\.operation)
    )
    preset.parameters = parameters.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
    let template = nameTemplate.trimmingCharacters(in: .whitespaces)
    preset.nameTemplate = showsTemplate && !template.isEmpty ? template : nil

    onSave(preset)
    onClose()
  }
}

/// One entry in the block library.
struct LibraryEntry: Identifiable {
  enum Group: String, CaseIterable {
    case output = "Comes out"
    case ask = "Asks"
    case transform = "Changes"
    case encode = "Encodes"
    case privacy = "Privacy"
  }

  enum Kind {
    case formats
    case template
    case question(PresetParameter.Kind)
    case step(ActionKind)
  }

  let kind: Kind
  let group: Group
  let title: String
  let symbol: String
  let summary: String

  /// Two blocks can share a title - "Quality" is both a question and a step -
  /// so the group is part of the identity.
  var id: String { "\(group.rawValue)/\(title)" }

  /// Everything the library offers for a kind of preset, in the order it is
  /// shown. Built from the same lists the app runs on, so a new step kind
  /// shows up here without a second list to keep in step.
  static func all(for category: PresetCategory) -> [LibraryEntry] {
    var entries: [LibraryEntry] = [
      LibraryEntry(kind: .formats, group: .output, title: "Comes out as", symbol: "arrow.triangle.2.circlepath", summary: "Which formats the files are written in"),
      LibraryEntry(kind: .template, group: .output, title: "Names files", symbol: "textformat", summary: "What the finished files are called"),
    ]
    entries += PresetParameter.Kind.allCases.map {
      LibraryEntry(kind: .question($0), group: .ask, title: $0.title, symbol: "questionmark.circle", summary: "Asked every time the preset runs")
    }
    entries += ActionKind.allCases.filter { $0.suits(category) }.map {
      LibraryEntry(kind: .step($0), group: $0.libraryGroup, title: $0.title, symbol: $0.symbol, summary: $0.summary)
    }
    return entries
  }
}

extension ActionKind {
  var libraryGroup: LibraryEntry.Group {
    switch self {
    case .crop, .resize, .filter, .recognizeText: return .transform
    case .quality, .limitSize, .encode: return .encode
    case .privacy: return .privacy
    }
  }

  var summary: String {
    switch self {
    case .crop: return "Fill a box and cut what does not fit"
    case .resize: return "Fit inside a box, keeping the shape"
    case .quality: return "How much to compress"
    case .limitSize: return "Stay under a size you choose"
    case .filter: return "Grayscale, sepia, blur, sharpen, invert"
    case .recognizeText: return "Read the words in it into text"
    case .encode: return "Which codec writes the file"
    case .privacy: return "What the file stops saying about you"
    }
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
    settings
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
