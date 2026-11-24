import SwiftUI
import UniformTypeIdentifiers

struct ActionRow: View {
  @Binding var action: Action
  @State private var showingCustomSize = false

  var body: some View {
    settings
  }

  @ViewBuilder
  private var settings: some View {
    switch action.operation {
    case .convertFormat(let to):
      // At the top level formats have a block of their own; inside an arm a
      // copy picks the one format it comes out as.
      FormatChips(offered: OutputFormat.images + OutputFormat.video + OutputFormat.audio + OutputFormat.documents, chosen: to) { action.operation = .convertFormat(to: $0) }

    case .join:
      Text("Every copy carries on from here, each still its own file.")
        .font(.callout)
        .foregroundStyle(.secondary)

    case .merge(let kind):
      Picker("", selection: Binding(get: { kind }, set: { action.operation = .merge($0) })) {
        ForEach(MergeKind.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .labelsHidden()
      .frame(maxWidth: 160, alignment: .leading)

    case .resize(let width, let height, let mode):
      HStack(spacing: 6) {
        numberField("Width", value: width) {
          action.operation = .resize(width: $0, height: height, fitMode: mode)
        }
        Text("×").foregroundStyle(.secondary)
        numberField("Height", value: height) {
          action.operation = .resize(width: width, height: $0, fitMode: mode)
        }
        Picker("", selection: Binding(
          get: { mode },
          set: { action.operation = .resize(width: width, height: height, fitMode: $0) }
        )) {
          ForEach(ResizeFitMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 130)
        // The micro menu: a frame to drag, ready-made shapes, how it fits.
        Button { showingCustomSize = true } label: { Image(systemName: "aspectratio") }
          .buttonStyle(.borderless)
          .help("Custom size: drag a frame, pick a shape")
          .accessibilityLabel(Text("Custom size"))
          .popover(isPresented: $showingCustomSize, arrowEdge: .bottom) {
            CustomSizeMenu(
              width: Binding(get: { width }, set: { setResize(width: .some($0)) }),
              height: Binding(get: { height }, set: { setResize(height: .some($0)) }),
              fit: Binding(get: { mode }, set: { setResize(fit: $0) })
            )
          }
      }

    case .quality(let level):
      HStack(spacing: 6) {
        NumberToken(
          value: Binding(get: { level }, set: { action.operation = .quality(level: $0 ?? level) }),
          placeholder: "\(level)", range: 1...100, startingFrom: level
        )
        .accessibilityLabel(Text("Quality"))
        Text("%").foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { Double(level) },
            set: { action.operation = .quality(level: Int($0.rounded())) }
          ),
          // No step: on macOS a step draws a tick for every one of the hundred.
          in: 1...100
        )
        .frame(maxWidth: 160)
        .accessibilityLabel(Text("Quality"))
      }

    case .filter(let type):
      Picker("", selection: Binding(
        get: { type },
        set: { action.operation = .filter(type: $0) }
      )) {
        ForEach(FilterType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      .labelsHidden()
      .frame(maxWidth: 200, alignment: .leading)

    case .encode(let codec):
      Picker("", selection: Binding(
        get: { codec },
        set: { action.operation = .encode(codec: $0) }
      )) {
        Section("Video") { ForEach(Codec.videoCodecs, id: \.self) { Text($0.title).tag($0) } }
        Section("Audio") { ForEach(Codec.audioCodecs, id: \.self) { Text($0.title).tag($0) } }
      }
      .labelsHidden()
      .frame(maxWidth: 200, alignment: .leading)

    case .film(let settings):
      FilmSettingsView(settings: Binding(get: { settings }, set: { action.operation = .film($0) }))

    case .tool(let tool):
      ToolRow(tool: Binding(get: { tool }, set: { action.operation = .tool($0) }))

    case .when, .split:
      EmptyView()

    case .stripMetadata(let policy):
      Picker("", selection: Binding(
        get: { policy },
        set: { action.operation = .stripMetadata(policy: $0) }
      )) {
        // Keeping is a choice too: it overrules a general preference to remove.
        ForEach(PrivacyPolicy.allCases, id: \.self) { Text($0.blockTitle).tag($0) }
      }
      .labelsHidden()
      .frame(maxWidth: 260, alignment: .leading)

    case .limitSize(let bytes):
      HStack(spacing: 6) {
        TextField("Megabytes", text: Binding(
          get: { String(format: "%g", Double(bytes) / 1_000_000) },
          set: { text in
            let megabytes = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
            action.operation = .limitSize(bytes: Int(max(megabytes, 0) * 1_000_000))
          }
        ))
        .frame(width: 80)
        .accessibilityLabel(Text("Largest size, in megabytes"))
        Text("MB").foregroundStyle(.secondary)
      }

    case .recognizeText(let languages):
      Picker("", selection: Binding(
        get: { languages.first ?? "" },
        set: { action.operation = .recognizeText(languages: $0.isEmpty ? [] : [$0]) }
      )) {
        Text("Detect automatically").tag("")
        ForEach(TextRecognizer.supportedLanguages, id: \.self) { Text($0).tag($0) }
      }
      .labelsHidden()
      .frame(maxWidth: 220, alignment: .leading)
    }
  }

  /// Changes one side of a resize, reading the other side from the operation
  /// as it is now: the menu sets width and then height in one go, and a
  /// value captured before the first change would put the width back.
  private func setResize(width newWidth: Int?? = nil, height newHeight: Int?? = nil, fit newFit: ResizeFitMode? = nil) {
    guard case .resize(let width, let height, let fit) = action.operation else { return }
    action.operation = .resize(width: newWidth ?? width, height: newHeight ?? height, fitMode: newFit ?? fit)
  }

  /// A number in the sentence: click and type, ↑↓, drag sideways, Tab, Esc.
  private func numberField(_ label: String, value: Int?, set: @escaping (Int?) -> Void) -> some View {
    NumberToken(value: Binding(get: { value }, set: set), placeholder: "auto")
      .help(label)
      .accessibilityLabel(Text(label))
  }
}

/// The output formats offered, taken from what this machine can really write
/// rather than a list typed out by hand.
