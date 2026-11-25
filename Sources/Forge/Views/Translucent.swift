import SwiftUI

extension View {
  /// A sheet the window shows through, the way the Mac's own panels do.
  ///
  /// The material API arrived in macOS 13.3; on 13.0 the sheet stays plain
  /// rather than the app refusing to run.
  @ViewBuilder
  func translucentSheet() -> some View {
    if #available(macOS 13.3, *) {
      presentationBackground(.thinMaterial)
    } else {
      self
    }
  }
}

/// What is behind the window, blurred, as a menu has it. A material of
/// SwiftUI's goes flat and grey in a panel that has not got the keyboard, and
/// one over a drag never has.
///
/// The shape is given to the view itself: what is blurred is drawn by the window
/// server, which has not heard of SwiftUI's clipping, and left to that its
/// corners are square behind the round ones.
struct BehindGlass: NSViewRepresentable {
  var radius: CGFloat = 0

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    view.maskImage = Self.mask(radius)
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) { view.maskImage = Self.mask(radius) }

  /// Stretched in the middle, so that it is right at any size.
  private static func mask(_ radius: CGFloat) -> NSImage? {
    guard radius > 0 else { return nil }
    // A continuous corner begins well before its radius does.
    let inset = (radius * 1.6).rounded(.up), side = inset * 2 + 2
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { box in
      NSColor.black.setFill()
      RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: box).cgPath.fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
    image.resizingMode = .stretch
    return image
  }
}

private extension CGPath {
  func fill() {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.addPath(self)
    context.fillPath()
  }
}

/// How much a panel leaves round what it shows. Less, and the shadow is cut off
/// in a straight line where the panel ends.
enum Floating {
  static let room: CGFloat = 34
}

extension View {
  /// A panel's own look: glass, one hairline just inside its edge, and a shadow
  /// that follows its shape. The panel leaves room for the shadow and has none
  /// of its own: the system's is drawn round a square.
  func floatingGlass(radius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return background(BehindGlass(radius: radius))
      .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
      .background(shape.fill(Color.black).blur(radius: 11).opacity(0.28).offset(y: 5))
  }
}
