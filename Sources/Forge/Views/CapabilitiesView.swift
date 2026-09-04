import AppKit
import SwiftUI

/// What this Mac can do, and what it cannot.
///
/// Doubles as the answer to "which formats does Forge support": the list is
/// computed from the frameworks at run time, so it describes the machine it is
/// running on rather than a claim written months ago.
struct CapabilitiesView: View {
  private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

  @State private var search = ""
  @State private var kind: Capability.Status.Kind?
  /// How many files of each extension this Mac holds, once it has been asked.
  @State private var census: [String: Int] = [:]
  @State private var scanning = false
  @State private var hasScanned = false
  @StateObject private var installer = ToolInstaller()

  var body: some View {
    VStack(spacing: 0) {
      filterBar
      Divider()
      if visible.isEmpty {
        EmptyStateView(
          icon: "magnifyingglass",
          title: "Nothing matches",
          message: "No capability fits what you are looking for.",
          actionTitle: "Clear Filters",
          action: clearFilters
        )
      } else {
        list
      }
    }
    .navigationTitle("Capabilities")
    .searchable(text: $search, placement: .toolbar, prompt: "Search capabilities")
    // Installing writes to the user's Mac, so the exact command is shown once
    // before it runs. Everything after that happens in here.
    .confirmationDialog(
      installer.confirming.map { "Install \($0.formula)?" } ?? "",
      isPresented: Binding(
        get: { installer.confirming != nil },
        set: { if !$0 { installer.confirming = nil } }
      )
    ) {
      if let tool = installer.confirming {
        Button("Install") { installer.install(tool) }
        Button("Cancel", role: .cancel) { installer.confirming = nil }
      }
    } message: {
      if let tool = installer.confirming {
        Text("Forge will run “\(tool.installCommand)”. Homebrew installs it on your Mac; Forge neither ships nor hosts it.")
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          ExternalTools.forgetWhatWasFound()
          Task { await scan() }
        } label: {
          Label(hasScanned ? "Scan Again" : "Suggest From My Files", systemImage: "sparkle.magnifyingglass")
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
          Text("Nothing on this Mac needs a capability Forge is missing.")
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
      : "\(Capabilities.all.count) capabilities"
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
      if let tool = pack.tool { haystack.append(contentsOf: [tool.binary, tool.formula, tool.adds]) }
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
        Image(systemName: capability.symbol)
          .font(.title3)
          .foregroundStyle(tint)
        Spacer()
        badge
      }

      Text(capability.title)
        .font(.headline)
        .lineLimit(1)

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
    .frame(minHeight: 176, alignment: .top)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
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
  /// true: whether this Mac has the tool, and whether Forge calls it. Those are
  /// two different facts, and running them together would promise a conversion
  /// that does not happen.
  @ViewBuilder
  private func packDetail(_ pack: Capability.Pack) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let tool = pack.tool {
        if tool.isInstalled {
          caption(pack.isWired
            ? "\(tool.binary) is installed, and Forge uses it for \(tool.adds)."
            : "\(tool.binary) is installed. Forge does not call it yet.")
        } else {
          switch installer.state(of: tool) {
          case .installed:
            caption("\(tool.binary) is installed. Restart is not needed.")

          case .running(let line):
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text(line.isEmpty ? "Installing \(tool.formula)…" : line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

          case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
              Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
              Button("Try Again") { installer.confirming = tool }
                .controlSize(.small)
            }

          case .idle:
            VStack(alignment: .leading, spacing: 6) {
              caption("\(tool.binary) would add \(tool.adds). Forge neither ships nor hosts it — Homebrew installs it here.")
              if ExternalTools.hasHomebrew {
                Button("Install \(tool.formula)") { installer.confirming = tool }
                  .controlSize(.small)
              } else {
                caption("Homebrew is not here either, and installing that is a step Forge will not take for you. brew.sh has the one line.")
              }
            }
          }
        }
      } else {
        caption("\(pack.name): needs \(pack.requires), about \(pack.approximateSize).")
      }
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var badge: some View {
    switch capability.status {
    case .available: label("Available", .green)
    case .installable: label("Add", .accentColor)
    case .planned: label("Coming", .blue)
    case .needsPack(let pack):
      if pack.tool?.isInstalled == true {
        label(pack.isWired ? "Available" : "Installed", pack.isWired ? .green : .orange)
      } else {
        label("Needs a tool", .orange)
      }
    case .unavailable: label("Unavailable", .secondary)
    }
  }

  private func label(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(Capsule().fill(color.opacity(0.18)))
      .foregroundStyle(color)
  }

  private var tint: Color {
    switch capability.status {
    case .available, .installable: return .accentColor
    case .needsPack(let pack): return pack.tool?.isInstalled == true ? .accentColor : .secondary
    default: return .secondary
    }
  }
}

extension Capability.Status {
  /// The shelves the list is sorted onto, and what the filter offers.
  enum Kind: String, CaseIterable, Hashable {
    case ready
    case addFromMacOS
    case needsTool
    case coming
    case notPossible

    var title: String {
      switch self {
      case .ready: return "Ready to use"
      case .addFromMacOS: return "Add from macOS"
      case .needsTool: return "Needs a tool"
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


/// Installs the tools the Capabilities screen offers, and remembers how each
/// one is getting on.
///
/// Kept out of the cards so that a card redrawing — which happens on every
/// keystroke in the search box — cannot restart or lose an install.
@MainActor
final class ToolInstaller: ObservableObject {

  enum State: Equatable {
    case idle
    /// The last line Homebrew printed, so a long install shows signs of life.
    case running(String)
    case failed(String)
    case installed
  }

  @Published private(set) var states: [String: State] = [:]
  /// The tool waiting on a yes. Installing writes to the user's Mac, so it is
  /// asked once, with the exact command.
  @Published var confirming: ExternalTool?

  func state(of tool: ExternalTool) -> State { states[tool.binary] ?? .idle }

  func install(_ tool: ExternalTool) {
    confirming = nil
    states[tool.binary] = .running("")

    Task { [weak self] in
      do {
        try await ExternalTools.install(tool) { line in
          Task { @MainActor [weak self] in
            self?.states[tool.binary] = .running(line)
          }
        }
        self?.states[tool.binary] = .installed
      } catch {
        self?.states[tool.binary] = .failed(error.localizedDescription)
      }
    }
  }
}
