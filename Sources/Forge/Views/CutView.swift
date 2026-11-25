import AVFoundation
import SwiftUI

/// One film, recording or picture, and what is cut out of it.
struct CutView: View {
  @StateObject private var model: CutModel
  @StateObject private var player: CutPlayer
  let save: (RulePreset) async throws -> [URL]
  let close: () -> Void
  @State private var state: Work = .editing

  private enum Work {
    case editing, working, done([URL]), failed(String)
  }

  init(model: CutModel, save: @escaping (RulePreset) async throws -> [URL], close: @escaping () -> Void) {
    _model = StateObject(wrappedValue: model)
    _player = StateObject(wrappedValue: CutPlayer(url: model.file.url, plays: model.isTimed))
    self.save = save
    self.close = close
  }

  var body: some View {
    VStack(spacing: 0) {
      stage.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
      VStack(alignment: .leading, spacing: 14) {
        if model.isTimed { timeline }
        controls
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      Divider()
      footer
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    .frame(minWidth: 720, minHeight: model.hasPicture ? 560 : 260)
    .task {
      await model.load()
      player.part = model.from...max(model.from, model.to)
      // What was loaded has been told by then: the end going to the end is not
      // somebody moving it.
      try? await Task.sleep(nanoseconds: 100_000_000)
      player.begin()
    }
    .onChange(of: model.from) { player.part = $0...max($0, model.to); player.show($0) }
    .onChange(of: model.to) { player.part = model.from...max(model.from, $0); player.show($0) }
    .onChange(of: model.speed) { player.speed = $0 }
    .onChange(of: model.isMuted) { player.isMuted = $0 }
    .onDisappear { player.stop() }
  }

  private var isEditing: Bool { if case .editing = state { return true } else { return false } }

  // MARK: - The picture

  @ViewBuilder
  private var stage: some View {
    if let problem = model.problem {
      Text(problem).foregroundStyle(.white.opacity(0.8)).padding(40)
    } else if model.isReady, model.hasPicture, model.size.width > 0 {
      GeometryReader { space in
        let shown = AVMakeRect(aspectRatio: model.size, insideRect: CGRect(origin: .zero, size: space.size).insetBy(dx: 20, dy: 20))
        ZStack(alignment: .topLeading) {
          picture(in: shown.size)
            .frame(width: shown.width, height: shown.height)
          CropBox(model: model, scale: shown.width / model.size.width)
            .frame(width: shown.width, height: shown.height)
        }
        .frame(width: shown.width, height: shown.height)
        .offset(x: shown.minX, y: shown.minY)
      }
    } else if model.kind == .audio {
      Image(systemName: "waveform").font(.system(size: 64)).foregroundStyle(.white.opacity(0.5))
    } else {
      ProgressView()
    }
  }

  /// Laid out as it is seen and turned as it is asked, which is what will be
  /// done to it.
  private func picture(in size: CGSize) -> some View {
    let isOnItsSide = model.quarters % 2 == 1
    return Group {
      if model.isTimed {
        PlayerLayerView(player: player.player)
      } else {
        PreviewImage(url: model.file.url, maxPixels: 2400)
      }
    }
    .frame(width: isOnItsSide ? size.height : size.width, height: isOnItsSide ? size.width : size.height)
    .rotationEffect(.degrees(Double(model.quarters) * 90))
    .scaleEffect(x: model.isMirrored ? -1 : 1, y: 1)
    .allowsHitTesting(false)
  }

  // MARK: - The time

  private var timeline: some View {
    HStack(spacing: 10) {
      Button { player.toggle() } label: {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 15))
          .foregroundStyle(.white)
          .frame(width: 34, height: 34)
          .background(Color.accentColor, in: Circle())
          .contentShape(Circle())
      }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help("Play the part")
        .accessibilityLabel(Text(player.isPlaying ? "Pause" : "Play"))
      Timeline(model: model, player: player)
      labelled("From") { TimeField(label: "From", value: model.from) { model.setFrom($0); return model.from } }
      labelled("To") { TimeField(label: "To", value: model.to) { model.setTo($0); return model.to } }
    }
    .disabled(!isEditing || !model.isReady)
    .background {
      // I and O, as every editor has them.
      Button("") { model.setFrom(player.time) }.keyboardShortcut("i", modifiers: []).opacity(0).accessibilityHidden(true)
      Button("") { model.setTo(player.time) }.keyboardShortcut("o", modifiers: []).opacity(0).accessibilityHidden(true)
      Button("") { player.step(-1) }.keyboardShortcut(.leftArrow, modifiers: []).opacity(0).accessibilityHidden(true)
      Button("") { player.step(1) }.keyboardShortcut(.rightArrow, modifiers: []).opacity(0).accessibilityHidden(true)
    }
  }

