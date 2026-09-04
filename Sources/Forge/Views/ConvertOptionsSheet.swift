import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What a batch should become.
///
/// A preset picked from the shelf is kept whole: `presetID` means "run exactly
/// what that preset says", which matters because a preset can hold things this
/// sheet has no control for, such as two filters in a row. Touching any control
/// drops the preset and the chain is built from the fields instead — the preset
/// was a starting point, not a mode.
struct ConvertChoice: Equatable {
  var presetID: UUID?
  var format: OutputFormat = .keep
  var width: Int?
  var quality: Int?
  var filter: FilterType?
  var codec: Codec?
  /// What resizing means. Starts from the general preference in Settings and
  /// can be changed for this batch alone.
  var fitMode: ResizeFitMode = .proportional
  /// A ceiling on the finished file, in bytes.
  var maxBytes: Int?
  /// Answers to the chosen preset's questions, by the parameter's key.
  var answers: [String: Double] = [:]
  /// The language for OCR and transcription. `nil` means let the system decide.
  var language: String?
  var destinationMode: DestinationMode = .copyTo
  var destinationURL: URL?

  var wantsText: Bool { format.type?.conforms(to: .plainText) == true }

  var needsDestination: Bool { destinationMode != .overwrite }

  /// The actions to run when no preset is in charge, in the order they run.
  var customActions: [Operation] {
    var actions: [Operation] = []
    if let type = format.type { actions.append(.convertFormat(to: type)) }
    if let width { actions.append(.resize(width: width, height: nil, fitMode: fitMode)) }
    if let quality { actions.append(.quality(level: quality)) }
    if let filter { actions.append(.filter(type: filter)) }
    if let codec { actions.append(.encode(codec: codec)) }
    if let maxBytes { actions.append(.limitSize(bytes: maxBytes)) }
    if wantsText { actions.append(.recognizeText(languages: language.map { [$0] } ?? [])) }
    return actions
  }

  /// The preset to hand the coordinator: the chosen one as it stands, or one
  /// assembled from the fields for this batch alone.
  func resolved(against presets: [RulePreset]) -> RulePreset? {
    if let presetID, let preset = presets.first(where: { $0.id == presetID }) {
      guard !preset.parameters.isEmpty else { return preset }
      // A preset that asks questions is finished by the answers: each one
      // becomes the action it stands for, and the answers travel along so the
      // filename can say what was asked for.
      var answered = preset
      for parameter in preset.parameters {
        let value = answers[parameter.key] ?? parameter.defaultValue
        answered = answered.replacing(parameter.operation(for: value))
        answered.parameterValues[parameter.key] = value
      }
      return answered
    }
    let actions = customActions
    guard !actions.isEmpty else { return nil }
    return RulePreset(name: "This batch", description: "", category: .custom, actions: actions)
  }
}

/// The Convert sheet: what these files should become, with only the controls
/// the files in hand can actually honour.
///
/// A PDF is offered pages, filters and a voice; a video is offered a codec and
/// a resolution; a CSV is offered nothing but another data format, because
/// `DataProcessor` refuses everything else. A control that is offered and then
/// ignored is worse than one that is missing: it makes the app look like it did
/// something it did not do.
struct ConvertOptionsSheet: View {
  @Environment(\.dismiss) private var dismiss

  let kinds: Set<ConvertKind>
  let fileCount: Int
  let totalSize: Int64
  let presets: [RulePreset]
  @Binding var choice: ConvertChoice
  let onConvert: () -> Void

  /// The one kind in the batch, or nil when the batch is mixed. Per-kind
  /// controls need a single kind to be about.
  private var kind: ConvertKind? { kinds.count == 1 ? kinds.first : nil }

