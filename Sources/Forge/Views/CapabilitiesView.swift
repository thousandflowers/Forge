import AppKit
import SwiftUI

/// What this Mac can do, and what it cannot.
///
/// Doubles as the answer to "which formats does Forge support": the list is
/// computed from the frameworks at run time, so it describes the machine it is
/// running on rather than a claim written months ago.
struct CapabilitiesView: View {
  private let columns = [GridItem(.adaptive(minimum: 250), spacing: 16)]

  @State private var search = ""
  @State private var kind: Capability.Status.Kind?
  /// How many files of each extension this Mac holds, once it has been asked.
  @State private var census: [String: Int] = [:]
  @State private var scanning = false
  @State private var hasScanned = false
  @ObservedObject private var installer = ToolInstaller.shared

  var body: some View {
    VStack(spacing: 0) {
      filterBar
      Divider()
      if visible.isEmpty {
        EmptyStateView(
          icon: "magnifyingglass",
          title: "Nothing matches",
          message: "No tool fits what you are looking for.",
          actionTitle: "Clear Filters",
          action: clearFilters
        )
      } else {
        list
      }
    }
    .searchable(text: $search, placement: .toolbar, prompt: "Search tools")
    // What comes from somewhere else is said once, with where from and how much,
    // before it is fetched. Everything after that happens in here.
    .confirmsToolInstalls(with: installer)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          ExternalTools.forgetWhatWasFound()
          Task { await scan() }
        } label: {
          Label(hasScanned ? "Look Again" : "Suggest from My Files", systemImage: "sparkle.magnifyingglass")
            .labelStyle(.titleAndIcon)
        }
        .disabled(scanning)
        .help("Look at the kinds of file you have, and put what would help first")
      }
    }
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 22) {
        if scanning {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Looking at what you have…").foregroundStyle(.secondary)
          }
        } else if !suggested.isEmpty {
          section("Suggested for your files", suggested, showEvidence: true)
        } else if hasScanned {
          Text("Nothing on this Mac needs a tool Forge is missing.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        ForEach(Capability.Status.Kind.allCases, id: \.self) { kind in
          let matching = visible.filter { capability in
            capability.status.kind == kind && !suggested.contains(capability)
          }
          if !matching.isEmpty {
            section(kind.title, matching, showEvidence: false)
          }
        }
      }
      .padding(20)
    }
  }

  private var filterBar: some View {
    HStack(spacing: 10) {
      Picker("Status", selection: $kind) {
        Text("Anything").tag(Capability.Status.Kind?.none)
        ForEach(Capability.Status.Kind.allCases, id: \.self) { kind in
          Text(kind.title).tag(Optional(kind))
        }
      }
      .pickerStyle(.menu).fixedSize()

      if isFiltered {
        Button("Clear", action: clearFilters)
      }

      Spacer()

      Text(countLabel)
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  private var isFiltered: Bool { kind != nil || !search.isEmpty }

  private func clearFilters() {
    kind = nil
    search = ""
  }

  private var countLabel: String {
    isFiltered
      ? "\(visible.count) of \(Capabilities.all.count)"
      : "\(Capabilities.all.count) in all"
  }

  // MARK: - What to show

  private var visible: [Capability] {
    Capabilities.all.filter { capability in
      if let kind, capability.status.kind != kind { return false }
      return matches(capability, search)
    }
  }

  /// The capabilities the files on this Mac argue for, most-wanted first.
  /// Empty until the scan is asked for: looking through somebody's folders
  /// uninvited is not a thing to do quietly.
  private var suggested: [Capability] {
    guard !census.isEmpty else { return [] }
    return visible
      .map { ($0, evidenceCount(for: $0)) }
      .filter { $0.1 > 0 }
      .sorted { $0.1 > $1.1 }
      .map(\.0)
  }

  private func evidenceCount(for capability: Capability) -> Int {
    capability.evidence.reduce(0) { $0 + (census[$1.lowercased()] ?? 0) }
  }

  private func matches(_ capability: Capability, _ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return true }

    var haystack = [capability.title, capability.summary, capability.status.kind.title]
    haystack.append(contentsOf: capability.evidence)
    switch capability.status {
    case .available(let detail):
      haystack.append(detail)
    case .installable(let install):
      haystack.append(install.adds)
    case .needsPack(let pack):
      haystack.append(pack.name)
      if let tool = pack.tool { haystack.append(contentsOf: [tool.binary, tool.name, tool.adds]) }
    case .unavailable(let reason):
      haystack.append(reason)
    case .planned:
      break
    }

    return haystack.contains { $0.lowercased().contains(needle) }
  }

  private func scan() async {
    scanning = true
    let wanted = Set(Capabilities.all.flatMap(\.evidence))
    census = await FileCensus.counts(of: wanted)
    scanning = false
    hasScanned = true
  }

  @ViewBuilder
  private func section(_ title: String, _ capabilities: [Capability], showEvidence: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      LazyVGrid(columns: columns, spacing: 16) {
        ForEach(capabilities) { capability in
          CapabilityCard(
            capability: capability,
            evidence: showEvidence ? evidenceCount(for: capability) : 0,
            installer: installer
          )
        }
      }
    }
  }
}

