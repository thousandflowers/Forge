import AppKit
import SwiftUI

/// The corner the cards come up in. It takes neither the keyboard nor the
/// front: it is there to be seen, and to be used by whoever wants to.
@MainActor
final class ResultPanel {
  private let panel: NSPanel
  private static let gap: CGFloat = 18

  init(center: ResultCenter) {
    panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.title = "Forge did this"
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    let host = NSHostingController(rootView: ResultCards(center: center) { [weak self] in self?.place() })
    host.sizingOptions = [.preferredContentSize]
    panel.contentViewController = host
  }

  func appear() {
    panel.orderFrontRegardless()
    DispatchQueue.main.async { [weak self] in self?.place() }
  }

  func close() { panel.orderOut(nil) }

  private func place() {
    let mouse = NSEvent.mouseLocation
    guard let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame else { return }
    if let size = panel.contentViewController?.view.fittingSize, size.width > 0 { panel.setContentSize(size) }
    panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - Self.gap, y: screen.minY + Self.gap))
  }
}

private struct ResultCards: View {
  @ObservedObject var center: ResultCenter
  let changed: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      ForEach(center.cards) { card in
        ResultCardView(card: card, close: { center.close(card.id) }) { inside in
          if inside { center.held.insert(card.id) } else { center.held.remove(card.id) }
        }
      }
    }
    .onChange(of: center.cards.map(\.id)) { _ in DispatchQueue.main.async { changed() } }
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
        HStack(spacing: 6) {
          Text("\(size(card.before)) → \(size(card.after))").foregroundStyle(.secondary)
          if let percent = ResultCard.percent(from: card.before, to: card.after) {
            Text(percent).fontWeight(.semibold).foregroundStyle(.green)
          }
        }
        .font(.callout).monospacedDigit()
      }
      Spacer(minLength: 4)
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
    .frame(width: 360, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    .onHover { inside = $0; hover($0) }
  }

  private func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
}
