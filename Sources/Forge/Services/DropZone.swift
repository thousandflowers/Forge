import AppKit
import SwiftUI

/// A small place, always on top, to let files go on: the same menu comes up
/// that comes up over a file being dragged.
@MainActor
final class DropZone: ObservableObject {
  @Published private(set) var isShown = false
  var take: ([URL]) -> Void = { _ in }
  private var panel: NSPanel?
  private static let size = NSSize(width: 144 + Floating.room * 2, height: 104 + Floating.room * 2)
  private static let gap: CGFloat = 24

  func toggle() { isShown ? hide() : show() }

  func show() {
    isShown = true
    let panel = self.panel ?? make()
    self.panel = panel
    panel.orderFrontRegardless()
  }

  func hide() {
    isShown = false
    panel?.orderOut(nil)
  }

  private func make() -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.title = "Drop zone"
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.contentViewController = NSHostingController(rootView: DropZoneView(
      take: { [weak self] in self?.take($0) }, close: { [weak self] in self?.hide() }
    ))
    panel.setContentSize(Self.size)
    if let screen = NSScreen.main?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - Self.gap + Floating.room, y: screen.midY - Self.size.height / 2))
    }
    return panel
  }
}

private struct DropZoneView: View {
  let take: ([URL]) -> Void
  let close: () -> Void
  @State private var isOver = false
  @State private var isInside = false
  @Environment(\.accessibilityReduceMotion) private var isStill

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    return VStack(spacing: 6) {
      FileFan(isOpen: isOver, size: 34)
      Text("Drop here").font(.callout.weight(.semibold)).foregroundStyle(isOver ? Color.accentColor : .primary)
    }
    .frame(width: 144, height: 104)
    .background(shape.fill(Color.accentColor.opacity(isOver ? 0.22 : 0)))
    .floatingGlass(radius: 22)
    .overlay(shape.strokeBorder(Color.accentColor, lineWidth: isOver ? 2.5 : 0))
    .scaleEffect(isOver && !isStill ? 1.04 : 1)
    .animation(isStill ? nil : Motion.arrive, value: isOver)
    .padding(Floating.room)
    .overlay(alignment: .topTrailing) {
      Button(action: close) { Image(systemName: "xmark.circle.fill") }
        .buttonStyle(.plain).foregroundStyle(.secondary).padding(Floating.room + 8)
        .opacity(isInside ? 1 : 0)
        .accessibilityLabel(Text("Close the drop zone"))
    }
    .onHover { isInside = $0 }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      guard !files.isEmpty else { return false }
      take(files)
      return true
    } isTargeted: { isOver = $0 }
  }
}
