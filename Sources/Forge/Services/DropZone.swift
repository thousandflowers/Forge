import AppKit
import SwiftUI

/// A small place, always on top, to let files go on: the same menu comes up
/// that comes up over a file being dragged.
@MainActor
final class DropZone: ObservableObject {
  @Published private(set) var isShown = false
  var take: ([URL]) -> Void = { _ in }
  private var panel: NSPanel?
  private static let size = NSSize(width: 132, height: 96)
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

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: "arrow.down.doc").font(.system(size: 24, weight: .medium))
      Text("Drop here").font(.callout.weight(.medium))
    }
    .foregroundStyle(isOver ? Color.white : .secondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(isOver ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [5])))
    .overlay(alignment: .topTrailing) {
      Button(action: close) { Image(systemName: "xmark.circle.fill") }
        .buttonStyle(.plain).foregroundStyle(.secondary).padding(7)
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
