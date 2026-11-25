import AppKit
import SwiftUI

/// Beside the folder, and with it: where the folder's window goes, it goes.
@MainActor
final class LessonPanel {
  private let panel: NSPanel
  private unowned let lesson: Lesson
  /// The Finder's window with the folder in it.
  private var folder: CGWindowID?
  private var timer: Timer?
  private var isBeside = false

  private static let gap: CGFloat = 10
  private static let often = 1.0 / 60

  init(_ lesson: Lesson) {
    self.lesson = lesson
    panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.title = "Try Forge"
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    let host = NSHostingController(rootView: LessonView(lesson: lesson))
    host.sizingOptions = [.preferredContentSize]
    panel.contentViewController = host
  }

  func show() {
    panel.setContentSize(panel.contentViewController?.view.fittingSize ?? .zero)
    if folder == nil, let screen = NSScreen.main?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.midY - panel.frame.height / 2 + screen.height * 0.08))
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
  }

  func close() {
    timer?.invalidate()
    timer = nil
    NSAnimationContext.runAnimationGroup({ [panel] context in
      context.duration = 0.2
      panel.animator().alphaValue = 0
    }, completionHandler: { [panel] in MainActor.assumeIsolated { panel.orderOut(nil) } })
  }

  /// Opens it, and stays with the window that comes of that.
  func follow(_ url: URL) {
    let before = Set(Self.finderWindows().map(\.id))
    folder = nil
    isBeside = false
    NSWorkspace.shared.open(url)
    timer?.invalidate()
    let began = Date()
    let timer = Timer(timeInterval: Self.often, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.keepUp(before, began) }
    }
    // While a menu is open as well.
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func keepUp(_ before: Set<CGWindowID>, _ began: Date) {
    let windows = Self.finderWindows()
    if folder == nil {
      // A window that was not there; or, if it was, the one brought forward.
      folder = windows.first { !before.contains($0.id) }?.id
      if folder == nil, Date().timeIntervalSince(began) > 1.2 { folder = windows.first?.id }
    }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let isWanted = front == "com.apple.finder" || front == Bundle.main.bundleIdentifier
    if isWanted != panel.isVisible { isWanted ? panel.orderFrontRegardless() : panel.orderOut(nil) }
    guard let folder, let window = windows.first(where: { $0.id == folder }) else { return }
    place(beside: window.frame)
  }

  private func place(beside window: CGRect) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(window) })?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
    let size = panel.frame.size
    let room = Floating.room, seen = size.width - room * 2
    let fitsRight = window.maxX + Self.gap + seen <= screen.maxX
    let fitsLeft = window.minX - Self.gap - seen >= screen.minX
    let isRight = fitsRight || !fitsLeft
    if lesson.isFolderOnTheLeft != isRight { lesson.isFolderOnTheLeft = isRight }
    let x = (isRight ? min(window.maxX + Self.gap, screen.maxX - seen) : window.minX - Self.gap - seen) - room
    let y = min(max(window.maxY - size.height + room - 40, screen.minY - room), screen.maxY - size.height + room)
    let to = NSPoint(x: x.rounded(), y: y.rounded())
    guard to != panel.frame.origin else { return }
    // It goes over there; from then on it is simply there.
    if isBeside {
      panel.setFrameOrigin(to)
    } else {
      isBeside = true
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.4
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        panel.animator().setFrame(NSRect(origin: to, size: size), display: true)
      }
    }
  }

  private struct Window { let id: CGWindowID; let frame: CGRect }

  /// Frontmost first, in the coordinates windows are placed in.
  private static func finderWindows() -> [Window] {
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier,
          let top = NSScreen.screens.first?.frame.maxY,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { one in
      guard (one[kCGWindowOwnerPID as String] as? pid_t) == finder, (one[kCGWindowLayer as String] as? Int) == 0,
            let id = one[kCGWindowNumber as String] as? CGWindowID, let box = one[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: box), frame.width > 200, frame.height > 150 else { return nil }
      return Window(id: id, frame: CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height))
    }
  }
}

/// What to try, and whether it was done.
struct LessonView: View {
  @ObservedObject var lesson: Lesson
  @Environment(\.accessibilityReduceMotion) private var isStill

