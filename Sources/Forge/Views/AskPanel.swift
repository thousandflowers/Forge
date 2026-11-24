import AppKit
import SwiftUI

/// The little menu, beside the pointer, over whatever is on screen. It takes
/// the keyboard without bringing Forge to the front.
@MainActor
final class AskPanel {
  private let panel: KeyPanel
  /// As tall as it can get, so that there is room for it to open where it is.
  private let tallest: () -> CGFloat
  /// SwiftUI hands the keyboard to the first field a moment after it appears.
  private static let settling: TimeInterval = 0.15

  /// - Parameter tiles: where a file being dragged can be dropped.
  init(session: AskSession, tiles: DropTiles? = nil, close: @escaping () -> Void) {
    tallest = {
      NSHostingController(rootView: AskView(session: session, tiles: DropTiles(), isOpen: true, close: {})).view.fittingSize.height
    }
    panel = KeyPanel(
      contentRect: NSRect(x: 0, y: 0, width: AskView.width, height: 200),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: false
    )
    panel.title = "Forge asks"
    panel.hasShadow = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.animationBehavior = .none
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.onEscape = close
    if let tiles {
      panel.takeDrops(on: tiles)
      tiles.openMore = { [weak session] in session?.showsMore = true }
    }
    // The controller's preferred size is the window's: it grows and shrinks
    // with what is being asked.
    let host = NSHostingController(rootView: AskView(session: session, tiles: tiles ?? DropTiles(), close: close))
    host.sizingOptions = [.preferredContentSize]
    panel.contentViewController = host
  }

  /// - Parameter takingKeys: not while the mouse is in the middle of a drag.
  func appear(takingKeys: Bool = true) {
    panel.contentViewController?.view.layoutSubtreeIfNeeded()
    let size = panel.contentViewController?.view.fittingSize ?? panel.frame.size
    let mouse = NSEvent.mouseLocation
    let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
    panel.setContentSize(size)
    let room = NSSize(width: panel.frame.width, height: max(panel.frame.height, tallest()))
    let origin = Self.origin(for: room, at: mouse, in: screen, lead: takingKeys ? nil : Self.lead(of: panel.frame.height))
    panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + room.height - panel.frame.height))
    panel.alphaValue = 0
    fade(to: 1, in: Self.fadeIn)
    guard takingKeys else { return panel.orderFrontRegardless() }
    takeKeys()
  }

  func takeKeys() {
    panel.makeKeyAndOrderFront(nil)
    // Not in the field: the numbers are there to be pressed, and in a field
    // they are only typed.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settling) { [panel] in panel.makeFirstResponder(nil) }
  }

  /// Just under the pointer and to its right, or on its other side where there
  /// is no room, and wholly on the screen. Never over the pointer where that
  /// can be helped: a file let go of there would be dropped on it.
  /// - Parameter lead: how far its top is above the pointer, where it is beside it.
  static func origin(for size: NSSize, at mouse: NSPoint, in screen: NSRect, lead: CGFloat? = nil) -> NSPoint {
    let gap: CGFloat = 14
    let right = mouse.x + gap, left = mouse.x - gap - size.width
    let below = mouse.y + (lead ?? -gap) - size.height
    let x = right + size.width + gap <= screen.maxX || left < screen.minX + gap ? right : left
    return NSPoint(
      x: min(max(x, screen.minX + gap), screen.maxX - size.width - gap),
      y: min(max(below, screen.minY + gap), screen.maxY - size.height - gap)
    )
  }

  /// The middle of the choices is where the file is: none of them is far.
  static func lead(of height: CGFloat) -> CGFloat { (height + AskView.headerHeight) / 2 }

  private func fade(to alpha: CGFloat, in seconds: TimeInterval, then done: @escaping @Sendable () -> Void = {}) {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = seconds
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = alpha
    }, completionHandler: done)
  }

  private static let fadeIn: TimeInterval = 0.1
  private static let fadeOut: TimeInterval = 0.08

  var frame: NSRect { panel.frame }
  func owns(_ window: NSWindow) -> Bool { window === panel }
  var target: any NSDraggingDestination { panel }

  func close() {
    panel.unregisterDraggedTypes()
    panel.ignoresMouseEvents = true
    let panel = panel
    fade(to: 0, in: Self.fadeOut) { Task { @MainActor in panel.orderOut(nil) } }
  }
}