  private func labelled<Field: View>(_ name: String, @ViewBuilder _ field: () -> Field) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
      field()
    }
  }

  // MARK: - The rest

  private var controls: some View {
    HStack(spacing: 12) {
      if model.hasPicture {
        Picker("Shape", selection: Binding(get: { model.shape }, set: { model.setShape($0) })) {
          Text("Any shape").tag(CutModel.Shape?.none)
          ForEach(shapes, id: \.self) { Text($0.title).tag(CutModel.Shape?.some($0)) }
        }
        .fixedSize()
        if model.isCropped { Button("Whole picture") { model.showWhole() } }
        ControlGroup {
          Button { model.turn() } label: { Image(systemName: "rotate.right") }
            .help("Rotate right").accessibilityLabel(Text("Rotate right"))
          Button { model.mirror() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            .help("Mirror").accessibilityLabel(Text("Mirror"))
        }
        .fixedSize()
      }
      if model.isTimed {
        Picker("Speed", selection: $model.speed) {
          ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8], id: \.self) { Text("\(Tool.text($0))×").tag($0) }
        }
        .fixedSize()
      }
      if model.kind == .video {
        Toggle("Mute", isOn: $model.isMuted).toggleStyle(.checkbox)
        Toggle("Fast", isOn: $model.isFast).toggleStyle(.checkbox).disabled(!model.canBeFast)
          .help("Not encoded again, so it is fast. The moment before the cut stays in the file, hidden.")
      }
      Spacer(minLength: 0)
    }
    .disabled(!isEditing || !model.isReady)
  }

  /// The ones there are, and the one it has if a turn made it another.
  private var shapes: [CutModel.Shape] {
    let common = CutModel.Shape.common
    guard let shape = model.shape, !common.contains(shape) else { return common }
    return common + [shape]
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text(summary).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 12)
      switch state {
      case .editing:
        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        Button { run() } label: { Text("Save a Copy").frame(minWidth: 90) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(model.tools.isEmpty || !model.isReady)
      case .working:
        ProgressView().controlSize(.small)
        Text("Saving…")
      case .done(let outputs):
        Text(outputs.first?.lastPathComponent ?? "").fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
        ResultActions(urls: outputs)
        Button("Cut Again") { state = .editing }
        Button("Done", action: close).keyboardShortcut(.defaultAction)
      case .failed(let reason):
        Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
        Button("Try Again") { state = .editing }
      }
    }
  }

  private var summary: String {
    var parts: [String] = []
    if model.isTimed { parts.append(Tool.clock((model.kept * 10).rounded() / 10)) }
    if model.hasPicture, model.isReady { parts.append("\(Int(model.box.width.rounded())) × \(Int(model.box.height.rounded()))") }
    return parts.joined(separator: " · ")
  }

  private func run() {
    player.pause()
    state = .working
    let preset = model.preset
    Task {
      do { state = .done(try await save(preset)) } catch { state = .failed(error.localizedDescription) }
    }
  }
}

// MARK: - Crop

