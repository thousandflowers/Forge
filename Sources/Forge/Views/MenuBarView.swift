import AppKit
import SwiftUI

/// The menu bar item: what is being made, and what was made last, to be taken
/// from there and dragged to where it is wanted.
///
/// It shares the model with the window, so a preset saved there is here
/// immediately, and a conversion started here lands in the same history.
struct MenuBarView: View {
  static let windowID = "forge.main"
  private static let width: CGFloat = 340
  private static let padding: CGFloat = 8

  @EnvironmentObject private var model: AppModel
  @ObservedObject var running: Running
  @Environment(\.openWindow) private var openWindow
  /// The menu is made once. What it says is looked up every time it opens.
  @State private var openings = 0

  var body: some View {
    let recent = Recent.entries(of: model.history)
    VStack(spacing: 0) {
      header
      if recent.isEmpty, running.jobs.isEmpty {
        nothing
      } else {
        VStack(spacing: 2) {
          ForEach(running.jobs.prefix(Recent.most)) { RunningRow(job: $0) }
          ForEach(recent) { RecentRow(entry: $0, opening: openings) }
        }
        .padding(.horizontal, Self.padding)
        .padding(.bottom, Self.padding)
      }
      Divider()
      footer
    }
    .frame(width: Self.width)
    .task(id: openings) { await model.refreshHistory() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in openings += 1 }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(running.jobs.isEmpty ? "Recent" : "Converting").font(.headline)
      if running.jobs.count > 1 { Tag(text: "\(running.jobs.count)", tint: .accentColor) }
      Spacer()
      MenuBarButton(symbol: "clock", name: "History") {
        // The editor covers the window, and is not left without being asked.
        if model.presetEditor == nil { model.section = .history }
        openForge()
      }
    }
    .padding(.horizontal, Self.padding + 6)
    .padding(.top, 10)
    .padding(.bottom, 6)
  }

  private var nothing: some View {
    VStack(spacing: 8) {
      FileFan(isOpen: false, size: 34)
      Text("No history yet").font(.callout.weight(.medium))
      Text("Files you convert will show up here.").font(.caption).foregroundStyle(.secondary)
    }
    .padding(.vertical, 20)
  }

  private var footer: some View {
    HStack(spacing: 4) {
      Menu {
        if model.usablePresets.isEmpty { Text("No presets turned on") }
        ForEach(model.usablePresets) { preset in
          Button(preset.name) { convert(with: preset) }.disabled(!model.canDeliver(preset))
        }
      } label: {
        Text("Convert")
      }
      .menuStyle(.button)
      .buttonStyle(.bordered)
      .fixedSize()
      Spacer()
      MenuBarButton(symbol: model.dropZone.isShown ? "rectangle.slash" : "arrow.down.doc", name: model.dropZone.isShown ? "Hide Drop Zone" : "Show Drop Zone") {
        model.dropZone.toggle()
      }
      settings
      MenuBarButton(symbol: "macwindow", name: "Open Forge", action: openForge)
      MenuBarButton(symbol: "power", name: "Quit Forge") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    .padding(.horizontal, Self.padding + 4)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var settings: some View {
    if #available(macOS 14, *) {
      SettingsLink { MenuBarButton.face("gearshape") }
        .buttonStyle(MenuBarButton.Style())
        .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
        .help("Settings…")
        .accessibilityLabel(Text("Settings…"))
    } else {
      MenuBarButton(symbol: "gearshape", name: "Settings…") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
      }
    }
  }

  private func openForge() {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: MenuBarView.windowID)
  }

  /// Pick files, pick where they go, convert. The same three questions the
  /// window asks, without the window.
  private func convert(with preset: RulePreset) {
    NSApp.activate(ignoringOtherApps: true)

    let files = NSOpenPanel()
    files.allowsMultipleSelection = true
    files.canChooseDirectories = false
    files.prompt = "Convert"
    // Both panels were titled "Open" and said nothing else.
    files.message = "Choose the files to convert with “\(preset.name)”."
    guard files.runModal() == .OK, !files.urls.isEmpty else { return }

    let destination = NSOpenPanel()
    destination.canChooseDirectories = true
    destination.canChooseFiles = false
    destination.prompt = "Save Into"
    destination.message = "Choose the folder the converted files go into."
    guard destination.runModal() == .OK, let folder = destination.url else { return }

    model.convertFromMenuBar(files.urls, with: preset, into: folder)
  }
}

