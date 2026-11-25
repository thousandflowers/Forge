import AppKit
import SwiftUI

/// A small place, always on top, to let files go on: the same menu comes up
/// that comes up over a file being dragged.
@MainActor
final class DropZone: ObservableObject {
  @Published private(set) var isShown = false
  var take: ([URL]) -> Void = { _ in }
  private var panel: NSPanel?
  private static let size = NSSize(width: 168, height: 128)
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
    panel.contentViewController = NSHostingController(rootView: DropZoneView(
      take: { [weak self] in self?.take($0) }, close: { [weak self] in self?.hide() }
    ))
    panel.setContentSize(Self.size)
    if let screen = NSScreen.main?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - Self.gap, y: screen.midY - Self.size.height / 2))
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
    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    return VStack(spacing: 6) {
      FileFan(isOpen: isOver, size: 34)
      Text("Drop here").font(.callout.weight(.semibold)).foregroundStyle(isOver ? Color.accentColor : .primary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial, in: shape)
    .background(shape.fill(Color.accentColor.opacity(isOver ? 0.25 : 0)))
    .overlay(shape.strokeBorder(isOver ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isOver ? 2.5 : 1))
    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    .scaleEffect(isOver && !isStill ? 1.04 : 1)
    .animation(isStill ? nil : .spring(response: 0.28, dampingFraction: 0.75), value: isOver)
    .padding(12)
    .overlay(alignment: .topTrailing) {
      Button(action: close) { Image(systemName: "xmark.circle.fill") }
        .buttonStyle(.plain).foregroundStyle(.secondary).padding(19)
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
