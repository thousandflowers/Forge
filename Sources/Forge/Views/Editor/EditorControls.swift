import SwiftUI
import UniformTypeIdentifiers

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
struct EditableSurface: ViewModifier {
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

extension View {
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
struct FormatChips: View {
  let offered: [OutputFormat]
  let chosen: UTType
  let choose: (UTType) -> Void

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
struct LibraryTileButton<Label: View>: View {
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

struct PressableTile: ButtonStyle {
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

/// The coloured square Shortcuts puts in front of an action.
struct BlockIcon: View {
  let symbol: String
  let tint: Color
  var size: CGFloat = 20

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.52, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(RoundedRectangle(cornerRadius: size * 0.28).fill(tint))
  }
}

/// A selectable chip: accent when chosen, grey otherwise.
struct Chip: View {
  let title: String
  let selected: Bool
  let action: () -> Void

  init(_ title: String, selected: Bool, action: @escaping () -> Void) {
    self.title = title
    self.selected = selected
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : Color.secondary.opacity(0.14)))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
}

/// The ⊖ every removable thing shares. The glyph is 14pt; the hit area is
/// not, because a target the size of the glyph is a target people miss.
struct RemoveButton: View {
  let help: String
  let action: () -> Void

  init(_ help: String, action: @escaping () -> Void) {
    self.help = help
    self.action = action
  }

  var body: some View {
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
}

/// The shape every block shares: a coloured icon and a title, its remove
/// button when it has one, and the controls underneath.
struct BlockCard<Content: View>: View {
  let title: String
  let symbol: String
  let tint: Color
  let remove: (() -> Void)?
  @ViewBuilder let content: () -> Content

  init(title: String, symbol: String, tint: Color, remove: (() -> Void)?, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.symbol = symbol
    self.tint = tint
    self.remove = remove
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        BlockIcon(symbol: symbol, tint: tint)
        Text(title).font(.callout.weight(.semibold))
        Spacer()
        if let remove {
          RemoveButton("Remove \(title)", action: remove)
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
}