/// The box, its eight handles, and the dark round it.
private struct CropBox: View {
  @ObservedObject var model: CutModel
  /// Points for a pixel.
  let scale: CGFloat
  @State private var start: CGRect?

  private static let reach: CGFloat = 22

  var body: some View {
    let box = CGRect(x: model.box.minX * scale, y: model.box.minY * scale, width: model.box.width * scale, height: model.box.height * scale)
    ZStack(alignment: .topLeading) {
      Path { path in
        path.addRect(CGRect(x: 0, y: 0, width: model.size.width * scale, height: model.size.height * scale))
        path.addRect(box)
      }
      .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
      .allowsHitTesting(false)

      // In thirds, while it is being moved.
      Path { path in
        for third in [1.0 / 3, 2.0 / 3] {
          path.move(to: CGPoint(x: box.minX + box.width * third, y: box.minY))
          path.addLine(to: CGPoint(x: box.minX + box.width * third, y: box.maxY))
          path.move(to: CGPoint(x: box.minX, y: box.minY + box.height * third))
          path.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * third))
        }
      }
      .stroke(Color.white.opacity(start == nil ? 0 : 0.5), lineWidth: 0.5)
      .allowsHitTesting(false)

      Rectangle().strokeBorder(Color.white, lineWidth: 1)
        .background(Color.white.opacity(0.001))
        .frame(width: box.width, height: box.height)
        .offset(x: box.minX, y: box.minY)
        .gesture(drag { start, offset in model.move(start, by: offset) })
        .accessibilityElement()
        .accessibilityLabel(Text("Crop"))
        .accessibilityValue(Text("\(Int(model.box.width)) by \(Int(model.box.height)), from \(Int(model.box.minX)), \(Int(model.box.minY))"))

      ForEach(CutModel.Handle.all.filter { model.shape == nil || $0.isCorner }, id: \.self) { handle in
        let x = box.midX + CGFloat(handle.x) * box.width / 2, y = box.midY + CGFloat(handle.y) * box.height / 2
        RoundedRectangle(cornerRadius: 2).fill(Color.white)
          .frame(width: handle.y == 0 ? 5 : handle.isCorner ? 11 : 22, height: handle.x == 0 ? 5 : handle.isCorner ? 11 : 22)
          .shadow(radius: 1)
          .frame(width: Self.reach, height: Self.reach)
          .contentShape(Rectangle())
          .offset(x: x - Self.reach / 2, y: y - Self.reach / 2)
          .gesture(drag { start, offset in model.drag(handle, from: start, by: offset) })
          .accessibilityHidden(true)
      }
    }
    .coordinateSpace(name: "crop")
  }

  private func drag(_ change: @escaping (CGRect, CGSize) -> Void) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named("crop"))
      .onChanged { value in
        let from = start ?? model.box
        start = from
        change(from, CGSize(width: value.translation.width / scale, height: value.translation.height / scale))
      }
      .onEnded { _ in start = nil }
  }
}

// MARK: - Timeline

private struct Timeline: View {
  @ObservedObject var model: CutModel
  @ObservedObject var player: CutPlayer
  @State private var frames: [CGImage] = []
  @State private var wave: [Double] = []
  @State private var grabbed: Double?

  private static let height: CGFloat = 52
  private static let handle: CGFloat = 12
  private static let count = 14
  private static let bars = 160