/// A panel that can be typed into, and that Esc closes.
private final class KeyPanel: NSPanel, NSDraggingDestination {
  var onEscape: () -> Void = {}
  override var canBecomeKey: Bool { true }

  /// It grows downwards. Its top is where the eye, and a file being held, is.
  override func setFrame(_ frame: NSRect, display: Bool) {
    var frame = frame
    if frame.height != self.frame.height { frame.origin.y = self.frame.maxY - frame.height }
    super.setFrame(frame, display: display)
  }

  override func cancelOperation(_ sender: Any?) {
    // A key held down would go through every question waiting behind this one.
    guard NSApp.currentEvent?.type != .keyDown || NSApp.currentEvent?.isARepeat == false else { return }
    onEscape()
  }

  // MARK: - A file dropped on it

  private var tiles: DropTiles?

  func takeDrops(on tiles: DropTiles) {
    self.tiles = tiles
    registerForDraggedTypes([.fileURL])
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let tiles, tiles.isLive else { return [] }
    tiles.move(to: fromTheTop(sender.draggingLocation))
    return DropTiles.operation(of: sender.draggingSourceOperationMask)
  }

  func draggingExited(_ sender: NSDraggingInfo?) { tiles?.move(to: nil) }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let tiles else { return false }
    let point = fromTheTop(sender.draggingLocation)
    let tile = tiles.tile(at: point)
    if tile == nil, tiles.isMore(point) { tiles.openMore() }
    tiles.move(to: nil)
    return tiles.drop(tile)
  }

  private func fromTheTop(_ point: NSPoint) -> CGPoint {
    CGPoint(x: point.x, y: (contentView?.bounds.height ?? 0) - point.y)
  }
}

/// What these files should be, in as few presses as it takes.
struct AskView: View {
  static let width: CGFloat = 400
  static let headerHeight: CGFloat = padding + portrait + section
  /// The corners are concentric: what is inside turns with what is outside.
  private static let radius: CGFloat = 22
  private static let padding: CGFloat = 12
  private static let gap: CGFloat = 6
  private static let section: CGFloat = 12
  private static let portrait: CGFloat = 46
  fileprivate static let inset: CGFloat = 10
  /// Two of a row of four are as wide as one of a row of two, so they line up.
  private static let shapes = [4, 2]
  /// A choice with nothing said under it.
  fileprivate static let plain: CGFloat = 34
  private static let weighed: CGFloat = 44
  fileprivate static let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
  /// How long a finished one stays up.
  private static let linger: UInt64 = 5_000_000_000
  private static let bar: CGFloat = 38
  private static let arming: UInt64 = 800_000_000
  private static let quick = Animation.easeOut(duration: 0.12)

  @ObservedObject var session: AskSession
  @ObservedObject var tiles: DropTiles
  /// To be measured, whatever is folded.
  var isOpen = false
  let close: () -> Void
  @Environment(\.accessibilityReduceMotion) private var isStill
  @State private var typed: [AskRequest.Question: String] = [:]
  @State private var hovered: DropTiles.Tile?
  @State private var isOverMore = false
  /// Whether the numbers answer yet. The panel comes up over somebody who may
  /// be in the middle of typing one.
  @State private var armed = false

