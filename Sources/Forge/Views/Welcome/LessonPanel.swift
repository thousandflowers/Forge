import AppKit
import SwiftUI

/// Beside the folder, and with it: where the folder's window goes, it goes.
@MainActor
final class LessonPanel {
  private let panel: Panel
  private unowned let lesson: Lesson
  /// The Finder's window with the folder in it.
  private var folder: CGWindowID?
  private var timer: Timer?
  private var isBeside = false

  /// Return and Escape answer the first question. Once the folder is open they
  /// are the Finder's: a name is being typed there.
  private final class Panel: NSPanel {
    var takesKeys = true
    override var canBecomeKey: Bool { takesKeys }
  }

  private static let gap: CGFloat = 10
  private static let often = 1.0 / 60

  init(_ lesson: Lesson) {
    self.lesson = lesson
    panel = Panel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
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
      panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.midY - panel.frame.height / 2))
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    if panel.canBecomeKey { panel.makeKey() }
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
    panel.takesKeys = false
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
    VStack(spacing: 0) {
      VStack(spacing: 6) {
        header
        words
        // In the middle of what is left, whatever it is and however many lines
        // there are above it.
        thing.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 10)
      }
      .id(lesson.step)
      .transition(isStill ? .opacity : .asymmetric(insertion: .offset(x: 14).combined(with: .opacity), removal: .opacity))
      footer
    }
    .padding(18)
    // One size for every step: the panel does not move under the pointer.
    .frame(width: Self.width, height: Self.height, alignment: .topLeading)
    .floatingGlass(radius: Self.radius)
    .padding(Floating.room)
  }

  /// The tick beside it takes no room: the title stays in the middle.
  private var header: some View {
    Text(title)
      .font(.system(size: 15, weight: .semibold))
      .frame(maxWidth: .infinity)
      .overlay(alignment: .trailing) {
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
    case .word: return "Sound, too"
    case .kind: return "Change what it is"
    case .drag: return "Or just drag"
    case .scan: return "A little magic"
    case .keep: return "Anywhere else"
    case .end: return "That’s all there is to it"
    }
  }

  private var more: String {
    switch lesson.step {
    case .hello: return "Three files to play with."
    case .kind: return "Now make it .pdf. If the Finder asks, choose Use .pdf."
    case .word: return "Add _reverse to the recording, and listen."
    case .drag: return "Hold \(keys) while you drag the picture, and let go on a format."
    case .scan: return "Select the photo, press Return, and add _scan."
    case .keep: return "It works the same in any folder you watch."
    case .end: return lesson.made == nil ? "A few more names to try." : "The PDF is yours: drag it anywhere."
    }
  }

  private var keys: String { lesson.model?.settings.dragMenuKeys.symbols ?? "⇧" }

  private var words: some View {
    Text(lesson.problem ?? more)
      .font(.system(size: 13)).foregroundStyle(lesson.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private var thing: some View {
    switch lesson.step {
    case .hello: LessonFan(size: 42, formats: lesson.formats, touched: lesson.touch, pressed: lesson.pop)
    case .drag: if let files = lesson.files { HeldFile(file: files.picture, keys: keys) }
    case .end:
      VStack(spacing: 8) {
        if let made = lesson.made { LessonMade(file: made) }
        LessonExtras(lesson: lesson)
      }
    case .keep:
      VStack(spacing: 10) {
        if let model = lesson.model {
          EndSwitch(model: model)
          if lesson.isDragMenuNew { DragSwitch(model: model, keys: keys) }
        }
      }
    case .scan, .kind:
      if lesson.isDone, lesson.chain.count > 1 {
        LessonChain(images: lesson.chain).transition(.scale(scale: 0.8).combined(with: .opacity))
      } else if let (from, to) = lesson.renaming() {
        TypedName(from: from, to: to, isStill: isStill)
      }
    default: if let (from, to) = lesson.renaming() { TypedName(from: from, to: to, isStill: isStill) }
    }
  }

  /// What is pressed in the middle; how far it is, and the sound, at the sides.
  private var footer: some View {
    HStack(spacing: 8) {
      switch lesson.step {
      case .hello:
        Button("Not Now") { lesson.openForge() }.keyboardShortcut(.cancelAction)
        Button("Open the Folder") { lesson.begin() }.buttonStyle(Prominent()).keyboardShortcut(.defaultAction)
      case .end:
        Button("Open Forge") { lesson.openForge(.process) }
        Button("Done") { lesson.close() }.buttonStyle(Prominent())
      case .keep:
        Button("Next") { lesson.next() }
      default:
        if lesson.renaming() != nil, !lesson.isDone { Button("Show Me") { lesson.showHow() } }
        Button(lesson.isDone ? "Next" : "Skip") { lesson.next() }
      }
    }
    .controlSize(.regular)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .leading) { if isTrying { dots } }
    .overlay(alignment: .trailing) { sound }
  }

  private var isTrying: Bool { !Self.aside.contains(lesson.step) }
  /// Nothing to be done here.
  private static let aside: Set<Lesson.Step> = [.hello, .keep, .end]

  private var sound: some View {
    let name = lesson.isLoud ? "Turn the sound off" : "Turn the sound on"
    return Button { lesson.isLoud.toggle() } label: { Image(systemName: lesson.isLoud ? "speaker.wave.2" : "speaker.slash").frame(width: 18) }
      .buttonStyle(.plain)
      // Where there is something to listen to, and nothing to be heard.
      .foregroundStyle(lesson.step == .word && !lesson.isLoud ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
      .help(name)
      .accessibilityLabel(Text(name))
  }

  private var dots: some View {
    HStack(spacing: 5) {
      ForEach(Lesson.Step.allCases.filter { !Self.aside.contains($0) }, id: \.self) { other in
        Circle().fill(Color.primary.opacity(other.rawValue < lesson.step.rawValue || other == lesson.step ? 0.7 : 0.18)).frame(width: 6, height: 6)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(Text("Step \(lesson.step.rawValue) of \(Lesson.Step.allCases.count - Self.aside.count)"))
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
        // As wide as it will be: in the middle, it moved with every letter.
        Text(new).hidden().overlay(alignment: .leading) {
          (Text(head) + Text(String(typed.prefix(shown))).foregroundColor(.accentColor) + Text(end)).fixedSize()
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity)
    .frame(height: 38)
    // As where a name is typed in the Finder.
    .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement()
    .accessibilityLabel(Text("\(old) becomes \(new)"))
  }
}

/// The Finder has the keys, and the system's own is drawn like any other
/// button without them.
private struct Prominent: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .frame(height: 20)
      .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

/// The key to hold, and the file to take hold of.
private struct HeldFile: View {
  let file: URL
  let keys: String

  var body: some View {
    HStack(spacing: 12) {
      Text(keys)
        .font(.system(size: 17, weight: .medium))
        .frame(minWidth: 38, minHeight: 38)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      HStack(spacing: 8) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 22, height: 22)
        Text(file.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
      }
      .frame(maxWidth: .infinity, minHeight: 38)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .accessibilityElement()
    .accessibilityLabel(Text("\(keys) and \(file.lastPathComponent)"))
  }
}

private struct DragSwitch: View {
  @ObservedObject var model: AppModel
  let keys: String

  var body: some View {
    Toggle("Keep the menu with \(keys)", isOn: Binding(get: { model.settings.dragMenu }, set: { model.settings.dragMenu = $0; model.saveSettings() }))
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
