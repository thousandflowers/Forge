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