  var body: some View {
    VStack(alignment: .leading, spacing: Self.section) {
      header
      switch session.state {
      case .asking: asking
      case .working(let fraction): ProgressView(value: fraction).progressViewStyle(.linear).accessibilityLabel(Text("Converting"))
      case .done(let outputs): finished(outputs)
      case .failed(let reason):
        Label(reason, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .task { if NSWorkspace.shared.isVoiceOverEnabled { Self.say(reason) } }
      }
    }
    .onPreferenceChange(DropTileFrames.self) { tiles.frames = $0 }
    .onPreferenceChange(MoreFrame.self) { tiles.more = $0 }
    .padding(Self.padding)
    .frame(width: Self.width, alignment: .leading)
    .background(BehindGlass().overlay(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
    .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    .task {
      try? await Task.sleep(nanoseconds: Self.arming)
      armed = true
    }
  }

  // MARK: - What it is, and what it would be

  private var aimed: DropTiles.Tile? { tiles.over ?? (tiles.isLive ? nil : hovered) }

  private var header: some View {
    HStack(spacing: 11) {
      PreviewImage(url: session.files[0].url, maxPixels: 120)
        .frame(width: Self.portrait, height: Self.portrait)
        .clipShape(RoundedRectangle(cornerRadius: Self.inset, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(session.files.count == 1 ? session.files[0].fileName : "\(session.files.count) files")
          .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        detail.font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1)
      }
      Spacer(minLength: 8)
      // Nothing to press while the button is down.
      if !tiles.isLive {
        Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .help("Leave it as it is")
          .accessibilityLabel(Text("Leave it as it is"))
      }
    }
    .frame(height: Self.portrait)
  }

  /// What it weighs; over a choice, what it would weigh.
  private var detail: Text {
    let now = session.files.reduce(Int64(0)) { $0 + $1.fileSize }
    let size = now.formatted(.byteCount(style: .file))
    if session.files.count == 1, let aimed, let after = session.measured[aimed.answer]?.bytes {
      let heavier = session.isHeavier(after)
      let percent = ResultCard.percent(from: now, to: after).map { "  \($0)" } ?? ""
      return Text("\(size) → ").foregroundColor(.secondary)
        + Text(after.formatted(.byteCount(style: .file))).foregroundColor(heavier ? .heavier : .primary)
        + Text(percent).foregroundColor(.lighter)
    }
    guard session.files.count == 1, let shape = session.files[0].dimensions else { return Text(size) }
    return Text(size) + Text("  \(shape.width) × \(shape.height)").font(.callout).foregroundColor(.secondary)
  }

  // MARK: - Asking

  @ViewBuilder
  private var asking: some View {
    let questions = session.questions
    if questions.isEmpty {
      Text(session.isMixed ? "These are different kinds of file. Take one kind at a time." : "There is nothing to choose for this kind of file.").font(.callout).foregroundStyle(.secondary)
    }
    let folds = session.folds
    ForEach(folds ? questions.filter { !$0.isSecondary } : questions, id: \.self) { section($0) }
    if folds, isOpen || session.showsMore { rest(of: questions) }
    if !questions.isEmpty, !session.answersAtOnce, !tiles.isLive {
      HStack {
        Spacer()
        Button { go() } label: { Text("Convert").frame(minWidth: 76) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(session.answers.values.allSatisfy { $0 == .flag(false) })
      }
    }
    if folds, !isOpen, !session.showsMore { more }
  }

  @ViewBuilder
  private func section(_ question: AskRequest.Question) -> some View {
    if question == .privacy {
      Toggle(question.title, isOn: Binding(
        get: { session.answers[question] == .flag(true) },
        set: { session.choose(.flag($0), for: question) }
      ))
      .toggleStyle(.checkbox)
      .dropTile(.init(question: question, answer: .flag(true)))
    } else {
      VStack(alignment: .leading, spacing: Self.gap) {
        Text(question.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 2)
        grid(question, numbered: question == numbered)
      }
    }
  }

  /// One section after another, each as it makes room for itself.
  private func rest(of questions: [AskRequest.Question]) -> some View {
    let sections = questions.filter { $0.isSecondary && ($0 != .cut || !questions.contains(.tool) && !handsOutCut) }
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(sections.enumerated()), id: \.element) { step, question in
        Unfolding(step: step, isWhole: isOpen || isStill) {
          section(question).padding(.top, step == 0 ? 0 : Self.section)
        }
      }
    }
    // No shorter than what it takes the place of: it grows, and only grows.
    .frame(minHeight: Self.bar - Self.section, alignment: .top)
  }

  /// The whole width of the menu, along the bottom of it.
  private var more: some View {
    Button { session.showsMore = true } label: {
      HStack {
        Text("More…").font(Font(Self.labelFont))
        Spacer()
        Image(systemName: "chevron.down").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
      }
      .padding(.horizontal, Self.padding + Self.inset)
      .frame(width: Self.width, height: Self.bar)
      .background(alignment: .leading) {
        // As long as it takes to open, so that it is seen to be opening.
        Color.accentColor.opacity(0.3)
          .scaleEffect(x: tiles.isResting ? 1 : 0, anchor: .leading)
          .animation(tiles.isResting ? .linear(duration: DropTiles.dwellSeconds) : nil, value: tiles.isResting)
      }
      .background(Color.primary.opacity(isOverMore && !tiles.isLive ? 0.06 : 0))
      .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
      .opacity(tiles.over == nil ? 1 : 0.55)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("What to do to it, how heavy, and what it says about you")
    .onHover { isOverMore = $0 }
    .background(GeometryReader { Color.clear.preference(key: MoreFrame.self, value: $0.frame(in: .global)) })
    .padding([.horizontal, .bottom], -Self.padding)
  }

  /// The numbers go to what stays where it is: what is suggested moves about,
  /// and a key that does something else tomorrow is worse than none.
  private var numbered: AskRequest.Question? { session.questions.first { $0 != .forYou && $0 != .join } }

  /// As many to a row as leave every one of them room for its words.
  static func columns(for labels: [String]) -> Int {
    let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0
    return shapes.first { widest + inset * 2 <= cell(of: $0) } ?? 2
  }

  private static func cell(of columns: Int) -> CGFloat {
    (width - padding * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
  }

  private struct Offer: Identifiable {
    let question: AskRequest.Question
    let choice: AskOptions.Choice
    let number: Int?
    var id: String { "\(question) \(choice.id)" }
  }

  /// Places a last row has to spare.
  static func leftOver(_ count: Int, in columns: Int) -> Int {
    (columns - count % columns) % columns
  }

  /// Whether cutting by hand has a place among the formats, and is not looked for
  /// under what is folded.
  private var handsOutCut: Bool {
    guard session.questions.contains(.cut), session.questions.contains(.format) else { return false }
    let labels = session.choices(for: .format).map(\.label)
    return Self.leftOver(labels.count, in: Self.columns(for: labels)) > 0
  }

  private func grid(_ question: AskRequest.Question, numbered: Bool) -> some View {
    let byNumber = numbered && !tiles.isLive
    // Cutting by hand is one more thing to do to it.
    let byHand = session.questions.contains(.cut) ? session.choices(for: .cut).first : nil
    let joinsTools = question == .tool && !handsOutCut, fillsRow = question == .format && handsOutCut
    let offers = session.choices(for: question).enumerated().map { Offer(question: question, choice: $1, number: byNumber && $0 < 9 ? $0 + 1 : nil) }
      + [joinsTools ? byHand : nil].compactMap { $0 }.map { Offer(question: .cut, choice: $0, number: nil) }
    let columns = Self.columns(for: offers.map(\.choice.label))
    let cell = Self.cell(of: columns)
    let height: CGFloat = session.weighs && question != .join || offers.contains { $0.choice.isDefault } ? Self.weighed : Self.plain
    let rows = stride(from: 0, to: offers.count, by: columns).map { Array(offers[$0..<min($0 + columns, offers.count)]) }
    return VStack(alignment: .leading, spacing: Self.gap) {
      ForEach(rows, id: \.first?.id) { row in
        HStack(spacing: Self.gap) {
          ForEach(row) { offer in button(offer, width: cell, height: height) }
          if fillsRow, let byHand, row.count < columns {
            button(
              Offer(question: .cut, choice: byHand, number: nil),
              width: CGFloat(columns - row.count) * (cell + Self.gap) - Self.gap, height: height
            )
          }
        }
      }
      if question.kind != nil {
        TextField("Something else: \(hint(question))", text: Binding(get: { typed[question] ?? "" }, set: { typed[question] = $0 }))
          .textFieldStyle(.roundedBorder)
          .onSubmit { submit(question) }
          .accessibilityLabel(Text("\(question.title): something else"))
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

  private func button(_ offer: Offer, width: CGFloat, height: CGFloat) -> some View {
    let choice = offer.choice, question = offer.question
    let tile = DropTiles.Tile(question: question, answer: choice.value)
    let isAimed = tiles.over == tile
    let isLit = isAimed || session.answers[question] == choice.value
    let weight = session.measured[choice.value]
    let says = weight?.words(from: session.files.first) ?? (choice.isDefault ? (short: "the usual", full: "the usual") : nil)
    let isHeavier = session.isHeavier(weight?.bytes)
    let isWeighed = height > Self.plain && (question != .cut || says != nil)
    let face = ChoiceFace(
      label: choice.label, says: says, number: offer.number, isLit: isLit, isAimed: isAimed,
      isHeavier: isHeavier, isWeighed: isWeighed, isFaint: !isLit && (tiles.over != nil || weight.map { $0.bytes == nil } ?? false), isHovered: hovered == tile && !tiles.isLive, isCommand: question == .cut,
      isStill: isStill, width: width, height: height
    )
    return Button { pick(choice.value, for: question) } label: { face.animation(isStill ? nil : Self.quick, value: tiles.over) }
    .buttonStyle(.plain)
    .zIndex(isAimed ? 1 : 0)
    .onHover { hovered = $0 ? tile : hovered == tile ? nil : hovered }
    .modifier(NumberKey(number: armed ? offer.number : nil))
    .dropTile(tile)
    .accessibilityLabel(Text(choice.label))
    .accessibilityValue(Text([says?.full, armed ? offer.number.map { "key \($0)" } : nil].compactMap { $0 }.joined(separator: ", ")))
    .accessibilityAddTraits(isLit ? [.isButton, .isSelected] : .isButton)
  }

  private func pick(_ answer: AskRequest.Answer, for question: AskRequest.Question) {
    session.choose(session.answers[question] == answer ? nil : answer, for: question)
    if session.answersAtOnce, answer != .cut { go() }
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
      if !outputs.isEmpty {
        ResultActions(urls: outputs)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs); close() }.controlSize(.small)
      }
    }
    .task {
      // Somebody listening to it is told, and leaves when they have heard.
      guard !NSWorkspace.shared.isVoiceOverEnabled else { return Self.say(outputs.count == 1 ? "Done: \(outputs[0].lastPathComponent)" : "Done: \(outputs.count) files") }
      try? await Task.sleep(nanoseconds: Self.linger)
      if !Task.isCancelled { close() }
    }
  }

  private static func say(_ words: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
      .announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue,
    ])
  }

  private func weight(_ outputs: [URL]) -> String {
    outputs.reduce(Int64(0)) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size]) as? Int64) ?? 0) }
      .formatted(.byteCount(style: .file))
  }
}