  var body: some View {
    GeometryReader { space in
      let width = max(1, space.size.width - Self.handle * 2)
      let perSecond = model.length > 0 ? width / model.length : 0
      let left = Self.handle + model.from * perSecond, right = Self.handle + model.to * perSecond
      ZStack(alignment: .topLeading) {
        HStack(spacing: 0) {
          ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
            Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
              .frame(width: width / CGFloat(max(1, frames.count)), height: Self.height).clipped()
          }
        }
        .frame(width: width, height: Self.height)
        .background { if model.kind == .audio { Waves(levels: wave) } }
        .background(Color.secondary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .offset(x: Self.handle)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
          player.pause()
          player.show(min(max((value.location.x - Self.handle) / max(perSecond, 0.0001), 0), model.length))
        })

        // What is left out.
        Color.black.opacity(0.55).frame(width: max(0, left - Self.handle), height: Self.height).offset(x: Self.handle).allowsHitTesting(false)
        Color.black.opacity(0.55).frame(width: max(0, Self.handle + width - right), height: Self.height).offset(x: right).allowsHitTesting(false)

        VStack {
          Rectangle().fill(Color.accentColor).frame(height: 3)
          Spacer()
          Rectangle().fill(Color.accentColor).frame(height: 3)
        }
        .frame(width: max(0, right - left), height: Self.height).offset(x: left).allowsHitTesting(false)
        grip("Start", "chevron.compact.left", isLeft: true, at: left - Self.handle, perSecond: perSecond, value: model.from) { model.setFrom($0) }
        grip("End", "chevron.compact.right", isLeft: false, at: right, perSecond: perSecond, value: model.to) { model.setTo($0) }

        Capsule().fill(Color.white)
          .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
          .frame(width: 4, height: Self.height + 8).shadow(color: .black.opacity(0.3), radius: 1)
          .offset(x: Self.handle + min(player.time, model.length) * perSecond - 2, y: -4)
          .allowsHitTesting(false)
      }
    }
    .frame(height: Self.height)
    .task(id: model.length) {
      if model.kind == .audio { return wave = await CutPlayer.wave(of: model.file.url, length: model.length, bars: Self.bars) }
      frames = await CutPlayer.strip(of: model.file.url, length: model.length, count: Self.count, height: Self.height * 2)
    }
  }

  private func grip(_ label: String, _ symbol: String, isLeft: Bool, at x: CGFloat, perSecond: CGFloat, value: Double, set: @escaping (Double) -> Void) -> some View {
    UnevenRoundedRectangle(
      topLeadingRadius: isLeft ? 8 : 0, bottomLeadingRadius: isLeft ? 8 : 0, bottomTrailingRadius: isLeft ? 0 : 8, topTrailingRadius: isLeft ? 0 : 8, style: .continuous
    )
      .fill(Color.accentColor)
      .frame(width: Self.handle, height: Self.height)
      .overlay { Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
      .offset(x: x)
      .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { moved in
          let from = grabbed ?? value
          grabbed = from
          player.pause()
          set(from + moved.translation.width / max(perSecond, 0.0001))
        }
        .onEnded { _ in grabbed = nil })
      .accessibilityElement()
      .accessibilityLabel(Text(label))
      .accessibilityValue(Text(Tool.clock(value)))
      .accessibilityAdjustableAction { direction in set(value + (direction == .increment ? 0.1 : -0.1)) }
  }
}

/// What is heard, from one end to the other.
private struct Waves: View {
  let levels: [Double]

  var body: some View {
    Canvas { context, size in
      guard !levels.isEmpty else { return }
      let each = size.width / CGFloat(levels.count), room = size.height - 14
      for (index, level) in levels.enumerated() {
        let height = max(2, room * level)
        let bar = CGRect(x: CGFloat(index) * each + each * 0.2, y: (size.height - height) / 2, width: max(1, each * 0.6), height: height)
        context.fill(Path(roundedRect: bar, cornerRadius: bar.width / 2), with: .color(.primary.opacity(0.55)))
      }
    }
    .accessibilityHidden(true)
  }
}

private struct TimeField: View {
  let label: String
  let value: Double
  /// Says what it came to. Asked of the field itself, that is what it was before.
  let set: (Double) -> Double
  @State private var typed = ""
  @FocusState private var isFocused: Bool

  private var shown: String { Self.text(value) }
  private static func text(_ value: Double) -> String { Tool.clock((value * 100).rounded() / 100) }

