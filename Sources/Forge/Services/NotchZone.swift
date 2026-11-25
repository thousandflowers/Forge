import AppKit
import SwiftUI

/// The notch, as a place to let files go on: it opens while a file is being
/// dragged, and the menu that comes up is the one the drop zone brings up.
///
/// macOS gives other people's apps no way into the Dynamic Island, so this is a
/// panel of Forge's own around whatever the top of the screen leaves out.
@MainActor
final class NotchZone {
  var take: ([URL]) -> Void = { _ in }

  private let find: @MainActor () -> NSRect?
  private let state = NotchState()
  private var panel: NotchPanel?
  private var cutout: NSRect = .zero
  private var drag = 0
  /// The button is up before the drop is delivered.
  private static let grace: TimeInterval = 0.6

  init(find: @escaping @MainActor () -> NSRect? = NotchZone.cutout) { self.find = find }

  var isShown: Bool { panel?.isVisible ?? false }
  var isOpen: Bool { state.isOpen }
  var target: (any NSDraggingDestination)? { panel }

  /// A file is being dragged.
  func began(at mouse: NSPoint) {
    drag += 1
    guard let cutout = find() else { return }
    self.cutout = cutout
    let panel = self.panel ?? make()
    self.panel = panel
    panel.isLive = true
    state.notch = cutout.size
    state.isOver = false
    state.isOpen = false
    panel.setFrame(NotchShape.open(around: cutout), display: true)
    panel.orderFrontRegardless()
    moved(to: mouse)
  }

  func moved(to mouse: NSPoint) {
    let isOpen = NotchShape.isNear(mouse, to: cutout)
    if state.isOpen != isOpen { state.isOpen = isOpen }
  }

  func ended(at mouse: NSPoint) {
    guard let panel, panel.isVisible else { return }
    guard panel.frame.contains(mouse) else { return hide() }
    let this = drag
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) { [weak self] in
      if let self, self.drag == this { self.hide() }
    }
  }

  private func hide() {
    panel?.isLive = false
    state.isOver = false
    state.isOpen = false
    panel?.orderOut(nil)
  }

  private func make() -> NotchPanel {
    let panel = NotchPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.title = "Drop zone"
    // Over the menu bar, which is where the notch is.
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.animationBehavior = .none
    let host = NSHostingView(rootView: NotchView(state: state))
    host.sizingOptions = []
    panel.contentView = host
    panel.registerForDraggedTypes([.fileURL])
    panel.over = { [weak self] in self?.state.isOver = $0 }
    panel.drop = { [weak self] files in
      self?.hide()
      self?.take(files)
    }
    return panel
  }

  /// What the top of the screen that has one leaves out.
  static func cutout() -> NSRect? {
    NSScreen.screens.lazy.compactMap {
      NotchShape.cutout(in: $0.frame, inset: $0.safeAreaInsets.top, left: $0.auxiliaryTopLeftArea, right: $0.auxiliaryTopRightArea)
    }.first
  }
}

/// Where the notch is, and how far around it files are taken.
enum NotchShape {
  static let openSize = NSSize(width: 320, height: 92)
  /// How close a file comes before it opens.
  static let reach: CGFloat = 90

  /// The areas beside it are in the screens' own coordinates. Nothing where
  /// there is no notch, or where macOS says there is room but not where.
  static func cutout(in screen: NSRect, inset: CGFloat, left: NSRect?, right: NSRect?) -> NSRect? {
    guard inset > 0, let left, let right, !left.isEmpty, !right.isEmpty, right.minX > left.maxX else { return nil }
    return NSRect(x: left.maxX, y: screen.maxY - inset, width: right.minX - left.maxX, height: inset)
  }

  /// Hung from the top of the screen, under the notch's middle.
  static func open(around cutout: NSRect) -> NSRect {
    let width = max(openSize.width, cutout.width), height = cutout.height + openSize.height
    return NSRect(x: cutout.midX - width / 2, y: cutout.maxY - height, width: width, height: height)
  }

  /// Wider than what opens, so a file is never over it while it is closed.
  static func isNear(_ mouse: NSPoint, to cutout: NSRect) -> Bool {
    open(around: cutout).insetBy(dx: -reach, dy: -reach).contains(mouse)
  }
}

@MainActor
private final class NotchState: ObservableObject {
  @Published var notch: NSSize = .zero
  @Published var isOpen = false
  @Published var isOver = false
}

private final class NotchPanel: NSPanel, NSDraggingDestination {
  var isLive = false
  var over: (Bool) -> Void = { _ in }
  var drop: ([URL]) -> Void = { _ in }

  /// Left to itself AppKit puts it under the menu bar.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard isLive else { return [] }
    over(true)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    return DropTiles.operation(of: sender.draggingSourceOperationMask)
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    isLive ? DropTiles.operation(of: sender.draggingSourceOperationMask) : []
  }

  func draggingExited(_ sender: NSDraggingInfo?) { over(false) }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let found = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    guard isLive, let files = found as? [URL], !files.isEmpty else { return false }
    drop(files)
    return true
  }
}

private struct NotchView: View {
  @ObservedObject var state: NotchState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Closed, it is a little more than the notch: enough to be noticed.
  private static let lip: CGFloat = 6

  var body: some View {
    let notch = state.notch
    VStack(spacing: 0) {
      ZStack(alignment: .bottom) {
        Hanging(radius: state.isOpen ? 24 : 11).fill(.black)
        if state.isOpen {
          content.frame(height: NotchShape.openSize.height).transition(.opacity)
        }
      }
      .frame(
        width: state.isOpen ? max(NotchShape.openSize.width, notch.width) : notch.width + Self.lip * 2,
        height: state.isOpen ? notch.height + NotchShape.openSize.height : notch.height + Self.lip
      )
      .clipped()
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // What is behind the notch is left out of it.
    .ignoresSafeArea()
    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: state.isOpen)
    .animation(.easeOut(duration: 0.12), value: state.isOver)
  }

  private var content: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.down.doc").font(.system(size: 20, weight: .medium))
      Text("Drop here").font(.callout.weight(.medium))
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(state.isOver ? Color.accentColor : Color.white.opacity(0.1))
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 12)
  }
}

/// Square against the top of the screen, round below.
private struct Hanging: Shape {
  var radius: CGFloat
  var animatableData: CGFloat {
    get { radius }
    set { radius = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let r = min(radius, rect.height / 2, rect.width / 2)
    return Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
      path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
      path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
      path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
      path.closeSubpath()
    }
  }
}
