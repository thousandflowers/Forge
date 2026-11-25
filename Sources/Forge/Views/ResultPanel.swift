import AppKit
import SwiftUI

/// The corner the cards come up in. It takes neither the keyboard nor the
/// front: it is there to be seen, and to be used by whoever wants to.
@MainActor
final class ResultPanel {
  private let panel: NSPanel
  private let host: NSHostingController<ResultCards>
  private let center: ResultCenter
  private static let gap: CGFloat = 18
  /// As long as it takes the cards to come down to where they are going.
  private static let settling = 0.8

  init(center: ResultCenter) {
    self.center = center
    let room = Room()
    host = NSHostingController(rootView: ResultCards(center: center, room: room))
    self.room = room
    host.sizingOptions = []
    panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.title = "Forge did this"
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.contentViewController = host
    room.changed = { [weak self] in self?.follow() }
  }

  /// How high the cards stand, as they say themselves.
  @MainActor
  final class Room {
    var changed: () -> Void = {}
    var height: CGFloat = 0 {
      didSet { if height != oldValue { changed() } }
    }
  }

  func appear() {
    guard !panel.isVisible else { return }
    // On one screen for as long as there are cards in it.
    let mouse = NSEvent.mouseLocation
    screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
    place(atLeast: 0)
    panel.orderFrontRegardless()
  }

  /// There are more cards, or fewer: room is made before they move, and taken
  /// away when they have moved.
  func follow() {
    place(atLeast: panel.frame.height)
    // Once, for however many came and went meanwhile.
    settle?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if center.cards.isEmpty { panel.orderOut(nil) } else { place(atLeast: 0) }
    }
    settle = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settling, execute: work)
  }

  private let room: Room
  private var screen: NSRect?
  private var settle: DispatchWorkItem?

  private func place(atLeast height: CGFloat) {
    guard let screen else { return }
    let width = ResultCards.width + Floating.room * 2
    panel.setFrame(
      NSRect(x: screen.maxX - width - Self.gap + Floating.room, y: screen.minY + Self.gap - Floating.room, width: width, height: max(room.height, height, 1)),
      display: true
    )
  }
}

private struct ResultCards: View {
  static let width: CGFloat = 392
  @ObservedObject var center: ResultCenter
  let room: ResultPanel.Room
  @Environment(\.accessibilityReduceMotion) private var isStill

  /// Until the others are out of the way, or the one that goes has gone: two
  /// in one place is neither.
  private static let makingWay = 0.2, going = 0.14

  private var coming: AnyTransition {
    guard !isStill else { return .opacity }
    let slide = AnyTransition.modifier(active: Slide(x: 24, opacity: 0), identity: Slide(x: 0, opacity: 1))
    return .asymmetric(
      insertion: slide.animation(Motion.move.delay(center.cards.count > 1 ? Self.makingWay : 0)),
      removal: slide.animation(.easeOut(duration: Self.going))
    )
  }

  var body: some View {
    // The one that comes is at the bottom, and those before it move up.
    VStack(spacing: 10) {
      ForEach(center.cards) { card in
        ResultCardView(card: card, close: { center.close(card.id) }) { inside in
          if inside { center.held.insert(card.id) } else { center.held.remove(card.id) }
        }
        .transition(coming)
      }
    }
    .animation(isStill ? nil : Motion.move.delay(center.isLeaving ? Self.going : 0), value: center.cards.map(\.id))
    .padding(Floating.room)
    .background(GeometryReader { proxy in
      Color.clear.onAppear { room.height = proxy.size.height }.onChange(of: proxy.size.height) { room.height = $0 }
    })
    .frame(maxHeight: .infinity, alignment: .bottom)
  }
}

/// All of it moves as one: what is drawn in it halfway is where the rest is.
private struct Slide: ViewModifier {
  let x: CGFloat
  let opacity: Double

  func body(content: Content) -> some View { content.modifier(Shift(x: x)).opacity(opacity) }

  private struct Shift: GeometryEffect {
    var x: CGFloat
    var animatableData: CGFloat {
      get { x }
      set { x = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(CGAffineTransform(translationX: x, y: 0)) }
  }
}

private struct ResultCardView: View {
  let card: ResultCard
  let close: () -> Void
  let hover: (Bool) -> Void
  @State private var inside = false
  @State private var isTooLate = false

  var body: some View {
    HStack(spacing: 12) {
      PreviewImage(url: card.file, maxPixels: 160)
        .frame(width: 60, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onDrag { NSItemProvider(object: card.file as NSURL) }
        .help("Drag it anywhere")
      VStack(alignment: .leading, spacing: 2) {
        Text(card.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
        if let note = card.note {
          Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
          HStack(spacing: 6) {
            Text(card.isSomethingElse ? size(card.after) : "\(size(card.before)) → \(size(card.after))").foregroundStyle(.secondary)
            if !card.isSomethingElse, let percent = ResultCard.percent(from: card.before, to: card.after) {
              Text(percent).fontWeight(.semibold).foregroundStyle(Color.lighter)
            }
          }
          .font(.callout).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.75)
        }
      }
      Spacer(minLength: 4)
      ResultActions(urls: [card.file])
      if isTooLate {
        Text("Too late to undo").font(.caption).foregroundStyle(.secondary)
      } else {
        Button("Undo") { if card.undo() { close() } else { isTooLate = true } }.controlSize(.small)
      }
      Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .opacity(inside ? 1 : 0.4)
        .accessibilityLabel(Text("Close"))
    }
    .padding(12)
    .frame(width: ResultCards.width, alignment: .leading)
    .floatingGlass(radius: 18)
    .onHover { inside = $0; hover($0) }
  }

  private func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
}
