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
struct BehindGlass: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
