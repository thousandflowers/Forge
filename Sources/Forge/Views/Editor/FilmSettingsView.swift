import SwiftUI

/// Everything a film can be told. The first lines are the ones people come
/// for; the rest is folded away under what it is about.
struct FilmSettingsView: View {
  @Binding var settings: FilmSettings
  @ObservedObject private var installer = ToolInstaller.shared
  @State private var encoders: Set<String>?
  @State private var showsPicture = false
  @State private var showsSound = false
  @State private var showsPart = false

  private static let labelWidth: CGFloat = 110

  private var tool: ExternalTool? { ToolOffers.all.first { $0.binary == "ffmpeg" && !$0.isInstalled } }

  private var offered: [FilmSettings.Encoder] {
    FilmSettings.Encoder.allCases.filter { encoder in
      encoder == settings.encoder || (encoders.map { $0.contains(encoder.name) } ?? true)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let tool {
        ToolOfferRow(tool: tool, because: "Film settings are ffmpeg\u{2019}s work.", installer: installer)
      }
      line("Encoder") {
        Picker("Encoder", selection: $settings.encoder) { ForEach(offered, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
        if !settings.encoder.isApple {
          Picker("Speed", selection: $settings.speed) { ForEach(FilmSettings.Speed.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
            .help("Slower makes a smaller file that looks the same")
        }
      }
      rate
      line("Frames") {
        NumberToken(value: $settings.framesPerSecond, placeholder: "all", range: 1...240, startingFrom: 30)
          .accessibilityLabel(Text("Frames a second"))
        Text("a second").foregroundStyle(.secondary)
      }
      Text("Fits in \(settings.encoder.containers.map { $0.uppercased() }.formatted(.list(type: .and).locale(Locale(identifier: "en")))).")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Picture", isExpanded: $showsPicture) { picture.padding(.top, 6) }
      DisclosureGroup("Sound and subtitles", isExpanded: $showsSound) { sound.padding(.top, 6) }
      DisclosureGroup("Only a part", isExpanded: $showsPart) { part.padding(.top, 6) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .confirmsToolInstalls(with: installer)
    .task { encoders = await Task.detached { ExternalBridge.ffmpegEncoders }.value }
  }

  // MARK: - Rate

  private var isByQuality: Binding<Bool> {
    Binding(
      get: { if case .quality = settings.rate { return true } else { return false } },
      set: { settings.rate = $0 ? .quality(75) : .kilobits(5000) }
    )
  }

  private var rate: some View {
    line("Aim for") {
      Picker("Aim for", selection: isByQuality) {
        Text("A quality").tag(true)
        Text("A bit rate").tag(false)
      }
      .labelsHidden()
      switch settings.rate {
      case .quality(let quality):
        NumberToken(
          value: Binding(get: { quality }, set: { settings.rate = .quality($0 ?? quality) }),
          placeholder: "\(quality)", range: 1...100, startingFrom: quality
        )
        .accessibilityLabel(Text("Quality"))
        Text("% (\(settings.encoder.scaleName) \(settings.encoder.level(for: quality)))").foregroundStyle(.secondary)
      case .kilobits(let kilobits):
        NumberToken(
          value: Binding(get: { kilobits }, set: { settings.rate = .kilobits($0 ?? kilobits) }),
          placeholder: "\(kilobits)", range: 50...200_000, startingFrom: kilobits
        )
        .accessibilityLabel(Text("Kilobits a second"))
        Text("kb/s").foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Picture

  private var picture: some View {
    VStack(alignment: .leading, spacing: 8) {
      choice("Interlacing", $settings.interlacing, title: \.title)
      choice("Noise", $settings.noise, title: \.title)
      if let warning = settings.noise.warning {
        Label(warning, systemImage: "tortoise").font(.caption).foregroundStyle(.orange)
      }
      choice("Sharpness", $settings.sharpness, title: \.title)
      crop
      choice("Turn", $settings.turn, title: \.title)
      line("Also") {
        Toggle("Smooth blocks", isOn: $settings.smoothsBlocks)
        Toggle("Grey", isOn: $settings.isGrey)
        Toggle("PAL to HD colours", isOn: $settings.isRec709).help("For an old PAL tape: from Rec. 601 to the Rec. 709 screens expect")
      }
    }
  }

  private enum CropChoice: String, CaseIterable { case none = "Leave it", blackBars = "Black bars off", edges = "By hand" }

  private var cropChoice: Binding<CropChoice> {
    Binding(
      get: {
        switch settings.crop {
        case .none: return .none
        case .blackBars: return .blackBars
        case .edges: return .edges
        }
      },
      set: {
        switch $0 {
        case .none: settings.crop = .none
        case .blackBars: settings.crop = .blackBars
        case .edges: settings.crop = .edges(top: 0, bottom: 0, left: 0, right: 0)
        }
      }
    )
  }

  @ViewBuilder
  private var crop: some View {
    line("Crop") {
      Picker("Crop", selection: cropChoice) { ForEach(CropChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
    }
    if case .edges(let top, let bottom, let left, let right) = settings.crop {
      line("") {
        edge("Top", top) { settings.crop = .edges(top: $0, bottom: bottom, left: left, right: right) }
        edge("Bottom", bottom) { settings.crop = .edges(top: top, bottom: $0, left: left, right: right) }
        edge("Left", left) { settings.crop = .edges(top: top, bottom: bottom, left: $0, right: right) }
        edge("Right", right) { settings.crop = .edges(top: top, bottom: bottom, left: left, right: $0) }
      }
    }
  }

  private func edge(_ name: String, _ value: Int, set: @escaping (Int) -> Void) -> some View {
    HStack(spacing: 4) {
      Text(name).foregroundStyle(.secondary)
      NumberToken(value: Binding(get: { value }, set: { set($0 ?? 0) }), placeholder: "0", range: 0...8000, startingFrom: 0)
        .accessibilityLabel(Text("\(name), in pixels"))
    }
  }

  // MARK: - Sound

  private var sound: some View {
    VStack(alignment: .leading, spacing: 8) {
      line("Sound") {
        Picker("Sound", selection: $settings.sound) { ForEach(FilmSettings.Sound.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
        if settings.sound.takesRate {
          NumberToken(value: $settings.soundKilobits, placeholder: "auto", range: 16...640, startingFrom: 160)
            .accessibilityLabel(Text("Sound, kilobits a second"))
          Text("kb/s").foregroundStyle(.secondary)
        }
      }
      if settings.sound != .none {
        choice("Channels", $settings.channels, title: \.title)
        line("Also") { Toggle("Even out the loudness", isOn: $settings.evensLoudness) }
      }
      line("Subtitles") { Toggle("Keep them", isOn: $settings.keepsSubtitles) }
    }
  }

  private var part: some View {
    line("Seconds") {
      Text("from").foregroundStyle(.secondary)
      NumberToken(value: $settings.from, placeholder: "start", range: 0...360_000, startingFrom: 0)
        .accessibilityLabel(Text("From, in seconds"))
      Text("to").foregroundStyle(.secondary)
      NumberToken(value: $settings.to, placeholder: "end", range: 1...360_000, startingFrom: 10)
        .accessibilityLabel(Text("To, in seconds"))
    }
  }

  // MARK: - Lines

  private func choice<Value: CaseIterable & Hashable>(
    _ name: String, _ value: Binding<Value>, title: @escaping (Value) -> String
  ) -> some View where Value.AllCases: RandomAccessCollection {
    line(name) {
      Picker(name, selection: value) { ForEach(Value.allCases, id: \.self) { Text(title($0)).tag($0) } }.labelsHidden()
    }
  }

  private func line<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 8) {
      Text(name).foregroundStyle(.secondary).frame(width: Self.labelWidth, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
    .pickerStyle(.menu)
    .fixedSize(horizontal: false, vertical: true)
  }
}
