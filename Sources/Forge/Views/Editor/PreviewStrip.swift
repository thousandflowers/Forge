import SwiftUI
import AppKit

/// The Preview at the foot of the editor: a sample file after each step, as
/// small thumbnails with what each weighs. Hover one to peek at it; click it
/// to compare it with the original, big. Nothing is written beside the
/// original: every stage goes to a scratch folder of its own.
struct PreviewStrip: View {
  let preset: RulePreset
  let coordinator: ProcessingCoordinator
  /// Called with the original and the step clicked, for the big view.
  let open: (PreviewRunner.Step, PreviewRunner.Step) -> Void

  @State private var sample: ProcessableFile?
  @State private var steps: [PreviewRunner.Step] = []
  @State private var failure: String?
  @State private var working = false
  @State private var scratch: URL?

  /// The run is redone when the sample or the chain changes, and only then.
  private struct Key: Equatable {
    let sample: URL?
    let actions: [Operation]
  }

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Preview").font(.system(size: 12, weight: .semibold))
        Text(sample?.fileName ?? "no file yet")
          .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(width: 118, alignment: .leading)

      if sample == nil {
        Text("Drop a file here, or choose one, to see what each step does to it.")
          .font(.callout).foregroundStyle(.secondary)
      } else if let failure {
        Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).lineLimit(2)
      } else {
        ForEach(steps) { step in
          if step.id > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
          PreviewThumb(step: step) { if let first = steps.first { open(first, step) } }
        }
        if working { ProgressView().controlSize(.small) }
      }
      Spacer()
      Button("Choose…", action: choose).controlSize(.small)
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
    .frame(minHeight: 52)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first, let file = try? ProcessableFile(url: url) else { return false }
      sample = file
      return true
    }
    .task(id: Key(sample: sample?.url, actions: preset.actions)) { await refresh() }
    .onDisappear { removeScratch() }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url { sample = try? ProcessableFile(url: url) }
  }

  /// Wait a moment so typing a number does not start a run per keystroke,
  /// then take the sample through the chain again into a fresh scratch folder.
  private func refresh() async {
    guard let sample else { return }
    try? await Task.sleep(nanoseconds: 350_000_000)
    guard !Task.isCancelled else { return }
    working = true
    defer { working = false }
    removeScratch()
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ForgePreview-\(UUID().uuidString)", isDirectory: true)
    scratch = folder
    do {
      steps = try await PreviewRunner.run(sample: sample, preset: preset, coordinator: coordinator, scratch: folder)
      failure = nil
    } catch is CancellationError {
      return
    } catch {
      failure = error.localizedDescription
    }
  }

  private func removeScratch() {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    scratch = nil
  }
}

/// One step as a small thumbnail with its weight; hover to peek, click to open.
private struct PreviewThumb: View {
  let step: PreviewRunner.Step
  let open: () -> Void
  @State private var hovering = false
  @State private var peeking = false

  var body: some View {
    Button(action: open) {
      HStack(spacing: 6) {
        PreviewImage(url: step.url).frame(width: 42, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
        VStack(alignment: .leading, spacing: 0) {
          Text(step.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
          Text(PreviewThumb.size(step.bytes)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
      .padding(4)
      .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
    }
    .buttonStyle(.plain)
    .help("Click to compare it with the original")
    .onHover { inside in
      hovering = inside
      if inside {
        // A short wait, so sweeping across the strip does not flash each one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if hovering { peeking = true } }
      } else {
        peeking = false
      }
    }
    .popover(isPresented: $peeking, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 6) {
        PreviewImage(url: step.url).frame(width: 300, height: 200).clipShape(RoundedRectangle(cornerRadius: 6))
        HStack {
          Text(step.id == 0 ? "Original" : "After \(step.title)").font(.callout.weight(.semibold))
          Spacer()
          Text(PreviewThumb.detail(step)).font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(10)
    }
    .accessibilityLabel(Text("\(step.title), \(PreviewThumb.size(step.bytes))"))
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  static func detail(_ step: PreviewRunner.Step) -> String {
    let pixels = step.width.flatMap { w in step.height.map { "\(w) × \($0) · " } } ?? ""
    return pixels + size(step.bytes)
  }
}

/// A file as a picture: the image itself where there is one, its icon otherwise.
struct PreviewImage: View {
  let url: URL

  var body: some View {
    let image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
  }
}

/// The big view: the original against one step, a divider to drag between
/// them. Esc or a click outside closes it.
struct PreviewCompare: View {
  let original: PreviewRunner.Step
  let step: PreviewRunner.Step
  let close: () -> Void
  @State private var split: CGFloat = 0.5

  var body: some View {
    ZStack {
      Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: close)
      VStack(spacing: 10) {
        HStack {
          Text(step.id == 0 ? "Original" : "After \(step.title)").font(.headline).foregroundStyle(.white)
          Text(PreviewThumb.detail(step)).foregroundStyle(.white.opacity(0.7))
          Spacer()
          Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close"))
        }
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            PreviewImage(url: original.url).frame(width: geo.size.width, height: geo.size.height).clipped()
            PreviewImage(url: step.url).frame(width: geo.size.width, height: geo.size.height).clipped()
              .mask(alignment: .leading) {
                Rectangle().frame(width: geo.size.width * (1 - split)).offset(x: geo.size.width * split)
              }
            Rectangle().fill(.white).frame(width: 2).offset(x: geo.size.width * split - 1)
          }
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(max($0.location.x / geo.size.width, 0.03), 0.97) })
        }
        Text("Drag to compare · Esc to close").font(.caption).foregroundStyle(.white.opacity(0.6))
      }
      .padding(40)
      .frame(maxWidth: 900, maxHeight: 640)
    }
  }
}