  var body: some View {
    TextField(label, text: $typed)
      .focused($isFocused)
      .multilineTextAlignment(.trailing).monospacedDigit()
      .frame(width: 74)
      .onAppear { typed = shown }
      .onChange(of: value) { typed = Self.text($0) }
      .onSubmit(commit)
      .onChange(of: isFocused) { if !$0 { commit() } }
      .accessibilityLabel(Text(label))
  }

  private func commit() {
    guard typed != shown else { return }
    guard let seconds = Tool.seconds(typed.trimmingCharacters(in: .whitespaces)) else {
      NSSound.beep()
      typed = shown
      return
    }
    typed = Self.text(set(seconds))
  }
}

// MARK: - Playing

@MainActor
final class CutPlayer: ObservableObject {
  let player: AVPlayer
  @Published private(set) var time = 0.0
  @Published private(set) var isPlaying = false
  /// It plays the part, over and over.
  var part: ClosedRange<Double> = 0...0
  var speed = 1.0 { didSet { if isPlaying { player.rate = Float(speed) } } }
  var isMuted = false { didSet { player.isMuted = isMuted } }
  private var observer: Any?
  private var hasBegun = false

  init(url: URL, plays: Bool) {
    player = plays ? AVPlayer(url: url) : AVPlayer()
    player.actionAtItemEnd = .pause
    guard plays else { return }
    observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
      MainActor.assumeIsolated { self?.passed(now.seconds) }
    }
  }

  private func passed(_ seconds: Double) {
    time = seconds
    if isPlaying, seconds >= part.upperBound - 0.02 { seek(part.lowerBound); player.rate = Float(speed) }
  }

  func toggle() { isPlaying ? pause() : play() }

  func play() {
    if time < part.lowerBound || time >= part.upperBound - 0.05 { seek(part.lowerBound) }
    isPlaying = true
    player.rate = Float(speed)
  }

  func pause() {
    isPlaying = false
    player.pause()
  }

  /// From here on it follows what is being cut. Loaded, the end is moved to the
  /// end, and that is nothing to look at.
  func begin() { hasBegun = true }

  func show(_ seconds: Double) {
    guard hasBegun, !isPlaying else { return }
    seek(seconds)
  }

  func step(_ frames: Int) {
    pause()
    player.currentItem?.step(byCount: frames)
  }

  func stop() {
    pause()
    if let observer { player.removeTimeObserver(observer) }
    observer = nil
    player.replaceCurrentItem(with: nil)
  }

  private func seek(_ seconds: Double) {
    time = seconds
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  /// How loud it is from end to end, from nothing to one. Read at eight
  /// thousand a second, which is more than is seen of it.
  nonisolated static func wave(of url: URL, length: Double, bars: Int) async -> [Double] {
    let asset = AVURLAsset(url: url)
    guard length > 0, bars > 0, let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
    return await Task.detached {
      let rate = 8_000
      guard let reader = try? AVAssetReader(asset: asset) else { return [] }
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
      ])
      reader.add(output)
      guard reader.startReading() else { return [] }
      var levels = [Double](repeating: 0, count: bars), at = 0
      let each = max(1, Int(length * Double(rate)) / bars)
      while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        var values = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
        let copied = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard copied == noErr else { continue }
        for value in values {
          let bar = min(at / each, bars - 1)
          levels[bar] = max(levels[bar], abs(Double(value)))
          at += 1
        }
      }
      reader.cancelReading()
      let top = levels.max() ?? 0
      return top > 0 ? levels.map { $0 / top } : levels
    }.value
  }

  nonisolated static func strip(of url: URL, length: Double, count: Int, height: CGFloat) async -> [CGImage] {
    guard length > 0 else { return [] }
    return await Task.detached {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 0, height: height)
      return (0..<count).compactMap { index in
        try? generator.copyCGImage(at: CMTime(seconds: length * (Double(index) + 0.5) / Double(count), preferredTimescale: 600), actualTime: nil)
      }
    }.value
  }
}

private struct PlayerLayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resize
    view.layer = layer
    view.wantsLayer = true
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
