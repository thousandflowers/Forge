import AppKit
import SwiftUI

/// The notch, as a place to take files: it stands out a little while a file is
/// being dragged, and the menu comes out of it when the file comes near.
///
/// macOS gives other people's apps no way into the Dynamic Island, so this is a
/// panel of Forge's own around whatever the top of the screen leaves out.
@MainActor
final class NotchZone {
  /// Files let go of on it before the menu was out.
  var take: ([URL]) -> Void = { _ in }
  /// What the top of the screen leaves out, for the drag that is going on.
  private(set) var cutout: NSRect?

  private let find: @MainActor () -> NSRect?
  private var panel: NotchPanel?
  private var drag = 0
  /// The button is up before the drop is delivered.
  private static let grace: TimeInterval = 0.6

  init(find: @escaping @MainActor () -> NSRect? = NotchZone.cutout) { self.find = find }

  var isShown: Bool { panel?.isVisible ?? false }
  var target: (any NSDraggingDestination)? { panel }
  func here() -> NSRect? { find() }

  /// A file is being dragged.
  func began() {
    drag += 1
    cutout = find()
    stand()
  }

  /// With no menu out of it.
  func stand() {
    guard let cutout else { return }
    let panel = self.panel ?? make()
    self.panel = panel
    panel.isLive = true
    panel.setFrame(NotchShape.lip(around: cutout), display: true)
    panel.orderFrontRegardless()
  }

  func hide() {
    panel?.isLive = false
    panel?.orderOut(nil)
  }

  func ended(at mouse: NSPoint) {
    guard let panel, panel.isVisible else { return }
    guard panel.frame.contains(mouse) else { return hide() }
    let this = drag
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) { [weak self] in
      if let self, self.drag == this { self.hide() }
    }
  }

  private func make() -> NotchPanel {
    let panel = NotchPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.title = "Drop zone"
    panel.hang()
    panel.contentView = NSHostingView(rootView: Hanging(radius: 11).fill(.black).ignoresSafeArea())
    panel.registerForDraggedTypes([.fileURL])
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

/// Where the notch is, and how far around it a file is near.
enum NotchShape {
  /// How much more than the notch is seen, so as to be noticed.
  private static let edge: CGFloat = 6
  private static let nearX: CGFloat = 70
  private static let nearY: CGFloat = 50
  /// A hand on its way to a choice strays.
  private static let stray: CGFloat = 40

  /// The areas beside it are in the screens' own coordinates. Nothing where
  /// there is no notch, or where macOS says there is room but not where.
  static func cutout(in screen: NSRect, inset: CGFloat, left: NSRect?, right: NSRect?) -> NSRect? {
    guard inset > 0, let left, let right, !left.isEmpty, !right.isEmpty, right.minX > left.maxX else { return nil }
    return NSRect(x: left.maxX, y: screen.maxY - inset, width: right.minX - left.maxX, height: inset)
  }

  static func lip(around cutout: NSRect) -> NSRect {
    NSRect(x: cutout.minX - edge, y: cutout.minY - edge, width: cutout.width + edge * 2, height: cutout.height + edge)
  }

  /// Hung from the top of the screen, under the notch's middle.
  static func origin(of size: NSSize, under cutout: NSRect) -> NSPoint {
    NSPoint(x: cutout.midX - size.width / 2, y: cutout.maxY - size.height)
  }

  static func isNear(_ mouse: NSPoint, to cutout: NSRect) -> Bool {
    cutout.insetBy(dx: -nearX, dy: -nearY).contains(mouse)
  }

  /// Further than it takes to bring it out, so that it does not flicker.
  static func keeps(_ mouse: NSPoint, near cutout: NSRect, menu: NSRect?) -> Bool {
    isNear(mouse, to: cutout) || (menu?.insetBy(dx: -stray, dy: -stray).contains(mouse) ?? false)
  }
}

extension NSPanel {
  /// Over the menu bar, which is where the notch is.
  func hang() {
    level = .popUpMenu
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    hasShadow = false
    isMovableByWindowBackground = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    backgroundColor = .clear
    isOpaque = false
    animationBehavior = .none
    // It is the notch, and the notch is black.
    appearance = NSAppearance(named: .darkAqua)
  }
}

private final class NotchPanel: NSPanel, NSDraggingDestination {
  var isLive = false
  var drop: ([URL]) -> Void = { _ in }

  /// Left to itself AppKit puts it under the menu bar.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    isLive ? DropTiles.operation(of: sender.draggingSourceOperationMask) : []
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let found = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    guard isLive, let files = found as? [URL], !files.isEmpty else { return false }
    drop(files)
    return true
  }
}

/// How far out of the notch its menu is.
@MainActor
final class NotchReveal: ObservableObject {
  let notch: NSSize
  @Published var isOut = false
  init(notch: NSSize) { self.notch = notch }
  static let seconds: TimeInterval = 0.28
}

/// Grows out of the notch, and goes back into it.
struct OutOfTheNotch: ViewModifier {
  @ObservedObject var reveal: NotchReveal
  @Environment(\.accessibilityReduceMotion) private var isStill
  private static let radius: CGFloat = 24

  func body(content: Content) -> some View {
    let isOut = reveal.isOut || isStill
    content
      .background(Color.black)
      .mask(alignment: .top) {
        GeometryReader { place in
          Hanging(radius: isOut ? Self.radius : 11)
            .frame(width: isOut ? place.size.width : reveal.notch.width, height: isOut ? place.size.height : reveal.notch.height)
            .frame(maxWidth: .infinity, alignment: .top)
        }
      }
      .opacity(reveal.isOut || !isStill ? 1 : 0)
      .animation(isStill ? nil : .spring(response: NotchReveal.seconds, dampingFraction: 0.86), value: reveal.isOut)
      .environment(\.colorScheme, .dark)
      .ignoresSafeArea()
  }
}

/// Square against the top of the screen, round below.
struct Hanging: Shape {
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
