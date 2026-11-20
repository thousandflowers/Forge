import SwiftUI
import AppKit
import ImageIO

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
  /// Every run gets a folder under this one; the whole of it goes when the
  /// editor closes.
  @State private var root = FileManager.default.temporaryDirectory
    .appendingPathComponent("ForgePreview-\(UUID().uuidString)", isDirectory: true)

  /// The run is redone when the sample or anything that decides the result
  /// changes - the steps, the test, the formats taken, the naming - and only
  /// then. The steps alone missed the rest: turning "Only if" off left the
  /// last run's "left alone" on screen.
  private struct Key: Equatable {
    let sample: URL?
    let preset: RulePreset

    init(sample: URL?, preset: RulePreset) {
      self.sample = sample
      // A new preset's draft has a new id on every redraw, and the name and
      // description change nothing the files go through.
      var settled = preset
      settled.id = Key.anyID
      settled.name = ""
      settled.description = ""
      self.preset = settled
    }

    private static let anyID = UUID()
  }

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Preview").font(.system(size: 12, weight: .semibold))
        Text(sample?.fileName ?? "no file yet")
          .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(width: 118, alignment: .leading)

      if let failure {
        Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).lineLimit(2)
      } else if sample == nil {
        Text("Drop a file here, or choose one, to see what each step does to it.")
          .font(.callout).foregroundStyle(.secondary)
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
      guard let url = urls.first else { return false }
      use(url)
      return true
    }
    .task(id: Key(sample: sample?.url, preset: preset)) { await refresh() }
    .onDisappear { try? FileManager.default.removeItem(at: root) }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url { use(url) }
  }

  /// A file Forge cannot open says so and keeps the sample there was.
  private func use(_ url: URL) {
    do {
      sample = try ProcessableFile(url: url)
      failure = nil
    } catch {
      failure = "Forge cannot open \(url.lastPathComponent): \(error.localizedDescription)"
    }
  }

  /// Wait a moment so typing a number does not start a run per keystroke,
  /// then take the sample through the chain again into a fresh scratch folder.
  private func refresh() async {
    guard let sample else { return }
    try? await Task.sleep(nanoseconds: 350_000_000)
    guard !Task.isCancelled else { return }
    working = true
    defer { working = false }
    let folder = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
    do {
      steps = try await PreviewRunner.run(sample: sample, preset: preset, coordinator: coordinator, scratch: folder)
      failure = nil
      removeRuns(except: folder)
    } catch is CancellationError {
      // A newer run is on its way; it clears this one's folder when it lands.
      return
    } catch {
      failure = error.localizedDescription
    }
  }

  /// The runs the thumbnails no longer point at. Only after the new run has
  /// finished: until then the strip still shows the previous one's files.
  private func removeRuns(except current: URL) {
    let fileManager = FileManager.default
    let runs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    for run in runs where run.standardizedFileURL != current.standardizedFileURL {
      try? fileManager.removeItem(at: run)
    }
  }
}

/// One step as a small thumbnail with its weight; hover to peek, click to open.
private struct PreviewThumb: View {
  let step: PreviewRunner.Step
  let open: () -> Void
  @State private var hovering = false
  @State private var peeking = false

  var body: some View {
    // The peek closes on the click: it used to stay up over the big view.
    Button { peeking = false; open() } label: {
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
    // Drawn over the strip rather than as a popover: a popover took the next
    // click to close itself, so opening the big view took two.
    .overlay(alignment: .bottomLeading) {
      if peeking {
        VStack(alignment: .leading, spacing: 6) {
          PreviewImage(url: step.url).frame(width: 300, height: 200).clipShape(RoundedRectangle(cornerRadius: 6))
          HStack {
            Text(step.id == 0 ? "Original" : "After \(step.title)").font(.callout.weight(.semibold))
            Spacer()
            Text(PreviewThumb.detail(step)).font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(10)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8, y: 2)
        .fixedSize()
        .offset(y: -48)
        .allowsHitTesting(false)
        .transition(.opacity)
      }
    }
    .zIndex(peeking ? 1 : 0)
    .animation(.easeOut(duration: 0.12), value: peeking)
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

/// A file as a picture: the image itself where there is one, its icon
/// otherwise. Read once per file, scaled down to what is shown, off the main
/// thread - a whole photograph decoded on every redraw is what this replaces.
struct PreviewImage: View {
  let url: URL
  /// The longest side to decode, in pixels; the big view asks for more.
  var maxPixels: Int = 400
  @State private var image: NSImage?

  var body: some View {
    SwiftUI.Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        Rectangle().fill(Color.secondary.opacity(0.15))
      }
    }
    .task(id: url) {
      let url = url, maxPixels = maxPixels
      image = await Task.detached(priority: .utility) { PreviewImage.thumbnail(of: url, maxPixels: maxPixels) }.value
    }
  }

  nonisolated static func thumbnail(of url: URL, maxPixels: Int) -> NSImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
       let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
      return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    return NSWorkspace.shared.icon(forFile: url.path)
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
            PreviewImage(url: original.url, maxPixels: 2000).frame(width: geo.size.width, height: geo.size.height).clipped()
            PreviewImage(url: step.url, maxPixels: 2000).frame(width: geo.size.width, height: geo.size.height).clipped()
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