/// What one choice looks like.
private struct ChoiceFace: View {
  let label: String
  let says: (short: String, full: String)?
  let number: Int?
  let isLit: Bool
  let isAimed: Bool
  let isHeavier: Bool
  let isWeighed: Bool
  let isFaint: Bool
  let isHovered: Bool
  /// Something done to it, among what it can become.
  let isCommand: Bool
  let isStill: Bool
  let width: CGFloat
  let height: CGFloat

  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AskView.inset, style: .continuous) }
  private var fill: Color { isLit ? .accentColor : Color.primary.opacity(isHovered ? 0.13 : isCommand ? 0 : 0.07) }
  private var weightColor: Color { isLit ? Color.white.opacity(0.9) : isHeavier ? .heavier : .secondary }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        Text(label).font(Font(AskView.labelFont)).lineLimit(1).minimumScaleFactor(0.7)
        Spacer(minLength: 0)
        if let number {
          Text("\(number)").font(.caption2.weight(.semibold)).foregroundColor(isLit ? Color.white.opacity(0.8) : .secondary)
        }
      }
      if isWeighed { weight }
    }
    .padding(.horizontal, AskView.inset)
    .frame(width: width, height: height, alignment: .leading)
    .background(shape.fill(fill))
    .overlay(shape.strokeBorder(Color.primary.opacity(isCommand && !isLit ? 0.16 : 0)))
    .foregroundColor(isLit ? .white : .primary)
    .contentShape(Rectangle())
    .scaleEffect(isAimed && !isStill ? 1.05 : 1)
    .shadow(color: Color.accentColor.opacity(isAimed ? 0.35 : 0), radius: 8, y: 3)
    .opacity(isFaint ? 0.55 : 1)
  }

  private var weight: some View {
    ViewThatFits(in: .horizontal) {
      Text(says?.full ?? " ")
      Text(says?.short ?? " ")
    }
    .font(.caption.monospacedDigit()).lineLimit(1)
    .foregroundColor(weightColor)
  }
}

