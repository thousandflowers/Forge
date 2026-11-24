import SwiftUI
import UniformTypeIdentifiers

/// A request to open the editor: a preset to change, or nil for a new one.
struct PresetEditorRequest: Identifiable {
  let id = UUID()
  let preset: RulePreset?
  /// Files to convert once, when it was opened from Quick convert.
  var conversion: EditorConversion? = nil
}

/// The preset editor, laid out the way Shortcuts lays out an automation: the
/// files that come in at the top, the steps they go through stacked under it,
/// and on the right the library of blocks that can be added.
///
/// It takes the whole window. The first block is the input and cannot be
/// removed: a preset with nothing coming in is not a preset.
struct PresetEditorView: View {
  private let existing: RulePreset?
  private let conversion: EditorConversion?
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
  @State private var nameTrigger: String
  @State private var gate: Condition?
  @State private var confirmingDiscard = false
  @State private var destinationMode: DestinationMode
  @State private var destinationURL: URL?
  /// A fork about to be removed with steps in its arms, waiting for a yes.
  @State private var removingFork: UUID?
  @FocusState private var focus: Field?

  private enum Field { case name, description }
  @State private var searchWantsFocus = false
  @EnvironmentObject private var model: AppModel
  /// The original and the step being compared big, from the Preview.
  @State private var compared: Compared?

  struct Compared: Equatable {
    let original: PreviewRunner.Step
    let step: PreviewRunner.Step
  }
  /// Where a dragged block would land: a step's id, or `end`.
  @State private var dropTarget: DropSpot?

  enum DropSpot: Equatable {
    case before(UUID)
    case endOf(UUID)

    /// The step or branch the spot is on, for the no-dropping-into-yourself check.
    var target: UUID {
      switch self {
      case .before(let id), .endOf(let id): return id
      }
    }

    var isBefore: Bool { if case .before = self { return true } else { return false } }
  }

  /// The canvas itself, as a container: the end of the top-level chain.
  private static let rootID = UUID()

  init(
    preset: RulePreset?,
    conversion: EditorConversion? = nil,
    onSave: @escaping (RulePreset) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.existing = preset
    self.conversion = conversion
    _destinationMode = State(initialValue: conversion?.mode ?? .copyTo)
    _destinationURL = State(initialValue: conversion?.destination)
    self.onSave = onSave
    self.onClose = onClose
    let actions = preset?.actions ?? []
    let chosen = actions.compactMap { action -> OutputFormat? in
      guard case .convertFormat(let to) = action else { return nil }
      return OutputFormat(type: to)
    }
    _name = State(initialValue: preset?.name ?? "")
    _description = State(initialValue: preset?.description ?? "")
    _category = State(initialValue: conversion?.category ?? preset?.category ?? .image)
    _formats = State(initialValue: chosen)
    _steps = State(initialValue: actions.filter { if case .convertFormat = $0 { return false } else { return true } }.map(Action.init))
    _parameters = State(initialValue: preset?.parameters ?? [])
    _nameTemplate = State(initialValue: preset?.nameTemplate ?? "")
    _showsFormats = State(initialValue: conversion != nil || !chosen.isEmpty)
    _showsTemplate = State(initialValue: !(preset?.nameTemplate ?? "").isEmpty)
    _inputFormats = State(initialValue: Set(preset?.inputFormats ?? []))
    _nameTrigger = State(initialValue: preset?.nameTrigger ?? "")
    _gate = State(initialValue: preset?.gate)
  }