/// A symbol to press, which answers the pointer.
private struct MenuBarButton: View {
  let symbol: String
  let name: String
  let action: () -> Void

  var body: some View {
    Button(action: action) { Self.face(symbol) }
      .buttonStyle(Style())
      .help(name)
      .accessibilityLabel(Text(name))
  }

  static func face(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26)
  }

  struct Style: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
      let configuration: Configuration
      @State private var isUnder = false

      var body: some View {
        configuration.label
          .foregroundStyle(isUnder ? Color.primary : .secondary)
          .background(Color.primary.opacity(configuration.isPressed ? 0.14 : isUnder ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
          .contentShape(Rectangle())
          .onHover { isUnder = $0 }
      }
    }
  }
}

private enum Row {
  static let picture: CGFloat = 40
  static let radius: CGFloat = 8
  static let padding: CGFloat = 6
}

/// One that is being made.
private struct RunningRow: View {
  let job: Running.Job

  var body: some View {
    HStack(spacing: 10) {
      PreviewImage(url: job.file, maxPixels: 120)
        .frame(width: Row.picture, height: Row.picture)
        .clipShape(RoundedRectangle(cornerRadius: Row.radius, style: .continuous))
      VStack(alignment: .leading, spacing: 5) {
        Text(job.file.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
        ProgressView(value: job.fraction).controlSize(.small)
      }
    }
    .padding(Row.padding)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Converting \(job.file.lastPathComponent)"))
    .accessibilityValue(Text("\(Int(job.fraction * 100))%"))
  }
}

/// One that was made: dragged out by the whole of it.
private struct RecentRow: View {
  @EnvironmentObject private var model: AppModel
  let entry: ProcessingHistory
  let opening: Int
  @State private var recent: Recent?
  @State private var isInside = false

  private var file: URL { recent?.outputs.first ?? entry.fileURL }
  private var isHere: Bool { !(recent?.outputs.isEmpty ?? true) }

  var body: some View {
    HStack(spacing: 10) {
      PreviewImage(url: file, maxPixels: 120)
        .frame(width: Row.picture, height: Row.picture)
        .clipShape(RoundedRectangle(cornerRadius: Row.radius, style: .continuous))
        .opacity(isHere ? 1 : 0.5)
      VStack(alignment: .leading, spacing: 2) {
        Text((entry.outputURL ?? entry.fileURL).lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
        detail.font(.caption.monospacedDigit()).lineLimit(1).truncationMode(.tail)
      }
      Spacer(minLength: 4)
      if let recent, isInside, isHere {
        if recent.canUndo { Button("Undo") { model.undo(entry) }.controlSize(.small) }
        ResultActions(urls: recent.outputs)
      }
    }
    .padding(Row.padding)
    .background(RoundedRectangle(cornerRadius: Row.radius + 2, style: .continuous).fill(Color.primary.opacity(isInside && isHere ? 0.07 : 0)))
    .contentShape(Rectangle())
    .onHover { isInside = $0 }
    .modifier(DraggedOut(file: isHere ? file : nil))
    .help(entry.status == .failed ? entry.errorMessage ?? "" : isHere ? "Drag it anywhere" : "")
    .accessibilityElement(children: .contain)
    .task(id: Moment(opening: opening, undoneAt: entry.undoneAt)) {
      let entry = entry
      recent = await Task.detached(priority: .userInitiated) { Recent(entry) }.value
    }
  }

  private struct Moment: Hashable {
    let opening: Int
    let undoneAt: Date?
  }

  private var detail: Text {
    if entry.status == .failed { return Text(entry.errorMessage ?? entry.status.displayName).foregroundColor(.red) }
    if entry.isUndone { return Text("Undone").foregroundColor(.secondary) }
    guard let recent else { return Text(" ") }
    guard let after = recent.after else { return Text("No longer there").foregroundColor(.secondary) }
    let size = after.formatted(.byteCount(style: .file))
    guard let before = recent.before else { return Text(size).foregroundColor(.secondary) }
    let percent = ResultCard.percent(from: before, to: after).map { "  \($0)" } ?? ""
    return Text("\(before.formatted(.byteCount(style: .file))) → \(size)").foregroundColor(.secondary)
      + Text(percent).foregroundColor(.green).fontWeight(.semibold)
  }
}

/// Only what is there can be taken.
struct DraggedOut: ViewModifier {
  let file: URL?

  func body(content: Content) -> some View {
    if let file {
      content.onDrag { NSItemProvider(object: file as NSURL) }
    } else {
      content
    }
  }
}
