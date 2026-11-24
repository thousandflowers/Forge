import AppKit
import SwiftUI

/// The little menu, beside the pointer, over whatever is on screen. It takes
/// the keyboard without bringing Forge to the front.
@MainActor
final class AskPanel {
  private let panel: KeyPanel
  /// SwiftUI hands the keyboard to the first field a moment after it appears.
  private static let settling: TimeInterval = 0.15

  init(session: AskSession, close: @escaping () -> Void) {
    panel = KeyPanel(
      contentRect: NSRect(x: 0, y: 0, width: AskView.width, height: 200),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: false
    )
    panel.title = "Forge asks"
    panel.hasShadow = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.onEscape = close
    // The controller's preferred size is the window's: it grows and shrinks
    // with what is being asked.
    let host = NSHostingController(rootView: AskView(session: session, close: close))
    host.sizingOptions = [.preferredContentSize]
    panel.contentViewController = host
  }

  func appear() {
    panel.contentViewController?.view.layoutSubtreeIfNeeded()
    let size = panel.contentViewController?.view.fittingSize ?? panel.frame.size
    let mouse = NSEvent.mouseLocation
    let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
    panel.setContentSize(size)
    panel.setFrameOrigin(Self.origin(for: panel.frame.size, at: mouse, in: screen))
    panel.makeKeyAndOrderFront(nil)
    // Not in the field: the numbers are there to be pressed, and in a field
    // they are only typed.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settling) { [panel] in panel.makeFirstResponder(nil) }
  }

  /// Just under the pointer and to its right, and wholly on the screen.
  static func origin(for size: NSSize, at mouse: NSPoint, in screen: NSRect) -> NSPoint {
    let gap: CGFloat = 14
    let x = min(max(mouse.x + gap, screen.minX + gap), screen.maxX - size.width - gap)
    let y = min(max(mouse.y - size.height - gap, screen.minY + gap), screen.maxY - size.height - gap)
    return NSPoint(x: x, y: y)
  }

  func close() { panel.orderOut(nil) }
}

/// A panel that can be typed into, and that Esc closes.
private final class KeyPanel: NSPanel {
  var onEscape: () -> Void = {}
  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) {
    // A key held down would go through every question waiting behind this one.
    guard NSApp.currentEvent?.type != .keyDown || NSApp.currentEvent?.isARepeat == false else { return }
    onEscape()
  }
}

/// What these files should be, in as few presses as it takes.
struct AskView: View {
  static let width: CGFloat = 400
  /// How long a finished one stays up.
  private static let linger: UInt64 = 5_000_000_000
  private static let arming: UInt64 = 800_000_000

  @ObservedObject var session: AskSession
  let close: () -> Void
  @State private var typed: [AskRequest.Question: String] = [:]
  /// Whether the numbers answer yet. The panel comes up over somebody who may
  /// be in the middle of typing one.
  @State private var armed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      switch session.state {
      case .asking: asking
      case .working(let fraction): ProgressView(value: fraction).progressViewStyle(.linear)
      case .done(let outputs): finished(outputs)
      case .failed(let reason):
        Label(reason, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    .task {
      try? await Task.sleep(nanoseconds: Self.arming)
      armed = true
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      PreviewImage(url: session.files[0].url, maxPixels: 120)
        .frame(width: 48, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 1) {
        Text(session.files.count == 1 ? session.files[0].fileName : "\(session.files.count) files")
          .font(.headline).lineLimit(1).truncationMode(.middle)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help("Leave it as it is")
        .accessibilityLabel(Text("Leave it as it is"))
    }
  }

  private var detail: String {
    let size = session.files.reduce(Int64(0)) { $0 + $1.fileSize }.formatted(.byteCount(style: .file))
    guard session.files.count == 1, let shape = session.files[0].dimensions else { return size }
    return "\(size) · \(shape.width) × \(shape.height)"
  }

  // MARK: - Asking

  @ViewBuilder
  private var asking: some View {
    let questions = session.questions
    if questions.isEmpty {
      Text("There is nothing to choose for this kind of file.").font(.callout).foregroundStyle(.secondary)
    }
    ForEach(Array(questions.enumerated()), id: \.element) { index, question in
      if question == .privacy {
        Toggle(question.title, isOn: Binding(
          get: { session.answers[question] == .flag(true) },
          set: { session.choose(.flag($0), for: question) }
        ))
        .toggleStyle(.checkbox)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text(question.title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
          grid(question, numbered: index == 0)
        }
      }
    }
    if !questions.isEmpty, !session.answersAtOnce {
      HStack {
        Spacer()
        Button { go() } label: { Text("Convert").frame(minWidth: 76) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(session.answers.values.allSatisfy { $0 == .flag(false) })
      }
    }
  }

  private func grid(_ question: AskRequest.Question, numbered: Bool) -> some View {
    let choices = session.choices(for: question)
    return VStack(alignment: .leading, spacing: 8) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
          button(choice, for: question, number: numbered && index < 9 ? index + 1 : nil)
        }
      }
      if question.kind != nil {
        TextField("Something else: \(hint(question))", text: Binding(get: { typed[question] ?? "" }, set: { typed[question] = $0 }))
          .textFieldStyle(.roundedBorder)
          .onSubmit { submit(question) }
          .accessibilityLabel(Text("Something else"))
      }
    }
  }

