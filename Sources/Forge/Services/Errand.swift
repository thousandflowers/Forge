import AppKit

/// Something done in Forge for somebody who was in another app, and goes back
/// to it when it is done: closing a window of Forge's own brings the next of
/// Forge's forward, and whoever dragged a file in the Finder never asked for it.
@MainActor
final class Errand {
  typealias WayBack = () -> Void

  private let wayBack: () -> WayBack?
  private var back: WayBack?

  /// - Parameter wayBack: nil where Forge is where it was begun.
  init(wayBack: (() -> WayBack?)? = nil) { self.wayBack = wayBack ?? { Errand.fromHere() } }

  func begin() {
    if back == nil { back = wayBack() }
  }

  /// They have come to Forge of their own accord.
  func stay() { back = nil }

  func end() {
    let back = back
    self.back = nil
    back?()
  }

  /// The app in front, and the places of Forge's windows among everybody's.
  private static func fromHere() -> WayBack? {
    let mine = NSRunningApplication.current.processIdentifier
    guard !NSApp.isActive, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != mine else { return nil }
    let pile = onScreen()
    let places = NSApp.windows.filter { $0.isVisible && $0.level == .normal }.compactMap { window -> (NSWindow, Int)? in
      guard let place = pile.firstIndex(where: { $0.number == window.windowNumber }) else { return nil }
      return pile[..<place].last { $0.owner != mine }.map { (window, $0.number) }
    }
    return {
      // Closed from afar: whoever did it is somewhere else already.
      guard NSApp.isActive else { return }
      for (window, above) in places where window.isVisible { window.order(.below, relativeTo: above) }
      if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
      app.activate(options: [])
    }
  }

  private static func onScreen() -> [(number: Int, owner: pid_t)] {
    let found = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return found.compactMap { window in
      guard window[kCGWindowLayer as String] as? Int == 0, let number = window[kCGWindowNumber as String] as? Int,
            let owner = window[kCGWindowOwnerPID as String] as? pid_t else { return nil }
      return (number, owner)
    }
  }
}