  static let width: CGFloat = 316, height: CGFloat = 196
  private static let radius: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        header
        content
      }
      .id(lesson.step)
      .transition(isStill ? .opacity : .asymmetric(insertion: .offset(x: 14).combined(with: .opacity), removal: .opacity))
      Spacer(minLength: 0)
      footer
    }
    .padding(18)
    // One size for every step: the panel does not move under the pointer.
    .frame(width: Self.width, height: Self.height, alignment: .topLeading)
    .floatingGlass(radius: Self.radius)
    .padding(Floating.room)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.system(size: 15, weight: .semibold))
      Spacer(minLength: 8)
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 17))
        .foregroundStyle(.green)
        .opacity(lesson.isDone ? 1 : 0)
        .scaleEffect(lesson.isDone || isStill ? 1 : 0.4)
        .accessibilityHidden(!lesson.isDone)
        .accessibilityLabel(Text("Done"))
    }
  }

  private var title: String {
    switch lesson.step {
    case .hello: return "Try Forge"
    case .word: return "Say it in the name"
    case .kind: return "Change what it is"
    case .ask: return "Let it ask"
    case .sound: return "Sound, too"
    case .drag: return "Or just drag"
    case .end: return "That’s all there is to it"
    }
  }

  private var more: String {
    switch lesson.step {
    case .hello: return "Three files to play with, in a folder of their own."
    case .word: return "Select the picture, press Return, and add _gray."
    case .kind: return "Give the letter another extension. If the Finder asks, choose Use .pdf."
    case .ask: return "Not sure? Add _ask, and choose from a menu."
    case .sound: return "Add _reverse to the recording, and listen."
    case .drag: return "Hold \(keys) while you drag the picture, and let go on a format."
    case .end: return "It works the same in any folder you watch."
    }
  }

  private var keys: String { lesson.model?.settings.dragMenuKeys.symbols ?? "⇧" }

  @ViewBuilder
  private var content: some View {
    Text(lesson.problem ?? more)
      .font(.system(size: 13)).foregroundStyle(lesson.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
      .fixedSize(horizontal: false, vertical: true)
    switch lesson.step {
    case .hello: FileFan(isOpen: true, size: 36).frame(maxWidth: .infinity)
    case .drag: if let model = lesson.model { DragSwitch(model: model, keys: keys) }
    case .end: if let model = lesson.model { EndSwitch(model: model) }
    default: if let (from, to) = lesson.renaming() { TypedName(from: from, to: to, isStill: isStill) }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      switch lesson.step {
      case .hello:
        Button("Not Now") { lesson.close() }
        Spacer()
        Button("Open the Folder") { lesson.begin() }.buttonStyle(.borderedProminent)
      case .end:
        Button("Open Forge") {
          let model = lesson.model
          lesson.close()
          model?.section = .process
          model?.showWindow?()
          NSApp.activate(ignoringOtherApps: true)
        }
        Spacer()
        Button("Done") { lesson.close() }.buttonStyle(.borderedProminent)
      default:
        dots
        Spacer()
        Button { lesson.isLoud.toggle() } label: { Image(systemName: lesson.isLoud ? "speaker.wave.2" : "speaker.slash").frame(width: 18) }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .help(lesson.isLoud ? "Turn the sound off" : "Turn the sound on")
          .accessibilityLabel(Text(lesson.isLoud ? "Turn the sound off" : "Turn the sound on"))
        if lesson.renaming() != nil, !lesson.isDone { Button("Show Me") { lesson.showHow() } }
        Button(lesson.isDone ? "Next" : "Skip") { lesson.next() }
      }
    }
    .controlSize(.regular)
  }

  private var dots: some View {
    HStack(spacing: 5) {
      ForEach(Lesson.Step.allCases.filter { $0 != .hello && $0 != .end }, id: \.self) { other in
        Circle().fill(Color.primary.opacity(other.rawValue < lesson.step.rawValue || other == lesson.step ? 0.7 : 0.18)).frame(width: 6, height: 6)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(Text("Step \(lesson.step.rawValue) of \(Lesson.Step.allCases.count - 2)"))
  }
}

/// The name being given, letter by letter, as it is to be typed.
private struct TypedName: View {
  let from: URL
  let to: URL
  let isStill: Bool

  var body: some View {
    let old = from.lastPathComponent, new = to.lastPathComponent
    let start = old.commonPrefix(with: new).count
    let tail = String(old.reversed()).commonPrefix(with: String(new.dropFirst(start).reversed())).count
    let typed = Array(new.dropFirst(start).dropLast(tail))
    let head = String(new.prefix(start)), end = String(new.suffix(tail))
    TimelineView(.periodic(from: .now, by: 0.12)) { time in
      let beat = Int(time.date.timeIntervalSinceReferenceDate / 0.12) % (typed.count + 22)
      let shown = isStill ? typed.count : min(max(0, beat - 4), typed.count)
      HStack(spacing: 8) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: from.path)).resizable().frame(width: 22, height: 22)
        (Text(head) + Text(String(typed.prefix(shown))).foregroundColor(.accentColor) + Text(end))
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 38)
    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement()
    .accessibilityLabel(Text("\(old) becomes \(new)"))
  }
}

private struct DragSwitch: View {
  @ObservedObject var model: AppModel
  let keys: String

  var body: some View {
    Toggle("Menu with \(keys)", isOn: Binding(get: { model.settings.dragMenu }, set: { model.settings.dragMenu = $0; model.saveSettings() }))
      .toggleStyle(.switch).controlSize(.small)
      .font(.system(size: 13))
  }
}

private struct EndSwitch: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Button { model.watchForNames() } label: {
      Label(isWatching ? "Desktop and Downloads are watched" : "Watch Desktop and Downloads", systemImage: isWatching ? "checkmark" : "eye")
    }
    .disabled(isWatching)
  }

  private var isWatching: Bool { model.watchesForNames }
}