  private var canConvert: Bool {
    guard choice.presetID != nil || !choice.customActions.isEmpty else { return false }
    return !choice.needsDestination || choice.destinationURL != nil
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView { fields.padding(24) }
      Divider()
      footer
    }
    .frame(width: 680, height: 600)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: kind?.icon ?? "square.on.square")
        .font(.system(size: 26, weight: .light))
        .foregroundStyle(.tint)
        .frame(width: 34)

      VStack(alignment: .leading, spacing: 2) {
        Text(headline).font(.title3.weight(.semibold))
        Text(subhead).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }

  private var headline: String {
    guard let kind else {
      return fileCount == 1 ? "1 file" : "\(fileCount) files"
    }
    return fileCount == 1 ? "1 \(kind.title)" : "\(fileCount) \(kind.plural)"
  }

  private var subhead: String {
    let size = totalSize.formatted(.byteCount(style: .file))
    guard kind == nil else { return "\(size) in all" }
    let names = kinds.sorted { $0.rawValue < $1.rawValue }.map(\.plural).joined(separator: " and ")
    return "\(names) together · \(size) in all"
  }

  // MARK: - Fields

  @ViewBuilder
  private var fields: some View {
    VStack(alignment: .leading, spacing: 22) {
      if !offeredPresets.isEmpty { presetField }

      if let preset = chosenPreset, !preset.parameters.isEmpty {
        parameterFields(preset)
      }

      if let kind {
        formatField(for: kind)
        if kind.supportsResize, !choice.wantsText { widthField }
        if kind.supportsResize, !choice.wantsText { fitField }
        if kind.supportsQuality, !choice.wantsText { qualityField }
        if kind.supportsSizeLimit, !choice.wantsText { ceilingField }
        if kind.supportsCodec, !choice.wantsText { codecField(for: kind) }
        if kind.supportsFilter, !choice.wantsText { filterField }
        if kind.supportsTextExtraction, choice.wantsText { languageField }
      } else {
        mixedNote
      }

      destinationField
    }
  }

  /// Presets for what was dropped. A mixed batch sees the presets for every
  /// kind in it, since each file goes to its own processor anyway.
  private var offeredPresets: [RulePreset] {
    let categories = Set(kinds.map(\.presetCategory))
    let fitting = presets.filter { categories.contains($0.category) || $0.category == .custom }
    return fitting.isEmpty ? presets : fitting
  }

  private var presetField: some View {
    field("Start from") {
      chips {
        chip("Nothing", selected: choice.presetID == nil) {
          choice.presetID = nil
        }
        ForEach(offeredPresets) { preset in
          chip(preset.name, selected: choice.presetID == preset.id) { load(preset) }
        }
      }
    }
  }

  private func formatField(for kind: ConvertKind) -> some View {
    field("Become") {
      VStack(alignment: .leading, spacing: 10) {
        chips {
          chip("Same format", selected: choice.format.type == nil) {
            edit { $0.format = .keep }
          }
        }
        ForEach(kind.outputGroups.filter { !$0.formats.isEmpty }) { group in
          VStack(alignment: .leading, spacing: 5) {
            Text(group.title)
              .font(.caption)
              .foregroundStyle(.tertiary)
            chips {
              ForEach(group.formats) { format in
                chip(format.label, selected: choice.format == format) {
                  edit { $0.format = format }
                }
              }
            }
          }
        }
      }
    }
  }

  private var widthField: some View {
    field("Width") {
      chips {
        chip("As they are", selected: choice.width == nil) { edit { $0.width = nil } }
        ForEach(Self.widths, id: \.self) { width in
          chip("\(width) px", selected: choice.width == width) { edit { $0.width = width } }
        }
        HStack(spacing: 6) {
          TextField("Custom", text: Binding(
            get: { choice.width.map(String.init) ?? "" },
            set: { text in
              let value = Int(text.trimmingCharacters(in: .whitespaces))
              edit { $0.width = (value ?? 0) > 0 ? value : nil }
            }
          ))
          .frame(width: 72)
          Text("px").foregroundStyle(.secondary).font(.callout)
        }
      }
    }
  }

  private var chosenPreset: RulePreset? {
    guard let id = choice.presetID else { return nil }
    return presets.first { $0.id == id }
  }

  /// What a preset asks for, asked here. A preset that wants a size ceiling is
  /// a shape rather than a setting, and this is where it is filled in.
  private func parameterFields(_ preset: RulePreset) -> some View {
    field("\(preset.name) asks") {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(preset.parameters) { parameter in
          HStack(spacing: 10) {
            Text(parameter.label.isEmpty ? parameter.kind.title : parameter.label)
              .frame(width: 150, alignment: .leading)
              .foregroundStyle(.secondary)

            TextField(parameter.kind.title, text: Binding(
              get: {
                let value = choice.answers[parameter.key] ?? parameter.defaultValue
                return String(format: "%g", value)
              },
              set: { text in
                let typed = Double(text.replacingOccurrences(of: ",", with: ".")) ?? parameter.defaultValue
                choice.answers[parameter.key] = min(max(typed, parameter.kind.range.lowerBound), parameter.kind.range.upperBound)
              }
            ))
            .frame(width: 90)

            if !parameter.kind.unit.isEmpty {
              Text(parameter.kind.unit).foregroundStyle(.secondary)
            }

            Text("{\(parameter.key)}")
              .font(.caption.monospaced())
              .foregroundStyle(.tertiary)
              .help("Use this in a name template to spend the answer in the filename")
          }
        }
      }
    }
  }

  /// What resizing means. Starts from the general preference and is overridden
  /// here for this batch alone.
  private var fitField: some View {
    field("Fit") {
      chips {
        ForEach(ResizeFitMode.allCases, id: \.self) { mode in
          chip(mode.title, selected: choice.fitMode == mode) { edit { $0.fitMode = mode } }
        }
      }
    }
  }

  /// A promise about the finished file rather than a setting for the encoder.
  private var ceilingField: some View {
    field("Fit within a size") {
      HStack(spacing: 10) {
        Toggle("No ceiling", isOn: Binding(
          get: { choice.maxBytes == nil },
          set: { none in edit { $0.maxBytes = none ? nil : 10_000_000 } }
        ))
        .toggleStyle(.checkbox)

        if let maxBytes = choice.maxBytes {
          TextField("Megabytes", text: Binding(
            get: { String(format: "%g", Double(maxBytes) / 1_000_000) },
            set: { text in
              let megabytes = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
              edit { $0.maxBytes = megabytes > 0 ? Int(megabytes * 1_000_000) : nil }
            }
          ))
          .frame(width: 80)
          Text("MB").foregroundStyle(.secondary)
        }
      }
    }
  }

  private var qualityField: some View {
    field("Quality") {
      HStack(spacing: 12) {
        Toggle("Leave it to Forge", isOn: Binding(
          get: { choice.quality == nil },
          set: { isDefault in edit { $0.quality = isDefault ? nil : ImageProcessor.defaultQuality } }
        ))
        .toggleStyle(.checkbox)

        if let quality = choice.quality {
          Slider(
            value: Binding(
              get: { Double(quality) },
              set: { value in edit { $0.quality = Int(value) } }
            ),
            in: 1...100,
            step: 1
          )
          .frame(width: 220)
          Text("\(quality)")
            .monospacedDigit()
            .frame(width: 30, alignment: .leading)
        }
      }
    }
  }

  private func codecField(for kind: ConvertKind) -> some View {
    let codecs = kind == .video ? Codec.videoCodecs : Codec.audioCodecs
    return field("Codec") {
      chips {
        chip("Whatever fits", selected: choice.codec == nil) { edit { $0.codec = nil } }
        ForEach(codecs, id: \.self) { codec in
          chip(codec.title, selected: choice.codec == codec) { edit { $0.codec = codec } }
        }
      }
    }
  }

  private var filterField: some View {
    field("Look") {
      chips {
        chip("Untouched", selected: choice.filter == nil) { edit { $0.filter = nil } }
        ForEach(FilterType.allCases, id: \.self) { filter in
          chip(filter.rawValue.capitalized, selected: choice.filter == filter) {
            edit { $0.filter = filter }
          }
        }
      }
    }
  }

  private var languageField: some View {
    field("Language") {
      chips {
        chip("Work it out", selected: choice.language == nil) { edit { $0.language = nil } }
        ForEach(TextRecognizer.supportedLanguages, id: \.self) { language in
          chip(language, selected: choice.language == language) { edit { $0.language = language } }
        }
      }
    }
  }

  private var mixedNote: some View {
    field("These files") {
      Text("More than one kind was dropped, and each kind takes different settings. Pick a preset above, or drop one kind at a time to set the format, size and quality by hand.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var destinationField: some View {
    field("Where they go") {
      VStack(alignment: .leading, spacing: 10) {
        chips {
          ForEach(DestinationMode.allCases, id: \.self) { mode in
            chip(mode.displayName, selected: choice.destinationMode == mode) {
              choice.destinationMode = mode
            }
          }
        }
        if choice.needsDestination {
          Button {
            chooseDestination()
          } label: {
            Label(choice.destinationURL?.path ?? "Choose a folder…", systemImage: "folder")
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        if choice.destinationMode == .overwrite {
          Text("The originals are replaced.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Text(plan)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(plan)

      Spacer(minLength: 12)

      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button {
        dismiss()
        onConvert()
      } label: {
        Text("Convert").frame(minWidth: 76)
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(!canConvert)
    }
    .padding(20)
  }

  /// What Convert will do, said once in the order it matters: how much, what
  /// changes, where it lands.
  private var plan: String {
    guard let preset = choice.resolved(against: presets) else {
      return "Choose what they should become"
    }

    var parts = [fileCount == 1 ? "1 file" : "\(fileCount) files"]
    let chain = preset.actions.map(PresetCard.chip).joined(separator: " · ")
    if !chain.isEmpty { parts.append(chain) }

    switch choice.destinationMode {
    case .overwrite:
      parts.append("replacing the originals")
    case .moveTo, .copyTo:
      if let url = choice.destinationURL { parts.append("into \(url.lastPathComponent)") }
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Pieces

  private static let widths = [1080, 1280, 1920, 2048]

  /// Every control drops the preset: from the first change onwards the fields
  /// are the truth, and leaving the preset selected would claim otherwise.
  private func edit(_ change: (inout ConvertChoice) -> Void) {
    var updated = choice
    change(&updated)
    updated.presetID = nil
    choice = updated
  }

  /// Fill the fields with what a preset says, so it reads as a starting point
  /// that can be adjusted rather than a black box.
  private func load(_ preset: RulePreset) {
    var updated = choice
    updated.format = .keep
    updated.width = nil
    updated.quality = nil
    updated.filter = nil
    updated.codec = nil
    updated.language = nil

    for action in preset.actions {
      switch action {
      case .convertFormat(let to): updated.format = OutputFormat(type: to)
      case .resize(let width, _, _): updated.width = width
      case .quality(let level): updated.quality = level
      case .filter(let type): updated.filter = type
      case .encode(let codec): updated.codec = codec
      case .recognizeText(let languages): updated.language = languages.first
      case .limitSize(let bytes): updated.maxBytes = bytes
      }
    }

    updated.presetID = preset.id
    choice = updated
  }

  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func chips<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    // A wrapping row: the format lists are long enough that a single line
    // would push the far end off the sheet.
    FlowLayout(spacing: 6) { content() }
  }

  private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.accentColor : Color.secondary.opacity(0.14))
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
    // A styled Text inside a plain button reaches the accessibility tree as an
    // unnamed button, so the name is said here rather than left to chance.
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  private func chooseDestination() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    if panel.runModal() == .OK { choice.destinationURL = panel.url }
  }
}

/// Lays out chips left to right, wrapping onto a new line when the row is full.
/// `LazyVGrid` cannot do it: its columns are fixed, and these are as wide as
/// the words inside them.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let rows = arrange(subviews, in: width)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(subviews, in: bounds.width) {
      var x = bounds.minX
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y),
          anchor: .topLeading,
          proposal: ProposedViewSize(item.size)
        )
        x += item.size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var items: [(index: Int, size: CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var row = Row()

    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
      if !row.items.isEmpty, needed > width {
        rows.append(row)
        row = Row()
      }
      row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.items.append((index, size))
    }
    if !row.items.isEmpty { rows.append(row) }
    return rows
  }
}