  var body: some View {
    VStack(spacing: 0) {
      if let conversion { conversionBar(conversion) } else { topBar }
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          canvas
          // The sample file after each step, small; click for the big view.
          PreviewStrip(preset: draft(), coordinator: model.coordinator, own: conversion?.sources.first) { original, step in
            withAnimation(.easeOut(duration: 0.15)) { compared = Compared(original: original, step: step) }
          }
        }
        Divider()
        library
      }
    }
    .overlay {
      if let compared {
        PreviewCompare(original: compared.original, step: compared.step) {
          withAnimation(.easeOut(duration: 0.15)) { self.compared = nil }
        }
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    // A crop on an audio preset would run and change nothing, and a JPEG
    // chosen for images means nothing once the preset is about sound: the
    // blocks that no longer apply come off the canvas where it can be seen.
    .onChange(of: category) { kind in
      steps.removeAll { step in step.kind.map { !$0.suits(kind) } ?? false }
      let offered = Set(offeredFormats)
      formats.removeAll { !offered.contains($0) }
    }
  }

  // MARK: - Top bar

  private var topBar: some View {
    HStack(spacing: 16) {
      Button("Cancel") {
        if isDirty { confirmingDiscard = true } else { onClose() }
      }
      // While the Preview's big view is up, Esc is its: two cancel actions in
      // one window meant Esc closed neither.
      .keyboardShortcut(compared == nil ? .cancelAction : nil)
      .confirmationDialog("Remove this fork and everything in its arms?", isPresented: Binding(get: { removingFork != nil }, set: { if !$0 { removingFork = nil } })) {
        Button("Remove Fork and Arms", role: .destructive) {
          if let id = removingFork { _ = steps.removeStep(id: id) }
          removingFork = nil
        }
        Button("Keep It", role: .cancel) { removingFork = nil }
      } message: {
        Text("The steps inside its arms go with it.")
      }
      .confirmationDialog("Discard the changes to this preset?", isPresented: $confirmingDiscard) {
        Button("Discard Changes", role: .destructive, action: onClose)
        Button("Keep Editing", role: .cancel) {}
      } message: {
        Text("What you changed here has not been saved.")
      }

      Spacer()

      VStack(spacing: 4) {
        TextField("Name this preset", text: $name)
          .font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
          .focused($focus, equals: .name)
          .onSubmit { focus = .description }
          .editableSurface()
          .accessibilityLabel(Text("Preset name"))
        TextField("What it does, in a line", text: $description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .focused($focus, equals: .description)
          .onSubmit { focus = nil }
          .editableSurface()
          .accessibilityLabel(Text("Preset description"))
      }
      .frame(maxWidth: 440)

      Spacer()

      if let reason = cannotSave {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      // ⌘F goes to the library's search; a button nobody sees carries it.
      Button("Find a block") { searchWantsFocus = true }
        .keyboardShortcut("f", modifiers: .command)
        .hidden()
        .frame(width: 0, height: 0)

      // ⌘S, not Return: Return in the name field used to save a preset that
      // was not finished being written.
      Button("Save", action: save)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("s", modifiers: .command)
        .help("Save the preset (⌘S)")
        .disabled(cannotSave != nil)
        .help(cannotSave ?? "")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  /// The top bar with files in the maker: back, keep it, or convert once.
  private func conversionBar(_ conversion: EditorConversion) -> some View {
    let needsFolder = destinationMode != .overwrite && destinationURL == nil
    return ConversionBar(
      title: conversion.title,
      suggestedName: conversion.sources.first.map {
        ProcessingHistory.describedName(for: $0.url, actions: draft().actions)
      } ?? "",
      blocked: unsound ?? (needsFolder ? "Choose a folder to go to" : nil),
      unsound: unsound,
      escGoesBack: compared == nil,
      back: { onClose(); conversion.onBack(outcome) },
      save: { name in
        var preset = draft()
        preset.name = name
        // What the preset it started from said about itself, which this no
        // longer is; and one word cannot start two presets.
        preset.description = ""
        if model.presets.contains(where: { $0.nameTrigger == preset.nameTrigger }) { preset.nameTrigger = nil }
        model.install(preset)
      },
      convert: { onClose(); conversion.onConvert(outcome) }
    )
  }

  private var outcome: EditorConversion.Outcome {
    .init(chain: draft(), mode: destinationMode, destination: destinationURL)
  }

  /// Why Save is off, in the words the button shows. `nil` means it is on.
  private var cannotSave: String? {
    name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give it a name" : unsound
  }

  /// What is wrong with the chain itself, whatever it is called.
  private var unsound: String? {
    if !keysAreSound { return "Every question needs its own key" }
    let hasSplit = steps.contains { if case .split = $0.operation { return true } else { return false } }
    let hasJoinOrMerge = steps.contains { if case .join = $0.operation { return true }; if case .merge = $0.operation { return true }; return false }
    if hasJoinOrMerge && !hasSplit { return "A join or a merge needs a split before it" }
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
    GeometryReader { proxy in
    ScrollView([.vertical, .horizontal]) {
      VStack(spacing: 0) {
        inputBlock

        ForEach($parameters) { parameter in
          questionRow(parameter)
        }

        // With a fork on the main line, what every path shares - the formats,
        // the naming - sits before the fork, where it reads as shared.
        if hasFork {
          if showsFormats { connected { formatsBlock }.dropSpot(steps.first.map { .before($0.id) } ?? .endOf(Self.rootID), into: self) }
          if showsTemplate { connected { templateBlock }.dropSpot(steps.first.map { .before($0.id) } ?? .endOf(Self.rootID), into: self) }
        }

        StepListView(actions: $steps, container: Self.rootID, render: { AnyView(renderStep($0)) }, endZone: { AnyView(renderEnd($0)) })

        if !hasFork {
          if showsFormats { connected { formatsBlock }.dropSpot(.endOf(Self.rootID), into: self) }
          if showsTemplate { connected { templateBlock }.dropSpot(.endOf(Self.rootID), into: self) }
        }

        if let conversion { connected { destinationBlock(conversion) } }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      // At least as wide and as tall as the canvas: centred sideways when the
      // tree is narrow, scrolling when it is wide, and always starting at the
      // top - a two-way scroll view would otherwise float short content in
      // the middle.
      .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .top)
      .animation(.easeOut(duration: 0.2), value: steps)
      .animation(.easeOut(duration: 0.2), value: parameters)
      .animation(.easeOut(duration: 0.2), value: showsFormats)
      .animation(.easeOut(duration: 0.2), value: showsTemplate)
    }
    }
    .frame(maxWidth: .infinity)
    // Anywhere else on the canvas: the block goes on the end.
    .onDrop(of: [.text], isTargeted: nil) { providers in
      receive(providers, at: .endOf(Self.rootID))
      return true
    }
  }

  /// How a step is drawn, at any depth: a fork with its arms, a join node,
  /// or a block.
  @ViewBuilder
  private func renderStep(_ step: Binding<Action>) -> some View {
    if !step.wrappedValue.branches.isEmpty {
      fork(step)
    } else if case .join = step.wrappedValue.operation {
      joinNode(step)
    } else {
      stepRow(step)
    }
  }

  /// The end of a chain, at any depth - unless the chain ends in a fork
  /// nothing rejoins, whose arms have ends of their own.
  @ViewBuilder
  private func renderEnd(_ container: UUID) -> some View {
    let chain = container == Self.rootID ? steps : (steps.actions(in: container) ?? [])
    if chain.last?.branches.isEmpty ?? true {
      endZone(container)
    }
  }

  /// The split on the main line, when there is one. What follows it is the
  /// tail every copy runs, after the arms have done their own work.
  private var trailingSplit: Action? {
    steps.first { if case .split = $0.operation { return true } else { return false } }
  }

  /// Whether the main line forks anywhere.
  private var hasFork: Bool { steps.contains { !$0.branches.isEmpty } }


  /// The node where the arms come back to the main line.
  private func joinNode(_ step: Binding<Action>) -> some View {
    connected {
      HStack(spacing: 8) {
        BlockIcon(symbol: "arrow.triangle.merge", tint: LibraryEntry.Group.logic.color)
        VStack(alignment: .leading, spacing: 1) {
          Text("Paths rejoin").font(.callout.weight(.semibold))
          Text("Every copy carries on from here, each still its own file.").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if case .before = steps.spotAfter(step.wrappedValue.id, root: Self.rootID) ?? .endOf(Self.rootID) {
          RemoveButton("Remove the steps after the join first") {}
            .disabled(true)
        } else {
          RemoveButton("Remove the join") { _ = steps.removeStep(id: step.wrappedValue.id) }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: Metrics.blockColumn)
      .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
      .overlay(Capsule().strokeBorder(LibraryEntry.Group.logic.color.opacity(0.4)))
    }
    .dropSpot(.before(step.wrappedValue.id), into: self)
  }

  /// A fork: the main line runs into a node - a split, or an if with its
  /// test - and from it an arm per path runs on its own, side by side, each
  /// a whole chain with its own end. The arms of an if are the two answers;
  /// a split has as many as there are copies.
  private func fork(_ step: Binding<Action>) -> some View {
    let isSplit: Bool = { if case .split = step.wrappedValue.operation { return true } else { return false } }()
    return VStack(spacing: 0) {
      connected(insertingAt: .step(step.wrappedValue.id)) {
        HStack(spacing: 8) {
          BlockIcon(symbol: step.wrappedValue.operation.symbol, tint: LibraryEntry.Group.logic.color)
          if isSplit {
            Text("Split into \(step.wrappedValue.branches.count) copies")
              .font(.callout.weight(.semibold))
              .monospacedDigit()
          } else if case .when(let condition, let then, let otherwise) = step.wrappedValue.operation {
            Text("If").font(.callout.weight(.semibold))
            ConditionEditor(condition: Binding(
              get: { condition },
              set: { step.wrappedValue.operation = .when($0, then: then, otherwise: otherwise) }
            ))
          }
          RemoveButton(isSplit ? "Remove the split; the arms go with it" : "Remove the if; both paths go with it") {
            // F. Arms with work in them are not thrown away on one click.
            let busy = step.wrappedValue.branches.contains { !$0.actions.isEmpty }
            if busy { removingFork = step.wrappedValue.id } else { _ = steps.removeStep(id: step.wrappedValue.id) }
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(LibraryEntry.Group.logic.color.opacity(0.4)))
      }

      // The bar the arms hang from.
      Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 2)
        .padding(.horizontal, 60)
        .padding(.top, 10)

      // The arms sit centred under the node, each as wide as it needs.
      HStack(alignment: .top, spacing: 16) {
        Spacer(minLength: 0)
        HStack(alignment: .top, spacing: 16) {
          ForEach(step.branches) { branch in
            arm(branch, of: step, renamable: isSplit)
          }
          if isSplit {
            Button {
              step.wrappedValue.branches.append(ActionBranch(name: "Copy \(step.wrappedValue.branches.count + 1)", actions: []))
            } label: {
              VStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.title2)
                Text("Add a copy").font(.caption)
              }
              .foregroundStyle(.secondary)
              .frame(width: 120, height: 90)
              .background(
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                  .foregroundStyle(Color.secondary.opacity(0.3))
              )
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
          }
        }
        Spacer(minLength: 0)
      }
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 8)

      // The arms are their own paths and stay apart. Only a join or a merge
      // the user put after this fork brings them back to one line, and then
      // the bar that says so is drawn.
      if rejoins(after: step.wrappedValue.id) {
        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 2)
          .padding(.horizontal, 60)
          .padding(.top, 6)
      }
    }
  }

  /// Whether a join or a merge follows this fork in the chain it sits in.
  private func rejoins(after id: UUID) -> Bool {
    guard case .before(let nextID) = steps.spotAfter(id, root: Self.rootID), let next = steps.step(nextID) else { return false }
    switch next.operation {
    case .join, .merge: return true
    default: return false
    }
  }

  /// One arm of the fork: its name, its own chain, its own end.
  private func arm(_ branch: Binding<ActionBranch>, of step: Binding<Action>, renamable: Bool) -> some View {
    let nested = branch.wrappedValue.actions.contains { !$0.branches.isEmpty }
    return VStack(spacing: 0) {
      Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2, height: 14)
      HStack(spacing: 6) {
        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).font(.caption)
        if renamable {
          TextField("Name this copy", text: branch.name)
            .font(.callout.weight(.semibold))
            .editableSurface()
            .accessibilityLabel(Text("Name of this copy"))
        } else {
          Text(branch.wrappedValue.name)
            .font(.callout.weight(.semibold))
          Spacer()
        }
        if renamable, step.wrappedValue.branches.count > 2 {
          RemoveButton("Remove this copy") {
            step.wrappedValue.branches.removeAll { $0.id == branch.wrappedValue.id }
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 8).fill(LibraryEntry.Group.logic.color.opacity(0.15)))
      StepListView(actions: branch.actions, container: branch.wrappedValue.id, render: { AnyView(renderStep($0)) }, endZone: { AnyView(renderEnd($0)) })
    }
    .frame(width: nested ? nil : 420)
    .fixedSize(horizontal: nested, vertical: false)
  }

  /// The dashed zone that ends every chain, root or branch: the next block
  /// lands here.
  private func endZone(_ container: UUID) -> some View {
    let root = container == Self.rootID
    let empty = root ? steps.isEmpty && !showsFormats && parameters.isEmpty : false
    return connected {
      // A menu as well as a place to drop. Clicking a block in the library adds
      // it to the end of the preset, so the only way into a path of an If or a
      // Split was to drag: nothing for the keyboard, nothing for VoiceOver.
      Menu {
        ForEach(LibraryEntry.all(for: category).filter(available)) { entry in
          Button(entry.title) { land(entry.id, at: .endOf(container)) }
        }
      } label: {
        Text(empty ? "Drag a block here from the library, or click it. They run top to bottom."
          : root ? "Drop the next block here, or choose one" : "Drop the next step of this path here, or choose one")
          .font(root ? .callout : .caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, root ? 14 : 8)
          .contentShape(Rectangle())
      }
      // Not borderlessButton: that style drops the label's own padding, and the
      // words sat on the dashes.
      .menuStyle(.button).buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityLabel(root ? "Add a block at the end" : "Add a step to this path")
      .background(
        RoundedRectangle(cornerRadius: Metrics.blockRadius, style: .continuous)
          .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
          .foregroundStyle(isDropTarget(.endOf(container)) ? Color.accentColor : Color.secondary.opacity(0.3))
      )
      .frame(maxWidth: Metrics.blockColumn)
      .frame(maxWidth: .infinity)
    }
    .dropSpot(.endOf(container), into: self)
  }

  /// A question on the canvas: dropping a step on it puts the step first.
  private func questionRow(_ parameter: Binding<PresetParameter>) -> some View {
    let index = parameters.firstIndex { $0.id == parameter.wrappedValue.id } ?? 0
    return connected(insertingAt: .question(index)) { questionBlock(parameter) }
      .dropSpot(steps.first.map { .before($0.id) } ?? .endOf(Self.rootID), into: self)
  }

  /// A step on the canvas: drags to reorder, takes drops in front of itself.
  private func stepRow(_ step: Binding<Action>) -> some View {
    let id = step.wrappedValue.id
    return connected(insertingAt: .step(id)) { stepBlock(step) }
      .onDrag { NSItemProvider(object: "step:\(id.uuidString)" as NSString) }
      .dropSpot(.before(id), into: self)
  }

  /// What a drop means, once the payload has been read: a library block to
  /// add at the spot, or a step already on the canvas to move there.
  func receive(_ providers: [NSItemProvider], at spot: DropSpot) {
    for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
      provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let payload = object as? String else { return }
        DispatchQueue.main.async { land(payload, at: spot) }
      }
    }
  }

  private func land(_ payload: String, at spot: DropSpot) {
    if payload.hasPrefix("step:"), let id = UUID(uuidString: String(payload.dropFirst(5))) {
      // A fork dropped into one of its own branches would vanish into itself.
      if let moving = steps.step(id), moving.contains(spot.target) { return }
      guard let moving = steps.removeStep(id: id) else { return }
      if !steps.insert(moving, at: spot, root: Self.rootID) { steps.append(moving) }
      steps.ensureJoins()
      return
    }
    guard let entry = LibraryEntry.all(for: category).first(where: { $0.id == payload }), available(entry) else { return }
    switch entry.kind {
    case .step(let kind):
      land(blank(kind), at: spot)
    case .tool(let kind):
      land(Action(.tool(kind.blank)), at: spot)
    case .formats where spot.target != Self.rootID && !steps.contains(where: { $0.id == spot.target }):
      // Dropped into an arm: that copy gets a format of its own.
      if let type = offeredFormats.first?.type {
        let step = Action(.convertFormat(to: type))
        if !steps.insert(step, at: spot, root: Self.rootID) { add(entry) }
      }
    default:
      add(entry)
    }
  }


  private func land(_ step: Action, at spot: DropSpot) {
    if !steps.insert(step, at: spot, root: Self.rootID) { steps.append(step) }
    steps.ensureJoins()
  }

  func setDropTarget(_ spot: DropSpot, _ on: Bool) {
    if on { dropTarget = spot } else if dropTarget == spot { dropTarget = nil }
  }

  func isDropTarget(_ spot: DropSpot) -> Bool { dropTarget == spot }

  /// A block with the line that leads down to it from the one above, and on
  /// that line the + that puts another block between the two.
  private func connected<Content: View>(insertingAt point: InsertPoint? = nil, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 0) {
      if let point {
        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2, height: 6)
        InsertButton(entries: point.offers(for: category, in: steps)) { insert($0, at: point) }
      }
      VStack(spacing: 0) {
        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2, height: point == nil ? 16 : 6)
        Image(systemName: "arrowtriangle.down.fill")
          .font(.system(size: 9))
          .foregroundStyle(Color.secondary.opacity(0.5))
          .offset(y: -3)
      }
      .frame(height: point == nil ? 22 : 12)
      .accessibilityHidden(true)
      content()
    }
  }

  private var inputBlock: some View {
    InputBlock(
      conversion: conversion, category: $category, inputFormats: $inputFormats,
      nameTrigger: $nameTrigger, gate: $gate
    )
  }

  private func questionBlock(_ parameter: Binding<PresetParameter>) -> some View {
    QuestionBlock(parameter: parameter, keyIsSound: keyIsSound(parameter.wrappedValue)) {
      parameters.removeAll { $0.id == parameter.wrappedValue.id }
    }
  }

  private func stepBlock(_ step: Binding<Action>) -> some View {
    BlockCard(title: step.wrappedValue.title, symbol: step.wrappedValue.operation.symbol, tint: step.wrappedValue.tint, remove: {
      _ = steps.removeStep(id: step.wrappedValue.id)
    }) {
      ActionRow(action: step)
    }
  }

  private var formatsBlock: some View {
    BlockCard(title: "Comes out as", symbol: "arrow.triangle.2.circlepath", tint: LibraryEntry.Group.output.color, remove: conversion != nil ? nil : {
      formats.removeAll()
      showsFormats = false
    }) {
      // A menu on the word, as Shortcuts does, rather than every format at
      // once: the list comes from what this Mac writes, ticked where chosen.
      Menu {
        Button { formats.removeAll() } label: {
          if formats.isEmpty { Label("Same format", systemImage: "checkmark") } else { Text("Same format") }
        }
        Divider()
        ForEach(offeredFormats) { format in
          Button { toggle(format) } label: {
            if formats.contains(format) { Label(format.label, systemImage: "checkmark") } else { Text(format.label) }
          }
        }
      } label: {
        Text(formats.isEmpty ? "the same format" : formats.map(\.label).joined(separator: ", "))
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .accessibilityValue(Text(formats.isEmpty ? "the same format" : formats.map(\.label).joined(separator: ", ")))
      .accessibilityLabel(Text("Comes out as"))
      if formats.count > 1 {
        Text("\(formats.count) copies of every file, one per format.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func destinationBlock(_ conversion: EditorConversion) -> some View {
    BlockCard(title: "Goes to", symbol: "folder", tint: .gray, remove: nil, inline: false) {
      DestinationPicker(mode: $destinationMode, url: $destinationURL, fileCount: conversion.sources.count)
    }
  }

  private var templateBlock: some View {
    BlockCard(title: "Names files", symbol: "textformat", tint: LibraryEntry.Group.output.color, remove: {
      nameTemplate = ""
      showsTemplate = false
    }, inline: false) {
      TemplateField(
        title: "Names files", template: $nameTemplate, sampleExtension: outputExtension,
        sampleWidth: exampleSize.width, sampleHeight: exampleSize.height
      )
    }
  }


  // MARK: - Library

  private var library: some View {
    BlockLibraryView(search: $search, wantsFocus: $searchWantsFocus, entries: offered, available: available, add: add)
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
    case .formats: return !showsFormats || trailingSplit != nil
    case .template: return !showsTemplate
    case .question, .step, .tool: return true
    }
  }

  private func add(_ entry: LibraryEntry) {
    switch entry.kind {
    case .formats: showsFormats = true
    case .template: showsTemplate = true
    case .question(let kind): add(kind)
    case .step(let kind): steps.append(blank(kind))
    case .tool(let kind): steps.append(Action(.tool(kind.blank)))
    }
  }

  /// A new step. While converting, a resize starts the way Settings says new
  /// conversions fit.
  private func blank(_ kind: ActionKind) -> Action {
    var operation = kind.blank(for: category)
    if kind == .resize, let conversion, case .resize(let width, let height, _) = operation {
      operation = .resize(width: width, height: height, fitMode: conversion.fitMode)
    }
    return Action(operation)
  }

  private func insert(_ entry: LibraryEntry, at point: InsertPoint) {
    switch (point, entry.kind) {
    case (.question(let index), .question(let kind)): add(kind, at: index)
    case (.question, _): add(entry)
    case (.step(let id), _): land(entry.id, at: .before(id))
    }
  }

  /// A question needs a key nothing else is using, since the key is what a
  /// name template spends.
  private func add(_ kind: PresetParameter.Kind, at index: Int? = nil) {
    var key = kind.defaultKey
    var attempt = 2
    while parameters.contains(where: { $0.key == key }) {
      key = "\(kind.defaultKey)\(attempt)"
      attempt += 1
    }
    parameters.insert(PresetParameter(key: key, label: kind.title, kind: kind), at: index ?? parameters.count)
  }

  // MARK: - Formats

  /// The size the name example shows: the one this preset resizes to, where
  /// it resizes, keeping the example photograph's shape for a side left out.
  private var exampleSize: (width: Int, height: Int) {
    let photograph = (width: 1920, height: 1080)
    for step in steps {
      guard case .resize(let width, let height, _) = step.operation else { continue }
      switch (width, height) {
      case (let width?, let height?): return (width, height)
      case (let width?, nil): return (width, width * photograph.height / photograph.width)
      case (nil, let height?): return (height * photograph.width / photograph.height, height)
      case (nil, nil): continue
      }
    }
    return photograph
  }

  private var outputExtension: String {
    formats.compactMap { $0.type.flatMap(FormatCatalog.fileExtension(for:)) }.first ?? "jpeg"
  }

  /// The formats worth offering for what this preset is about. An audio preset
  /// has no business listing TIFF.
  private var offeredFormats: [OutputFormat] {
    // With files in hand, what those files can really become.
    if let conversion { return conversion.formats }
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


  // MARK: - Saving

  /// Whether anything differs from what was opened. A new preset with
  /// nothing typed is not dirty; a new preset with a name is.
  private var isDirty: Bool {
    let now = draft()
    guard let existing else {
      return !now.name.isEmpty || !now.description.isEmpty || !now.actions.isEmpty
        || !now.parameters.isEmpty || now.nameTemplate != nil || now.inputFormats != nil || now.nameTrigger != nil || now.gate != nil
    }
    return now.name != existing.name || now.description != existing.description
      || now.category != existing.category || now.actions != existing.actions
      || now.parameters != existing.parameters || now.nameTemplate != existing.nameTemplate
      || now.inputFormats != existing.inputFormats || now.nameTrigger != existing.nameTrigger || now.gate != existing.gate
  }

  /// The preset as it stands on the canvas.
  private func draft() -> RulePreset {
    var preset = RulePreset(
      id: existing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      description: description,
      category: category,
      actions: formats.compactMap { $0.type.map { Operation.convertFormat(to: $0) } } + steps.map(\.resolved)
    )
    preset.parameters = parameters.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
    let template = nameTemplate.trimmingCharacters(in: .whitespaces)
    preset.nameTemplate = showsTemplate && !template.isEmpty ? template : nil
    preset.inputFormats = category == .custom && !inputFormats.isEmpty ? inputFormats.sorted() : nil
    let word = nameTrigger.trimmingCharacters(in: .whitespaces).lowercased()
    preset.nameTrigger = word.isEmpty ? nil : word
    preset.gate = gate
    return preset
  }

  private func save() {
    var preset = draft()
    preset.position = existing?.position ?? 0
    preset.isEnabled = existing?.isEnabled ?? true
    onSave(preset)
    onClose()
  }

}