  private func hint(_ question: AskRequest.Question) -> String {
    switch question.kind {
    case .maxFileSize: return "300 KB, 1.5 MB"
    case .width: return "640"
    default: return "70"
    }
  }

  private func button(_ choice: AskOptions.Choice, for question: AskRequest.Question, number: Int?) -> some View {
    let chosen = session.answers[question] == choice.value
    let says = session.measured[choice.value]
    return Button { pick(choice.value, for: question) } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(choice.label).font(.body.weight(.semibold)).lineLimit(1)
          Spacer(minLength: 0)
          if let number {
            Text("\(number)").font(.caption2.weight(.semibold)).foregroundStyle(chosen ? Color.white.opacity(0.8) : .secondary)
          }
        }
        Text(says ?? (choice.isDefault ? "the usual" : " "))
          .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
          .frame(height: 13)
          .foregroundStyle(chosen ? Color.white.opacity(0.85) : .secondary)
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(chosen ? Color.accentColor : Color.primary.opacity(0.07)))
      .foregroundStyle(chosen ? Color.white : Color.primary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(NumberKey(number: armed ? number : nil))
    .accessibilityLabel(Text([choice.label, says].compactMap { $0 }.joined(separator: ", ")))
    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
  }

  private func pick(_ answer: AskRequest.Answer, for question: AskRequest.Question) {
    session.choose(session.answers[question] == answer ? nil : answer, for: question)
    if session.answersAtOnce { go() }
  }

  private func submit(_ question: AskRequest.Question) {
    guard let answer = AskOptions.typed(typed[question] ?? "", for: question) else { NSSound.beep(); return }
    session.choose(answer, for: question)
    if session.answersAtOnce { go() }
  }

  private func go() { session.start() }

  // MARK: - Done

  @ViewBuilder
  private func finished(_ outputs: [URL]) -> some View {
    if outputs.isEmpty {
      Text("Left as it is: its folder is no longer watched.").font(.callout).foregroundStyle(.secondary)
    }
    HStack(spacing: 10) {
      if let first = outputs.first {
        PreviewImage(url: first, maxPixels: 120).frame(width: 48, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
      }
      VStack(alignment: .leading, spacing: 1) {
        if !outputs.isEmpty { Text(outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files").font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
        Text(weight(outputs)).font(.callout).foregroundStyle(.green) }
      }
      Spacer(minLength: 8)
      if !outputs.isEmpty { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs); close() }.controlSize(.small) }
    }
    .task {
      try? await Task.sleep(nanoseconds: Self.linger)
      if !Task.isCancelled { close() }
    }
  }

  private func weight(_ outputs: [URL]) -> String {
    outputs.reduce(Int64(0)) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size]) as? Int64) ?? 0) }
      .formatted(.byteCount(style: .file))
  }
}

/// The first nine choices answer to their number.
private struct NumberKey: ViewModifier {
  let number: Int?

  func body(content: Content) -> some View {
    if let number {
      content.keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
    } else {
      content
    }
  }
}
