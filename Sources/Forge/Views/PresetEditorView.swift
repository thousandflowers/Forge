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
  /// The extensions a custom preset takes. Empty means anything Forge opens.
  @State private var inputFormats: Set<String>
  @State private var choosingFormats = false
  /// Where a dragged block would land: a step's id, or `end`.
  @State private var dropTarget: DropSpot?

  fileprivate enum DropSpot: Equatable {
    case before(UUID)
    case end
  }

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
    _inputFormats = State(initialValue: Set(preset?.inputFormats ?? []))
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
    // A crop on an audio preset would run and change nothing, and a JPEG
    // chosen for images means nothing once the preset is about sound: the
    // blocks that no longer apply come off the canvas where it can be seen.
    .onChange(of: category) { kind in
      steps.removeAll { !$0.kind.suits(kind) }
      let offered = Set(offeredFormats)
      formats.removeAll { !offered.contains($0) }
    }
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

      if let reason = cannotSave {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Button("Save", action: save)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(cannotSave != nil)
        .help(cannotSave ?? "")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  /// Why Save is off, in the words the button shows. `nil` means it is on.
  private var cannotSave: String? {
    if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name" }
    if !keysAreSound { return "Every question needs its own key" }
    let doesSomething = !steps.isEmpty || !formats.isEmpty || !parameters.isEmpty
      || (showsTemplate && !nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty)
    if !doesSomething {
      return showsFormats ? "Pick a format, or add a step" : "Add a block: with none it would only copy the file"
    }
    return nil
  }

  /// Every question has a key, and no two share one: the key is what a name
  /// template spends, and two questions under one key answer as one.
  private var keysAreSound: Bool {
    let keys = parameters.map { $0.key.trimmingCharacters(in: .whitespaces).lowercased() }
    return !keys.contains("") && Set(keys).count == keys.count
  }

  private func keyIsSound(_ parameter: PresetParameter) -> Bool {
    let key = parameter.key.trimmingCharacters(in: .whitespaces).lowercased()
    return !key.isEmpty && parameters.filter { $0.key.trimmingCharacters(in: .whitespaces).lowercased() == key }.count == 1
  }

  // MARK: - Canvas

  /// The chain, top to bottom: what comes in, what is asked, what is done,
  /// what comes out, what it is called. A line runs from each block to the
  /// next, so the canvas reads as the flow it is. Every block is a place to
  /// drop: a library block lands there, a step dragged from elsewhere on the
  /// canvas moves there.
  ///
  /// A plain scroll view, not a List: a List only took drops on rows it
  /// already had, wanted a click to select a row before its fields would
  /// take typing, and drew its own drag previews.
  private var canvas: some View {
    ScrollView {
      VStack(spacing: 0) {
        inputBlock

        ForEach($parameters) { parameter in
          questionRow(parameter)
        }

        ForEach($steps) { step in
          stepRow(step)
        }

        if showsFormats { connected { formatsBlock }.dropSpot(.end, into: self) }
        if showsTemplate { connected { templateBlock }.dropSpot(.end, into: self) }

        connected {
          Text(steps.isEmpty && !showsFormats && parameters.isEmpty
            ? "Drag a block here from the library, or click it. They run top to bottom."
            : "Drop the next block here")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
              RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTarget == .end ? Color.accentColor : Color.secondary.opacity(0.3))
            )
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .dropSpot(.end, into: self)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
    }
    .frame(maxWidth: .infinity)
    // Anywhere else on the canvas: the block goes on the end.
    .onDrop(of: [.text], isTargeted: nil) { providers in
      receive(providers, at: .end)
      return true
    }
  }

  /// A question on the canvas: dropping a step on it puts the step first.
  private func questionRow(_ parameter: Binding<PresetParameter>) -> some View {
    connected { questionBlock(parameter) }
      .dropSpot(steps.first.map { .before($0.id) } ?? .end, into: self)
  }

  /// A step on the canvas: drags to reorder, takes drops in front of itself.
  private func stepRow(_ step: Binding<Action>) -> some View {
    let id = step.wrappedValue.id
    return connected { stepBlock(step) }
      .onDrag { NSItemProvider(object: "step:\(id.uuidString)" as NSString) }
      .dropSpot(.before(id), into: self)
  }

  /// What a drop means, once the payload has been read: a library block to
  /// add at the spot, or a step already on the canvas to move there.
  fileprivate func receive(_ providers: [NSItemProvider], at spot: DropSpot) {
    for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
      provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let payload = object as? String else { return }
        DispatchQueue.main.async { land(payload, at: spot) }
      }
    }
  }

  private func land(_ payload: String, at spot: DropSpot) {
    let index: Int? = {
      if case .before(let id) = spot { return steps.firstIndex { $0.id == id } }
      return nil
    }()
    if payload.hasPrefix("step:"), let moving = steps.firstIndex(where: { $0.id.uuidString == payload.dropFirst(5) }) {
      let step = steps.remove(at: moving)
      var target = index ?? steps.count
      if let index, moving < index { target = index - 1 }
      steps.insert(step, at: min(target, steps.count))
    } else {
      add(id: payload, at: index)
    }
  }

  fileprivate func setDropTarget(_ spot: DropSpot, _ on: Bool) {
    if on { dropTarget = spot } else if dropTarget == spot { dropTarget = nil }
  }

  fileprivate func isDropTarget(_ spot: DropSpot) -> Bool { dropTarget == spot }

  /// A block with the line that leads down to it from the one above.
  private func connected<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2, height: 16)
        Image(systemName: "arrowtriangle.down.fill")
          .font(.system(size: 9))
          .foregroundStyle(Color.secondary.opacity(0.5))
          .offset(y: -3)
      }
      .frame(height: 22)
      .accessibilityHidden(true)
      content()
    }
  }

  /// The files this preset takes. Always first, never removed.
  private var inputBlock: some View {
    block(title: "Files that come in", symbol: category.icon, tint: Color(red: 0.38, green: 0.62, blue: 0.68), remove: nil) {
      HStack(spacing: 10) {
        Picker("Kind", selection: $category) {
          ForEach(PresetCategory.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()

        if category == .custom {
          Button {
            choosingFormats = true
          } label: {
            Label("Choose formats…", systemImage: "line.3.horizontal.decrease.circle")
          }
          // The anchor keeps one width whatever is chosen: a label that grew
          // with the count moved the popover under the pointer at every click.
          .popover(isPresented: $choosingFormats, arrowEdge: .bottom) { formatsPopover }
          Text(inputFormats.isEmpty ? "Any file Forge opens." : "\(inputFormats.count) formats chosen.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else {
          Text("Every \(category.noun) file dropped on Forge, or into a folder it watches, goes through the blocks below.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// Every format Forge reads, by kind, each one a switch.
  private var formatsPopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Formats this preset takes").font(.headline)
        Spacer()
        Button("Any") { inputFormats.removeAll() }
          .disabled(inputFormats.isEmpty)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(InputFormats.groups) { group in
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 6) {
                Image(systemName: group.kind.icon).foregroundStyle(.secondary)
                Text(group.kind.plural.capitalized).font(.callout.weight(.semibold))
                Spacer()
                Button(group.extensions.allSatisfy(inputFormats.contains) ? "None" : "All") {
                  if group.extensions.allSatisfy(inputFormats.contains) {
                    inputFormats.subtract(group.extensions)
                  } else {
                    inputFormats.formUnion(group.extensions)
                  }
                }
                .buttonStyle(.borderless)
                .font(.caption)
              }
              FlowLayout(spacing: 6) {
                ForEach(group.extensions, id: \.self) { ext in
                  chip(ext.uppercased(), selected: inputFormats.contains(ext)) {
                    if inputFormats.contains(ext) { inputFormats.remove(ext) } else { inputFormats.insert(ext) }
                  }
                }
              }
            }
          }
        }
        .padding(.trailing, 8)
      }
      Text(inputFormats.isEmpty ? "None chosen: any file Forge can open goes through." : "\(inputFormats.count) formats chosen.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 520, height: 480)
  }

  /// One thing the preset asks for, and where the answer comes from: a
  /// window once per batch, or the file's own name. Files that say nothing
  /// use the default.
  private func questionBlock(_ parameter: Binding<PresetParameter>) -> some View {
    block(title: "Asks for", symbol: "questionmark.circle", tint: LibraryEntry.Group.ask.color, remove: {
      parameters.removeAll { $0.id == parameter.wrappedValue.id }
    }) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          TextField("Question", text: parameter.label)
          Text("{").foregroundStyle(.tertiary)
          TextField("key", text: parameter.key)
            .frame(width: 80)
            .font(.callout.monospaced())
            .overlay(
              RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.red.opacity(keyIsSound(parameter.wrappedValue) ? 0 : 0.8))
                .padding(-2)
            )
            .help(keyIsSound(parameter.wrappedValue) ? "Spend it in a name template as {\(parameter.wrappedValue.key)}" : "Every question needs its own key")
          Text("}").foregroundStyle(.tertiary)
          Text(parameter.wrappedValue.kind.unit).foregroundStyle(.secondary).frame(width: 26)
        }

        Picker("Answer", selection: parameter.source) {
          ForEach(PresetParameter.Source.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 340)

        HStack(spacing: 10) {
          Text("Default")
            .foregroundStyle(.secondary)
          TextField("Default", text: Binding(
            get: { String(format: "%g", parameter.wrappedValue.defaultValue) },
            set: { text in
              let typed = Double(text.replacingOccurrences(of: ",", with: ".")) ?? parameter.wrappedValue.kind.suggestedDefault
              let range = parameter.wrappedValue.kind.range
              parameter.wrappedValue.defaultValue = min(max(typed, range.lowerBound), range.upperBound)
            }
          ))
          .frame(width: 80)
          Text(parameter.wrappedValue.kind.unit).foregroundStyle(.secondary)
        }

        Text(parameter.wrappedValue.source == .prompt
          ? "A small window asks for it once per batch, before the files run."
          : "Read from the file's own name: \(parameter.wrappedValue.nameExample) says it. A file that says nothing uses the default.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func stepBlock(_ step: Binding<Action>) -> some View {
    block(title: step.wrappedValue.operation.title, symbol: step.wrappedValue.operation.symbol, tint: step.wrappedValue.tint, remove: {
      steps.removeAll { $0.id == step.wrappedValue.id }
    }) {
      ActionRow(action: step)
        .padding(.leading, 22)
    }
  }

  private var formatsBlock: some View {
    block(title: "Comes out as", symbol: "arrow.triangle.2.circlepath", tint: LibraryEntry.Group.output.color, remove: {
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
    block(title: "Names files", symbol: "textformat", tint: LibraryEntry.Group.output.color, remove: {
      nameTemplate = ""
      showsTemplate = false
    }) {
      TemplateField(title: "Names files", template: $nameTemplate, sampleExtension: outputExtension)
    }
  }

  /// The shape every block shares: a coloured icon and a title, its remove
  /// button when it has one, and the controls underneath.
  private func block<Content: View>(title: String, symbol: String, tint: Color, remove: (() -> Void)?, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        blockIcon(symbol, tint: tint)
        Text(title).font(.callout.weight(.semibold))
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
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25)))
  }

  /// The coloured square Shortcuts puts in front of an action.
  private func blockIcon(_ symbol: String, tint: Color, size: CGFloat = 20) -> some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.52, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(RoundedRectangle(cornerRadius: size * 0.28).fill(tint))
  }

  // MARK: - Library

  /// Every block that can be added: click its +, or drag it onto the canvas.
  /// Grouped by what it is for, coloured by group, narrowed by the search.
  private var library: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search blocks", text: $search)
          .textFieldStyle(.plain)
        if !search.isEmpty {
          Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
      }
      .font(.body)
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
      .padding(14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ForEach(LibraryEntry.Group.allCases, id: \.self) { group in
            let entries = offered.filter { $0.group == group }
            if !entries.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                  Circle().fill(group.color).frame(width: 8, height: 8)
                  Text(group.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
                ForEach(entries) { entry in
                  libraryTile(entry)
                }
              }
            }
          }
          if offered.isEmpty {
            Text("No block matches “\(search)”.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.top, 20)
          }
        }
        .padding(14)
      }
    }
    .frame(width: 300)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
  }

  /// One block in the library: coloured icon, name, what it does. The whole
  /// tile is a button, and the whole tile drags onto the canvas.
  private func libraryTile(_ entry: LibraryEntry) -> some View {
    let usable = available(entry)
    return Button {
      add(entry)
    } label: {
      HStack(spacing: 10) {
        blockIcon(entry.symbol, tint: entry.group.color, size: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.title).font(.callout.weight(.medium))
          Text(entry.summary).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Image(systemName: usable ? "plus.circle.fill" : "checkmark.circle")
          .font(.body)
          .foregroundStyle(usable ? entry.group.color : Color.secondary)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(entry.group.color.opacity(0.25)))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .disabled(!usable)
    .opacity(usable ? 1 : 0.45)
    .onDrag { NSItemProvider(object: entry.id as NSString) }
    .help(usable ? "Click, or drag onto the canvas" : "Already on the canvas")
    .accessibilityLabel(Text("Add \(entry.title)"))
  }

  private func add(id: String, at index: Int?) {
    guard let entry = LibraryEntry.all(for: category).first(where: { $0.id == id }), available(entry) else { return }
    if case .step(let kind) = entry.kind, let index {
      steps.insert(Action(kind.blank(for: category)), at: min(index, steps.count))
    } else {
      add(entry)
    }
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
    var key = kind.defaultKey
    var attempt = 2
    while parameters.contains(where: { $0.key == key }) {
      key = "\(kind.defaultKey)\(attempt)"
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
    case .data: return OutputFormat.data
    case .model: return OutputFormat.models
    case .subtitle: return OutputFormat.subtitles + OutputFormat.text
    case .font: return OutputFormat.fonts
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
    preset.inputFormats = category == .custom && !inputFormats.isEmpty ? inputFormats.sorted() : nil

    onSave(preset)
    onClose()
  }
}

private extension View {
  /// Makes a block a place to drop: a library block lands here, a step dragged
  /// from elsewhere moves here. Highlights while something hovers.
  func dropSpot(_ spot: PresetEditorView.DropSpot, into editor: PresetEditorView) -> some View {
    self
      .overlay(alignment: .top) {
        if editor.isDropTarget(spot), spot != .end {
          Rectangle().fill(Color.accentColor).frame(width: 640, height: 3).offset(y: 8)
        }
      }
      .onDrop(of: [.text], isTargeted: Binding(get: { editor.isDropTarget(spot) }, set: { editor.setDropTarget(spot, $0) })) { providers in
        editor.receive(providers, at: spot)
        return true
      }
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

    /// One colour per group, the way Shortcuts colours its actions.
    var color: Color {
      switch self {
      case .output: return Color(red: 0.36, green: 0.53, blue: 0.80)
      case .ask: return Color(red: 0.58, green: 0.48, blue: 0.76)
      case .transform: return Color(red: 0.80, green: 0.58, blue: 0.34)
      case .encode: return Color(red: 0.40, green: 0.64, blue: 0.50)
      case .privacy: return Color(red: 0.78, green: 0.45, blue: 0.53)
      }
    }
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
      return [.image, .video, .document, .custom].contains(category)
    case .encode:
      return [.video, .audio, .custom].contains(category)
    case .privacy:
      // Every kind of file carries something about who made it.
      return true
    }
  }
}

extension Action {
  /// The library kind this step came from, so the library's own rules can
  /// say whether it still applies.
  var kind: ActionKind {
    switch operation {
    case .convertFormat: return .resize  // never in the step list; formats have their own block
    case .resize(_, _, let mode): return mode == .cropCenter ? .crop : .resize
    case .quality: return .quality
    case .filter: return .filter
    case .recognizeText: return .recognizeText
    case .encode: return .encode
    case .limitSize: return .limitSize
    case .stripMetadata: return .privacy
    }
  }

  /// The colour of the group this step is filed under.
  var tint: Color {
    switch operation {
    case .convertFormat: return LibraryEntry.Group.output.color
    case .resize, .filter, .recognizeText: return LibraryEntry.Group.transform.color
    case .quality, .limitSize, .encode: return LibraryEntry.Group.encode.color
    case .stripMetadata: return LibraryEntry.Group.privacy.color
    }
  }

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
