import AppKit
import Combine
import SwiftUI

/// The notch while Forge works: a little wider, with the hammer on one side of
/// it and how far it has got on the other. Then, below, what was done.
@MainActor
final class NotchSign {
  private let signs: WorkSigns
  private var panel: NSPanel?
  private var watching: AnyCancellable?
  private var leaving: Task<Void, Never>?

  init(_ signs: WorkSigns) { self.signs = signs }

  func follow() {
    guard watching == nil else { return }
    watching = signs.$state.removeDuplicates().sink { [weak self] state in self?.show(state) }
  }

  private func show(_ state: WorkSigns.State) {
    guard state != .resting, let cutout = NotchZone.cutout(), signs.place.showsNotch(hasNotch: true) else { return leave() }
    leaving?.cancel()
    leaving = nil
    if panel?.isVisible == true { return }
    let panel = panel ?? make()
    self.panel = panel
    let size = NotchSignView.size(around: cutout.size)
    panel.contentView = NSHostingView(rootView: NotchSignView(signs: signs, notch: cutout.size))
    panel.setFrame(NSRect(origin: NotchShape.origin(of: size, under: cutout), size: size), display: true)
    panel.orderFrontRegardless()
  }

  /// Once it has gone back into the notch.
  private func leave() {
    guard panel?.isVisible == true, leaving == nil else { return }
    leaving = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(NotchSignView.away * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.panel?.orderOut(nil)
      self?.panel?.contentView = nil
      self?.leaving = nil
    }
  }

  private func make() -> NSPanel {
    let panel = SignPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.title = "Converting"
    panel.hang()
    // Under the menu that comes out of the notch, which says the same and more.
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    return panel
  }

  private final class SignPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    /// Left to itself AppKit puts it under the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
  }
}

struct NotchSignView: View {
  @ObservedObject var signs: WorkSigns
  let notch: NSSize
  @Environment(\.accessibilityReduceMotion) private var isStill
  @State private var isOut = false
  /// What is being shown, kept while it goes back in.
  @State private var shown = WorkSigns.State.working(0)

  /// How long it takes to be gone.
  static let away = 0.45
  private static let ear: CGFloat = 38
  private static let shelf: CGFloat = 46
  private static let widest: CGFloat = 340

  static func size(around notch: NSSize) -> NSSize {
    NSSize(width: max(notch.width + ear * 2, widest) + Hanging.shoulder * 2, height: notch.height + shelf)
  }

  private var word: WorkSigns.Word? { if case .said(let word) = shown { return word } else { return nil } }
  private var fraction: Double { if case .working(let share) = shown { return share } else { return 1 } }

  private var width: CGFloat {
    let shoulders = Hanging.shoulder * 2
    guard isOut || isStill else { return notch.width + shoulders }
    return word == nil ? notch.width + Self.ear * 2 + shoulders : Self.size(around: notch).width
  }

  var body: some View {
    // Not past its own edge, which is where the panel ends: it lost its corners there.
    let spring = Animation.spring(response: 0.36, dampingFraction: 1)
    VStack(spacing: 0) {
      ZStack(alignment: .top) {
        Hanging(radius: word == nil ? 11 : 20).fill(.black)
        VStack(spacing: 0) {
          ears.frame(height: notch.height)
          if let word { says(word).transition(.opacity) }
        }
        .opacity(isOut ? 1 : 0)
      }
      .frame(width: width, height: notch.height + (word != nil && isOut ? Self.shelf : 0))
      .clipped()
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .opacity(isStill && !isOut ? 0 : 1)
    .animation(isStill ? nil : spring, value: isOut)
    .animation(isStill ? nil : spring, value: word)
    .environment(\.colorScheme, .dark)
    .ignoresSafeArea()
    .accessibilityHidden(true)
    .onAppear { take(signs.state) }
    .onReceive(signs.$state) { take($0) }
  }

  private func take(_ state: WorkSigns.State) {
    if state == .resting { isOut = false; return }
    shown = state
    if !isOut { DispatchQueue.main.async { isOut = true } }
  }

  private var ears: some View {
    HStack(spacing: 0) {
      StrikingHammer(isWorking: word == nil && !isStill)
        .frame(width: Self.ear)
      Spacer(minLength: notch.width - 4)
      mark.frame(width: Self.ear)
    }
    .frame(width: notch.width + Self.ear * 2)
  }

  @ViewBuilder private var mark: some View {
    if let word {
      Image(systemName: Self.symbol(for: word.kind))
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Self.color(for: word.kind))
        .transition(isStill ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
    } else {
      Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
        .overlay {
          Circle().trim(from: 0, to: max(0.04, fraction)).stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(isStill ? nil : .easeOut(duration: 0.25), value: fraction)
        }
        .frame(width: 14, height: 14)
    }
  }

  private func says(_ word: WorkSigns.Word) -> some View {
    VStack(spacing: 1) {
      Text(word.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
      Text(word.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
    }
    .lineLimit(1)
    .truncationMode(.middle)
    .padding(.horizontal, 18)
    .frame(maxWidth: .infinity)
    .frame(height: Self.shelf, alignment: .center)
  }

  static func symbol(for kind: WorkSigns.Word.Kind) -> String {
    switch kind {
    case .done: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    case .leftAlone: return "minus.circle.fill"
    }
  }

  private static func color(for kind: WorkSigns.Word.Kind) -> Color {
    switch kind {
    case .done: return .green
    case .failed: return .red
    case .leftAlone: return .white.opacity(0.7)
    }
  }
}

/// The hammer, and what flies off where it strikes.
private struct StrikingHammer: View {
  let isWorking: Bool
  @State private var start = Date()

  var body: some View {
    TimelineView(.animation(paused: !isWorking)) { timeline in
      let time = isWorking ? timeline.date.timeIntervalSince(start) : 0
      ZStack {
        Image(systemName: "hammer.fill")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.white)
          .rotationEffect(.degrees(-Blow.angle(at: time)), anchor: UnitPoint(x: 0.12, y: 0.9))
        if isWorking, let flown = Blow.sparks(at: time) {
          ForEach([75.0, 35, -5], id: \.self) { angle in
            Capsule().fill(Color.orange)
              .frame(width: 2.6 * (1 - flown) + 0.8, height: 1.4)
              .offset(x: 3 + flown * 4)
              .rotationEffect(.degrees(-angle))
              .offset(x: 9, y: 4)
              .opacity(1 - flown)
          }
        }
      }
    }
  }
}