private struct CapabilityCard: View {
  let capability: Capability
  /// How many files on this Mac argue for it. Zero means do not mention it.
  var evidence: Int = 0
  @ObservedObject var installer: ToolInstaller

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        BlockIcon(symbol: capability.symbol, tint: tint, size: 30)
        Text(capability.title)
          .font(.headline)
          .lineLimit(1)
        Spacer(minLength: 4)
        if saysMore { badge }
      }

      Text(capability.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      if evidence > 0 {
        Text("\(evidence) file\(evidence == 1 ? "" : "s") on this Mac")
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.accentColor)
      }

      Spacer(minLength: 6)

      detail
    }
    .padding(14)
    // A minimum, not a fixed height: a fixed one left a hole under every short
    // summary and clipped the long ones.
    .frame(minHeight: 150, alignment: .top)
    .forgeCard()
  }

  @ViewBuilder
  private var detail: some View {
    switch capability.status {
    case .available(let detail):
      caption(detail)

    case .installable(let install):
      VStack(alignment: .leading, spacing: 8) {
        caption(install.adds)
        Button(install.action) { NSWorkspace.shared.open(install.settings) }
          .controlSize(.small)
      }

    case .planned:
      EmptyView()

    case .needsPack(let pack):
      packDetail(pack)

    case .unavailable(let reason):
      caption(reason)
    }
  }

  /// A pack is a tool Forge does not ship. What is said here is exactly what is
  /// true: whether this Mac has the tool, whose copy it is, and whether Forge
  /// calls it. Those are three different facts, and running them together
  /// would promise a conversion that does not happen.
  @ViewBuilder
  private func packDetail(_ pack: Capability.Pack) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let tool = pack.tool {
        toolDetail(tool, wired: pack.isWired)
      } else {
        caption("\(pack.name): needs \(pack.requires), about \(pack.approximateSize).")
      }
    }
  }

  @ViewBuilder
  private func toolDetail(_ tool: ExternalTool, wired: Bool) -> some View {
    switch installer.state(of: tool.binary) {
    case .running(let line):
      ToolProgress(tool: tool, share: line)

    case .failed(let reason):
      VStack(alignment: .leading, spacing: 6) {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
        retry(tool)
      }

    case .idle, .installed:
      settled(tool, wired: wired)
    }
  }

  /// The card when nothing is happening to the tool.
  @ViewBuilder
  private func settled(_ tool: ExternalTool, wired: Bool) -> some View {
    if tool.isInstalled {
      caption(wired
        ? "\(tool.name) is here, and Forge uses it for \(tool.adds)."
        : "\(tool.name) is here. Forge does not call it yet.")
      if Toolbox.shared.has(tool.name) {
        Button("Remove") { installer.remove(tool) }
          .controlSize(.small)
          .help("Delete the copy Forge downloaded")
      }
    } else {
      VStack(alignment: .leading, spacing: 6) {
        caption("\(tool.name) adds \(tool.adds).")
        Button("Download, \(tool.weight)…") { installer.ask(tool) }
          .controlSize(.small)
      }
    }
  }

  private func retry(_ tool: ExternalTool) -> some View {
    Button("Try Again") { installer.ask(tool) }
      .controlSize(.small)
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The heading over the cards says what they all are; a badge is for the one
  /// that is something else.
  private var saysMore: Bool {
    switch capability.status {
    case .needsPack(let pack): return pack.tool?.isInstalled == true && !pack.isWired
    default: return false
    }
  }

  private var badge: some View {
    label("Installed", .orange)
  }

  private func label(_ text: String, _ color: Color) -> some View { Tag(text: text, tint: color) }

  private var tint: Color {
    switch capability.status {
    case .unavailable, .planned: return .gray
    default: return capability.status.kind == .ready ? .green : .accentColor
    }
  }
}

extension Capability.Status {
  /// The shelves the list is sorted onto, and what the filter offers.
  enum Kind: String, CaseIterable, Hashable {
    case needsTool
    case addFromMacOS
    case ready
    case coming
    case notPossible

    var title: String {
      switch self {
      case .ready: return "Ready on this Mac"
      case .addFromMacOS: return "Add from macOS"
      case .needsTool: return "Can be added"
      case .coming: return "Coming"
      case .notPossible: return "Not possible on macOS"
      }
    }
  }

  var kind: Kind {
    switch self {
    case .available: return .ready
    case .installable: return .addFromMacOS
    case .planned: return .coming
    case .needsPack(let pack): return pack.tool?.isInstalled == true && pack.isWired ? .ready : .needsTool
    case .unavailable: return .notPossible
    }
  }
}


