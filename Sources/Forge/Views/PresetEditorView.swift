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
  @State private var nameTrigger: String
  @State private var gate: Condition?
  @State private var choosingFormats = false
  @State private var confirmingDiscard = false
  /// A fork about to be removed with steps in its arms, waiting for a yes.
  @State private var removingFork: UUID?
  @FocusState private var focus: Field?

  private enum Field { case name, description, search }
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
    _nameTrigger = State(initialValue: preset?.nameTrigger ?? "")
    _gate = State(initialValue: preset?.gate)
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
      Button("Cancel") {
        if isDirty { confirmingDiscard = true } else { onClose() }
      }
      .keyboardShortcut(.cancelAction)
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
      Button("Find a block") { focus = .search }
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

  /// Why Save is off, in the words the button shows. `nil` means it is on.
  private var cannotSave: String? {
    if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name" }
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
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      // At least as wide as the canvas, so the chain sits centred when the
      // tree is narrow and scrolls sideways when it is wide.
      .frame(minWidth: proxy.size.width)
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

  /// Whether the main line still goes on after its last step: it does not
  /// when that step is a fork nothing rejoins.
  private var mainLineOpen: Bool {
    guard let last = steps.last else { return true }
    return last.branches.isEmpty
  }

  /// The node where the arms come back to the main line.
  private func joinNode(_ step: Binding<Action>) -> some View {
    connected {
      HStack(spacing: 8) {
        blockIcon("arrow.triangle.merge", tint: LibraryEntry.Group.logic.color)
        VStack(alignment: .leading, spacing: 1) {
          Text("Paths rejoin").font(.callout.weight(.semibold))
          Text("Every copy carries on from here, each still its own file.").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        removeButton("Remove the join") { _ = steps.removeStep(id: step.wrappedValue.id) }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: 640)
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
      connected {
        HStack(spacing: 8) {
          blockIcon(step.wrappedValue.operation.symbol, tint: LibraryEntry.Group.logic.color)
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
          removeButton(isSplit ? "Remove the split; the arms go with it" : "Remove the if; both paths go with it") {
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
          removeButton("Remove this copy") {
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
      Text(empty ? "Drag a block here from the library, or click it. They run top to bottom."
        : root ? "Drop the next block here" : "Drop the next step of this path here")
        .font(root ? .callout : .caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, root ? 14 : 8)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(isDropTarget(.endOf(container)) ? Color.accentColor : Color.secondary.opacity(0.3))
        )
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }
    .dropSpot(.endOf(container), into: self)
  }

  /// A question on the canvas: dropping a step on it puts the step first.
  private func questionRow(_ parameter: Binding<PresetParameter>) -> some View {
    connected { questionBlock(parameter) }
      .dropSpot(steps.first.map { .before($0.id) } ?? .endOf(Self.rootID), into: self)
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
    if payload.hasPrefix("step:"), let id = UUID(uuidString: String(payload.dropFirst(5))) {
      // A fork dropped into one of its own branches would vanish into itself.
      if let moving = steps.step(id), moving.contains(spot.target) { return }
      guard let moving = steps.removeStep(id: id) else { return }
      if !steps.insert(moving, at: spot, root: Self.rootID) { steps.append(moving) }
      keepSplitLast()
      return
    }
    guard let entry = LibraryEntry.all(for: category).first(where: { $0.id == payload }), available(entry) else { return }
    switch entry.kind {
    case .step(let kind):
      let step = Action(kind.blank(for: category))
      if !steps.insert(step, at: spot, root: Self.rootID) { steps.append(step) }
      keepSplitLast()
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

  /// A step after a fork runs on every path, so the join that says so is put
  /// in front of it when nothing does yet - on the main line or in an arm.
  private func keepSplitLast() {
    steps.ensureJoins()
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

  /// The files this preset takes, what starts it, and the test they have to
  /// pass. Always first, never removed.
  private var inputBlock: some View {
    block(title: "Files that come in", symbol: category.icon, tint: .teal, remove: nil) {
      VStack(alignment: .leading, spacing: 10) {
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
            Text("Every \(category.noun) file dropped on Forge, or into a folder it watches.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Divider()

        // Runs when: dropped, or renamed to say so.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("Runs when").foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
          VStack(alignment: .leading, spacing: 6) {
            Text("a file is dropped on Forge, or lands in a folder Forge watches")
              .font(.callout)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
              Text("or a file is renamed with the word").font(.callout)
              Text("_").foregroundStyle(.tertiary)
              TextField("word", text: $nameTrigger)
                .frame(width: 90)
                .font(.callout.monospaced())
                .accessibilityLabel(Text("Trigger word"))
            }
            if !nameTrigger.trimmingCharacters(in: .whitespaces).isEmpty {
              Text("In a watched folder, foto.jpg renamed to foto_\(nameTrigger.trimmingCharacters(in: .whitespaces)).jpg runs this preset, whatever the folder's own preset is. The word is dropped from the output's name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }

        // Only if: a gate on the whole preset.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("Only if").foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
          VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { gate != nil }, set: { gate = $0 ? Condition() : nil })) {
              Text("the file passes a test; otherwise it is left alone")
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            if let current = gate {
              ConditionEditor(condition: Binding(get: { current }, set: { gate = $0 }))
            }
          }
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
    block(title: step.wrappedValue.title, symbol: step.wrappedValue.operation.symbol, tint: step.wrappedValue.tint, remove: {
      _ = steps.removeStep(id: step.wrappedValue.id)
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
          removeButton("Remove \(title)", action: remove)
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

  /// The ⊖ every removable thing shares. The glyph is 14pt; the hit area is
  /// not, because a target the size of the glyph is a target people miss.
  private func removeButton(_ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "minus.circle")
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(Text(help))
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
          .focused($focus, equals: .search)
          .accessibilityLabel(Text("Search blocks"))
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
    return LibraryTileButton(usable: usable) {
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
    .disabled(!usable)
    .opacity(usable ? 1 : 0.45)
    .onDrag { NSItemProvider(object: entry.id as NSString) }
    .help(usable ? "Click, or drag onto the canvas" : "Already on the canvas")
    .accessibilityLabel(Text("Add \(entry.title)"))
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

extension View {
  /// Makes a block a place to drop: a library block lands here, a step dragged
  /// from elsewhere moves here. Highlights while something hovers.
  func dropSpot(_ spot: PresetEditorView.DropSpot, into editor: PresetEditorView) -> some View {
    self
      .overlay(alignment: .top) {
        if editor.isDropTarget(spot), spot.isBefore {
          Rectangle().fill(Color.accentColor).frame(maxWidth: 640).frame(height: 3).offset(y: 8)
        }
      }
      .onDrop(of: [.text], isTargeted: Binding(get: { editor.isDropTarget(spot) }, set: { editor.setDropTarget(spot, $0) })) { providers in
        editor.receive(providers, at: spot)
        return true
      }
  }
}

/// A plain text field with a surface that says it can be typed in: faint at
/// rest, plainer on hover, a ring when it has focus. Plain fields without it
/// read as labels.
private struct EditableSurface: ViewModifier {
  @State private var hovering = false
  @FocusState private var focused: Bool

  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .focused($focused)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(hovering || focused ? 0.14 : 0.07)))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

private extension View {
  func editableSurface() -> some View { modifier(EditableSurface()) }
}

/// A condition, as a row of controls that change with what is being tested.
struct ConditionEditor: View {
  @Binding var condition: Condition

  var body: some View {
    HStack(spacing: 6) {
      Picker("", selection: Binding(
        get: { condition.subject },
        set: { subject in
          condition.subject = subject
          // A comparison the new subject cannot make is swapped for its first.
          if !subject.comparisons.contains(condition.comparison), let first = subject.comparisons.first {
            condition.comparison = first
          }
          if subject == .kind, condition.kind == nil { condition.kind = .image }
        }
      )) {
        ForEach(Condition.Subject.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .labelsHidden()
      .fixedSize()

      if !condition.subject.comparisons.isEmpty {
        Picker("", selection: $condition.comparison) {
          ForEach(condition.subject.comparisons, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
      }

      switch condition.subject {
      case .any:
        Text("every file passes").font(.callout).foregroundStyle(.secondary)
      case .kind:
        Picker("", selection: Binding(get: { condition.kind ?? .image }, set: { condition.kind = $0 })) {
          ForEach(ConvertKind.allCases, id: \.self) { Text($0.plural.capitalized).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
      case .name, .folder, .fileExtension:
        TextField(condition.subject == .fileExtension ? "png" : "text", text: $condition.text)
          .frame(width: 140)
      case .fileSize, .longestSide, .width, .height:
        TextField("Value", text: Binding(
          get: { String(format: "%g", condition.value) },
          set: { condition.value = Double($0.replacingOccurrences(of: ",", with: ".")) ?? condition.value }
        ))
        .frame(width: 80)
        Text(condition.subject.unit).foregroundStyle(.secondary)
      }
    }
  }
}

/// The formats a copy can come out as, one chosen.
private struct FormatChips: View {
  let chosen: UTType
  let choose: (UTType) -> Void

  private var offered: [OutputFormat] {
    OutputFormat.images + OutputFormat.video + OutputFormat.audio + OutputFormat.documents
  }

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(offered) { format in
        if let type = format.type {
          chip(format.label, on: type == chosen) { choose(type) }
        }
      }
    }
  }

  private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label)
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.secondary.opacity(0.14)))
        .foregroundStyle(on ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
  }
}

/// A library tile as a button that lifts a little under the pointer and
/// presses down under the click.
private struct LibraryTileButton<Label: View>: View {
  let usable: Bool
  let action: () -> Void
  @ViewBuilder let label: () -> Label
  @State private var hovering = false

  init(usable: Bool, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
    self.usable = usable
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(action: action) {
      label()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(hovering && usable ? 0.06 : 0)))
    }
    .buttonStyle(PressableTile())
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

private struct PressableTile: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

/// A chain of steps on the canvas, root or branch: every step rendered by the
/// editor, and a drop zone at the end. A separate view so a fork's branches
/// can hold the same thing without the type system chasing its own tail.
struct StepListView: View {
  @Binding var actions: [Action]
  let container: UUID
  let render: (Binding<Action>) -> AnyView
  let endZone: (UUID) -> AnyView

  var body: some View {
    VStack(spacing: 0) {
      ForEach($actions) { render($0) }
      endZone(container)
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
    case logic = "Logic"

    /// One colour per group, the way Shortcuts colours its actions.
    var color: Color {
      switch self {
      // The system's own colours, the ones Shortcuts paints its actions
      // with: alive on the small icon squares, and they follow light and dark.
      case .logic: return .indigo
      case .output: return .blue
      case .ask: return .purple
      case .transform: return .orange
      case .encode: return .green
      case .privacy: return .pink
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
    case .when, .split, .join, .merge: return .logic
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
    case .when: return "One path if the file passes a test, another if not"
    case .split: return "Several copies, each down its own path"
    case .join: return "The copies carry on together, still separate files"
    case .merge: return "The copies become one file, a page each"
    }
  }
}

/// An action with a stable identity, so a list can move it around without the
/// rows swapping their contents underneath the user. A fork carries its
/// branches as trees of the same, so every step everywhere can be dragged.
struct Action: Identifiable, Hashable {
  let id: UUID
  /// The step itself. For a fork the nested chains here are empty: the
  /// branches below hold them, with identities.
  var operation: Operation
  var branches: [ActionBranch]

  init(_ operation: Operation) {
    id = UUID()
    switch operation {
    case .when(let condition, let then, let otherwise):
      self.operation = .when(condition, then: [], otherwise: [])
      branches = [
        ActionBranch(name: "If it passes", actions: then.map(Action.init)),
        ActionBranch(name: "Otherwise", actions: otherwise.map(Action.init)),
      ]
    case .split(let split):
      self.operation = .split([])
      branches = split.map { ActionBranch(name: $0.name, actions: $0.actions.map(Action.init)) }
    default:
      self.operation = operation
      branches = []
    }
  }

  /// The operation with its branches folded back in, as the preset stores it.
  var resolved: Operation {
    switch operation {
    case .when(let condition, _, _):
      return .when(
        condition,
        then: branches.first?.actions.map(\.resolved) ?? [],
        otherwise: branches.dropFirst().first?.actions.map(\.resolved) ?? []
      )
    case .split:
      return .split(branches.map { Branch(name: $0.name, actions: $0.actions.map(\.resolved)) })
    default:
      return operation
    }
  }

  /// What the block is called on the canvas. A split counts its branches
  /// here, where they live, rather than the empty list the operation holds.
  var title: String {
    if case .split = operation { return "Split into \(branches.count) copies" }
    return operation.title
  }

  /// Whether a step with this id is this one or lives somewhere under it.
  func contains(_ other: UUID) -> Bool {
    id == other || branches.contains { $0.id == other || $0.actions.contains { $0.contains(other) } }
  }
}

/// One path out of a fork, on the canvas.
struct ActionBranch: Identifiable, Hashable {
  let id = UUID()
  var name: String
  var actions: [Action]
}

extension Array where Element == Action {
  /// Takes the step with this id out of the tree, wherever it is.
  mutating func removeStep(id: UUID) -> Action? {
    if let index = firstIndex(where: { $0.id == id }) { return remove(at: index) }
    for i in indices {
      for b in self[i].branches.indices {
        if let taken = self[i].branches[b].actions.removeStep(id: id) { return taken }
      }
    }
    return nil
  }

  /// Puts a step where a drop said, anywhere in the tree. False when the spot
  /// is nowhere to be found, which the caller treats as "at the end".
  mutating func insert(_ step: Action, at spot: PresetEditorView.DropSpot, root: UUID) -> Bool {
    switch spot {
    case .before(let id):
      if let index = firstIndex(where: { $0.id == id }) { insert(step, at: index); return true }
    case .endOf(let container):
      if container == root { append(step); return true }
    }
    for i in indices {
      for b in self[i].branches.indices {
        if case .endOf(let container) = spot, container == self[i].branches[b].id {
          self[i].branches[b].actions.append(step)
          return true
        }
        if self[i].branches[b].actions.insert(step, at: spot, root: root) { return true }
      }
    }
    return false
  }

  /// The spot right after a step, wherever it lives: before the next step in
  /// its chain, or the end of that chain when it is the last.
  func spotAfter(_ id: UUID, root: UUID) -> PresetEditorView.DropSpot? {
    if let index = firstIndex(where: { $0.id == id }) {
      return index + 1 < count ? .before(self[index + 1].id) : .endOf(root)
    }
    for action in self {
      for branch in action.branches {
        if let spot = branch.actions.spotAfter(id, root: branch.id) { return spot }
      }
    }
    return nil
  }

  /// The chain a branch holds, found by the branch's id.
  func actions(in container: UUID) -> [Action]? {
    for action in self {
      for branch in action.branches {
        if branch.id == container { return branch.actions }
        if let found = branch.actions.actions(in: container) { return found }
      }
    }
    return nil
  }

  /// A step after a fork, in any chain, gets a join in front of it when
  /// nothing rejoins the arms yet.
  mutating func ensureJoins() {
    if let index = lastIndex(where: { !$0.branches.isEmpty }), index + 1 < count {
      switch self[index + 1].operation {
      case .join, .merge: break
      default: insert(Action(.join), at: index + 1)
      }
    }
    for i in indices {
      for b in self[i].branches.indices { self[i].branches[b].actions.ensureJoins() }
    }
  }

  func step(_ id: UUID) -> Action? {
    for action in self {
      if action.id == id { return action }
      for branch in action.branches { if let found = branch.actions.step(id) { return found } }
    }
    return nil
  }
}

/// The steps that can be added, what each one starts as, and which kinds of
/// file it means anything for.
///
/// The format is not here: what a preset comes out as is its own block at the
/// top, because it is the one thing every preset answers and the one thing that
/// can be answered more than once.
enum ActionKind: String, CaseIterable, Identifiable {
  case crop, resize, quality, limitSize, filter, recognizeText, encode, privacy, when, split, join, merge
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
    case .when: return "If…"
    case .split: return "Split into copies"
    case .join: return "Join the paths"
    case .merge: return "Merge into one file"
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
    case .when: return "arrow.triangle.branch"
    case .split: return "square.split.2x1"
    case .join: return "arrow.triangle.merge"
    case .merge: return "doc.on.doc"
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
    case .when: return .when(Condition(), then: [], otherwise: [])
    case .split: return .split([Branch(name: "Copy 1"), Branch(name: "Copy 2")])
    case .join: return .join
    case .merge: return .merge(.pdf)
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
    case .when, .split, .join, .merge:
      return true
    }
  }
}

extension Action {
  /// The library kind this step came from, so the library's own rules can
  /// say whether it still applies.
  var kind: ActionKind {
    switch operation {
    case .convertFormat: return .resize  // inside an arm it is a step; the top level keeps its block
    case .resize(_, _, let mode): return mode == .cropCenter ? .crop : .resize
    case .quality: return .quality
    case .filter: return .filter
    case .recognizeText: return .recognizeText
    case .encode: return .encode
    case .limitSize: return .limitSize
    case .stripMetadata: return .privacy
    case .when: return .when
    case .split: return .split
    case .join: return .join
    case .merge: return .merge
    }
  }

  /// The colour of the group this step is filed under.
  var tint: Color {
    switch operation {
    case .convertFormat: return LibraryEntry.Group.output.color
    case .resize, .filter, .recognizeText: return LibraryEntry.Group.transform.color
    case .quality, .limitSize, .encode: return LibraryEntry.Group.encode.color
    case .stripMetadata: return LibraryEntry.Group.privacy.color
    case .when, .split, .join, .merge: return LibraryEntry.Group.logic.color
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
    case .convertFormat(let to):
      // At the top level formats have a block of their own; inside an arm a
      // copy picks the one format it comes out as.
      FormatChips(chosen: to) { action.operation = .convertFormat(to: $0) }

    case .join:
      Text("Every copy carries on from here, each still its own file.")
        .font(.callout)
        .foregroundStyle(.secondary)

    case .merge(let kind):
      Picker("", selection: Binding(get: { kind }, set: { action.operation = .merge($0) })) {
        ForEach(MergeKind.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .labelsHidden()
      .frame(maxWidth: 160, alignment: .leading)

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

    case .when, .split:
      EmptyView()

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
