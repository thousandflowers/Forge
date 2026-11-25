import SwiftUI
import UniformTypeIdentifiers

/// Quick convert: what these files become and where they go, and nothing else.
///
/// Anything finer - a size, a quality, a filter - is the maker's, one press
/// away with the files already in it. Only what these files can really become
/// is offered: a format offered and then refused makes the app look like it
/// did something it did not do.
struct QuickConvertSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var installer = ToolInstaller.shared
  @State private var showsAllFormats = false
  @State private var showsAllTools = false

  let kinds: Set<ConvertKind>
  /// The files themselves, since what is offered depends on what each one is.
  let sources: [ProcessableFile]
  let presets: [RulePreset]
  @Binding var choice: ConvertChoice
  /// The last conversion of this kind of file, offered as one press.
  var sameAsLast: LastConversion? = nil
  var onSameAsLast: () -> Void = {}
  let onMore: () -> Void
  let onConvert: () -> Void

  /// The one kind in the batch, or nil when the batch is mixed. Formats need a
  /// single kind to be about.
  private var kind: ConvertKind? { kinds.count == 1 ? kinds.first : nil }

  private var canConvert: Bool {
    choice.resolved(against: presets) != nil && choice.hasDestination
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView { fields.padding(24) }
      Divider()
      footer
    }
    .frame(width: 680, height: 560)
    // The sheet is where an install is started, so it is where it is confirmed.
    .confirmsToolInstalls(with: installer)
    .translucentSheet()
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: kind?.icon ?? "square.on.square")
        .font(.system(size: 26, weight: .light))
        .foregroundStyle(.tint)
        .frame(width: 34)

      VStack(alignment: .leading, spacing: 2) {
        Text(headline).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
        Text(subhead).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }

  private var headline: String {
    let noun = sources.count == 1 ? (kind?.title ?? "file") : (kind?.plural ?? "files")
    let count = "\(sources.count) \(noun)"
    return sources.count == 1 ? "\(count) · \(sources[0].fileName)" : count
  }

  private var subhead: String {
    let size = sources.reduce(Int64(0)) { $0 + $1.fileSize }.formatted(.byteCount(style: .file))
    if sources.count == 1 {
      return sources[0].dimensions.map { "\(size) · \($0.width) × \($0.height)" } ?? size
    }
    guard kind == nil else { return "\(size) in all" }
    let names = kinds.sorted { $0.rawValue < $1.rawValue }.map(\.plural).joined(separator: " and ")
    return names.isEmpty ? "\(size) in all" : "\(names) together · \(size) in all"
  }

  // MARK: - Fields

  private var fields: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let kind { formatCard(for: kind) } else { mixedNote }
      if kind != nil { toolCard }
      if !presets.isEmpty { presetField }
      if choice.draft.parameters.contains(where: { $0.source == .prompt }) { questions }
      if !choice.steps.isEmpty {
        Text("Also: \(choice.steps.map(PresetChip.text).joined(separator: ", ")). Change it in More…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      card(title: "Goes to", symbol: "folder", tint: .gray) {
        DestinationPicker(mode: $choice.destinationMode, url: $choice.destinationURL, fileCount: sources.count)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func formatCard(for kind: ConvertKind) -> some View {
    let groups = kind.outputGroups(for: sources).filter { !$0.formats.isEmpty }
    let all = groups.flatMap(\.formats)
    let leading = kind.leading(of: all)
    // A format chosen from the long list stays on show once it is folded away.
    let chosen = all.filter { format in !leading.contains(format) && isChosen(format) }
    let tools = ToolOffers.missing(for: [kind])

    return card(title: "Comes out as", symbol: "arrow.triangle.2.circlepath", tint: LibraryEntry.Group.output.color) {
      VStack(alignment: .leading, spacing: 10) {
        if showsAllFormats {
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 5) {
              if groups.count > 1 { Text(group.title).font(.caption).foregroundStyle(.secondary) }
              formatChips(group.formats)
            }
          }
          // What a tool that is not here would add, with the button that adds
          // it. The formats appear above as soon as it is in.
          ForEach(tools, id: \.id) { tool in
            ToolOfferRow(tool: tool, because: "With \(tool.name): \(tool.adds).", installer: installer)
          }
        } else {
          formatChips(leading + chosen)
        }
        if leading.count < all.count || !tools.isEmpty {
          Button(showsAllFormats ? "Fewer formats" : "All formats…") { withAnimation(Motion.move) { showsAllFormats.toggle() } }
            .buttonStyle(.link)
        }
      }
    }
  }

  /// How many are shown before all of them are asked for.
  private static let fewTools = 6

  @ViewBuilder private var toolCard: some View {
    let all = Tool.all(for: sources)
    let few = Array(all.prefix(Self.fewTools))
    // What was chosen stays on show once the rest is folded away.
    let shown = showsAllTools ? all : few + all.dropFirst(Self.fewTools).filter(isChosen)
    if !all.isEmpty {
      card(title: "Do this to it", symbol: "wand.and.stars", tint: LibraryEntry.Group.transform.color) {
        VStack(alignment: .leading, spacing: 10) {
          FlowLayout(spacing: 6) {
            ForEach(shown, id: \.word) { tool in
              Chip(tool.title, selected: isChosen(tool), large: true) { choice = choice.toggling(tool) }
                .help("\(tool.kind.summary). In a file\u{2019}s name: _\(tool.word)")
            }
          }
          if all.count > few.count {
            Button(showsAllTools ? "Fewer" : "All \(all.count)…") { withAnimation(Motion.move) { showsAllTools.toggle() } }.buttonStyle(.link)
          }
        }
      }
    }
  }

  private func isChosen(_ tool: Tool) -> Bool { choice.draft.actions.contains(.tool(tool)) }

  private func formatChips(_ formats: [OutputFormat]) -> some View {
    FlowLayout(spacing: 6) {
      ForEach(formats) { format in
        Chip(format.label, selected: isChosen(format), large: true) {
          if let type = format.type { choice = choice.choosing(type) }
        }
      }
    }
  }

  private func isChosen(_ format: OutputFormat) -> Bool {
    format.type.map(choice.formats.contains) ?? false
  }

  private var presetField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(kind == nil ? "One of your presets" : "Or one of your presets")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
      FlowLayout(spacing: 6) {
        ForEach(presets) { preset in
          Chip(preset.name, selected: choice.presetID == preset.id) { choice = choice.adopting(preset) }
        }
      }
    }
  }

  /// What the chain asks for, asked here.
  private var questions: some View {
    card(title: "Asks each time", symbol: "questionmark.circle", tint: LibraryEntry.Group.ask.color) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(choice.draft.parameters.filter { $0.source == .prompt }) { parameter in
          HStack(spacing: 10) {
            Text(parameter.label.isEmpty ? parameter.kind.title : parameter.label)
              .frame(width: 150, alignment: .leading)
              .foregroundStyle(.secondary)
            TextField(parameter.kind.title, text: Binding(
              get: { String(format: "%g", choice.answers[parameter.key] ?? parameter.defaultValue) },
              set: { text in
                let typed = Double(text.replacingOccurrences(of: ",", with: ".")) ?? parameter.defaultValue
                choice.answers[parameter.key] = min(max(typed, parameter.kind.range.lowerBound), parameter.kind.range.upperBound)
              }
            ))
            .frame(width: 90)
            if !parameter.kind.unit.isEmpty { Text(parameter.kind.unit).foregroundStyle(.secondary) }
          }
        }
      }
    }
  }

  private var mixedNote: some View {
    VStack(alignment: .leading, spacing: 10) {
      // No kind at all is not "more than one": it is files Forge cannot open,
      // and the useful thing to say is what would open them.
      Text(kinds.isEmpty
        ? "Forge cannot open these yet."
        : "These are files of more than one kind, so there is no one format for them all. Pick a preset, press More…, or drop one kind at a time.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if kinds.isEmpty {
        let tools = Dictionary(grouping: sources.compactMap { ToolOffers.opener(for: $0.url) }, by: \.id).compactMap(\.value.first)
        ForEach(tools, id: \.id) { tool in
          ToolOfferRow(tool: tool, because: "\(tool.name) opens them. It adds \(tool.adds).", installer: installer)
        }
      }
    }
  }

  private func card<Content: View>(title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        BlockIcon(symbol: symbol, tint: tint, size: Metrics.iconSize)
        Text(title).font(.headline)
      }
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .forgeCard()
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(plan)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(plan)

      HStack(spacing: 12) {
        Button(moreTitle) {
          dismiss()
          onMore()
        }
        .disabled(kinds.isEmpty)

        Spacer(minLength: 12)

        if let last = sameAsLast {
          let chain = last.preset.actions.map(PresetChip.text).joined(separator: " · ")
          Button {
            dismiss()
            onSameAsLast()
          } label: {
            Text("Same as Last: \(chain)").lineLimit(1).truncationMode(.tail)
          }
          .help("Convert the way the last \(kind?.title ?? "file") was: \(chain)")
        }
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
    }
    .padding(20)
  }

  /// Says what is in there for these files, and nothing they cannot use.
  private var moreTitle: String {
    guard let kind else { return "More…" }
    let inside = [
      kind.supportsResize ? "resize" : nil,
      kind.supportsQuality ? "quality" : nil,
      kind.supportsFilter ? "filters" : nil,
      kind.supportsCodec ? "codec" : nil,
    ].compactMap { $0 }
    return inside.isEmpty ? "More…" : "More… (\(inside.joined(separator: ", ")))"
  }

  /// What Convert will do, said once in the order it matters: how much, what
  /// changes, where it lands.
  private var plan: String {
    guard let preset = choice.resolved(against: presets) else { return "Choose what they should become" }

    var parts = [sources.count == 1 ? "1 file" : "\(sources.count) files"]
    let chain = preset.actions.map(PresetChip.text).joined(separator: " · ")
    if !chain.isEmpty { parts.append(chain) }

    switch choice.destinationMode {
    case .overwrite:
      parts.append(sources.count == 1 ? "replacing the original" : "replacing the originals")
    case .moveTo, .copyTo:
      parts.append(choice.destinationURL.map { "into \($0.lastPathComponent)" } ?? "choose a folder")
    }
    return parts.joined(separator: " · ")
  }
}