/// Says where a choice is, for a file held over it. Gathered as one, every
/// time it is drawn: a choice drawn again goes after the new one has come.
private struct DropTileFrames: PreferenceKey {
  static let defaultValue: [DropTiles.Tile: CGRect] = [:]
  static func reduce(value: inout [DropTiles.Tile: CGRect], nextValue: () -> [DropTiles.Tile: CGRect]) {
    value.merge(nextValue()) { $1 }
  }
}

private struct MoreFrame: PreferenceKey {
  static let defaultValue: CGRect? = nil
  static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

private extension View {
  func dropTile(_ tile: DropTiles.Tile) -> some View {
    background(GeometryReader { Color.clear.preference(key: DropTileFrames.self, value: [tile: $0.frame(in: .global)]) })
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

private extension Color {
  /// The system's green and orange are too pale to be read on a light panel.
  static let lighter = Color(nsColor: shade(light: NSColor(red: 0.05, green: 0.45, blue: 0.22, alpha: 1), dark: .systemGreen))
  static let heavier = Color(nsColor: shade(light: NSColor(red: 0.65, green: 0.3, blue: 0, alpha: 1), dark: .systemOrange))

  private static func shade(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
  }
}

/// Something that comes out by itself, from when it is first drawn. What it holds
/// is made once: only how much of it shows is worked out again.
private struct Unfolding<Content: View>: View {
  let step: Int
  let isWhole: Bool
  let content: Content
  @State private var since: Date?
  @State private var isOut = false

  init(step: Int, isWhole: Bool, @ViewBuilder content: () -> Content) {
    self.step = step
    self.isWhole = isWhole
    self.content = content()
  }

  var body: some View {
    TimelineView(.animation(paused: isWhole || isOut)) { time in
      let progress = isWhole || isOut ? 1 : Unfold.progress(after: since.map { time.date.timeIntervalSince($0) } ?? 0, step: step)
      Unfold(progress: progress) { content }
        .opacity(progress)
        .clipped()
    }
    .onAppear { if since == nil { since = Date() } }
    .task {
      try? await Task.sleep(nanoseconds: UInt64((Unfold.length(of: step + 1) + 0.1) * 1_000_000_000))
      isOut = true
    }
  }
}

/// As much of something as has come out, from the top. The room it takes is the
/// room it shows, so what it is in grows with it.
struct Unfold: Layout {
  let progress: Double

  private static let each: TimeInterval = 0.22
  private static let apart: TimeInterval = 0.09

  static func length(of steps: Int) -> TimeInterval { each + apart * Double(max(steps - 1, 0)) }

  /// Fast to begin with, and slow to come to rest.
  static func progress(after elapsed: TimeInterval, step: Int) -> Double {
    let share = min(max((elapsed - apart * Double(step)) / each, 0), 1)
    return 1 - pow(1 - share, 3)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let size = whole(proposal, subviews)
    return CGSize(width: size.width, height: size.height * progress)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let size = whole(proposal, subviews)
    for view in subviews { view.place(at: bounds.origin, proposal: ProposedViewSize(size)) }
  }

  private func whole(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGSize {
    subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
  }
}
