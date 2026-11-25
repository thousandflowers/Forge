import AppKit
import SwiftUI

/// Where presets and tools come from, in one place.
struct StoreView: View {
  enum Shelf: String, CaseIterable {
    case presets = "Presets", tools = "Tools"
  }

  @AppStorage("storeShelf") private var shelf = Shelf.presets

  var body: some View {
    VStack(spacing: 0) {
      // Not in the title bar, which cut its ends off.
      Picker("Show", selection: $shelf) {
        ForEach(Shelf.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 220)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20)
      .padding(.top, 14)
      switch shelf {
      case .presets: GalleryView()
      case .tools: CapabilitiesView()
      }
    }
    .navigationTitle("Store")
  }
}

/// Presets other people have published.
struct GalleryView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var installer = ToolInstaller.shared
  @State private var entries: [PresetGallery.Entry] = []
  @State private var loading = true
  @State private var failure: String?
  /// Whether a gallery preset is already in the user's own list is a fact
  /// about the list, not about this screen. It used to be `@State`, so leaving
  /// the Gallery and coming back showed "Add" again on something already
  /// added - and adding it a second time gave two presets with one name.
  private func isInstalled(_ entry: PresetGallery.Entry) -> Bool {
    model.presets.contains { $0.name == entry.preset.name }
  }

  @State private var search = ""
  /// `nil` on any of these means "do not narrow by this".
  @State private var category: PresetCategory?
  @State private var band: SizeBand?
  @State private var topic: String?

  var body: some View {
    Group {
      if loading {
        ProgressView("Fetching presets…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let failure {
        EmptyStateView(
          icon: "wifi.slash",
          title: "Could not fetch the gallery",
          message: failure,
          actionTitle: "Try Again",
          action: { Task { await load() } }
        )
      } else if entries.isEmpty {
        EmptyStateView(
          icon: "square.grid.2x2",
          title: "Nothing here yet",
          message: "No published preset runs on this Mac."
        )
      } else {
        browser
      }
    }
    .confirmsToolInstalls(with: installer)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        // The editor covers what it is about.
        if model.presetEditor == nil {
          Button {
            NSWorkspace.shared.open(GalleryView.contributeURL)
          } label: {
            Label("Share Yours", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
          }
          .help("Open the gallery file on GitHub to add one")
        }
      }
    }
    .task { await load() }
  }

  static let contributeURL = URL(
    string: "https://github.com/thousandflowers/Forge/blob/main/Gallery/presets.json"
  )!

  private static let fewEnough = 12

  // MARK: - Browsing

  private var browser: some View {
    VStack(spacing: 0) {
      filterBar
      if visible.isEmpty {
        EmptyStateView(
          icon: "magnifyingglass",
          title: "Nothing matches",
          message: "No published preset fits what you are looking for.",
          actionTitle: "Clear Filters",
          action: clearFilters
        )
      } else {
        grid
      }
    }
  }

  private var grid: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
        ForEach(visible) { entry in
          card(entry)
        }
      }
      .padding(20)
    }
  }

  /// The narrowing controls, built from what is actually in the list: a filter
  /// with one option is not a choice, so it is not shown.
  private var filterBar: some View {
    HStack(spacing: 10) {
      SearchField(prompt: "Search presets", text: $search).frame(maxWidth: 260)
      // A few are looked at; only many are narrowed.
      if entries.count >= Self.fewEnough { filters }
      Spacer()
      Text(countLabel)
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, 20)
    .padding(.top, 14)
    .padding(.bottom, 2)
  }

  private var filters: some View {
    HStack(spacing: 10) {
      if categories.count > 1 {
        Picker("Type", selection: $category) {
          Text("Any type").tag(PresetCategory?.none)
          ForEach(categories, id: \.self) { category in
            Text(category.rawValue.capitalized).tag(Optional(category))
          }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
      }

      if bands.count > 1 {
        Picker("Size", selection: $band) {
          Text("Any size").tag(SizeBand?.none)
          ForEach(bands, id: \.self) { band in
            Text(band.title).tag(Optional(band))
          }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
      }

      if topics.count > 1 {
        Picker("Topic", selection: $topic) {
          Text("Any topic").tag(String?.none)
          ForEach(topics, id: \.self) { topic in
            Text(topic.capitalized).tag(Optional(topic))
          }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
      }

      if isFiltered {
        Button("Clear", action: clearFilters)
      }
    }
  }

  private var countLabel: String {
    guard isFiltered || !search.isEmpty else {
      return entries.count == 1 ? "1 preset" : "\(entries.count) presets"
    }
    return "\(visible.count) of \(entries.count)"
  }

  private var isFiltered: Bool { category != nil || band != nil || topic != nil }

  private func clearFilters() {
    category = nil
    band = nil
    topic = nil
    search = ""
  }

  // MARK: - What is on offer

  private var categories: [PresetCategory] {
    let present = Set(entries.map(\.preset.category))
    return PresetCategory.allCases.filter { present.contains($0) }
  }

  private var bands: [SizeBand] {
    let present = Set(entries.map { SizeBand(of: $0.preset) })
    return SizeBand.allCases.filter { present.contains($0) }
  }

  private var topics: [String] {
    Set(entries.flatMap { $0.tags ?? [] }).sorted()
  }

  /// What survives the search box and the three menus.
  private var visible: [PresetGallery.Entry] {
    entries.filter { entry in
      if let category, entry.preset.category != category { return false }
      if let band, SizeBand(of: entry.preset) != band { return false }
      if let topic, !(entry.tags ?? []).contains(topic) { return false }
      return matches(entry, search)
    }
  }

  /// Search reads everything written about an entry, including what it does:
  /// somebody typing "jpeg" means the action, not the prose.
  private func matches(_ entry: PresetGallery.Entry, _ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return true }

    var haystack = [
      entry.preset.name,
      entry.preset.description,
      entry.summary,
      entry.author,
      entry.preset.category.rawValue,
    ]
    haystack.append(contentsOf: entry.tags ?? [])
    haystack.append(contentsOf: entry.preset.actions.map(PresetChip.text))

    return haystack.contains { $0.lowercased().contains(needle) }
  }

  // MARK: - One card

  /// The card opens what it does; the button takes it as it is.
  private func card(_ entry: PresetGallery.Entry) -> some View {
    let tool = PresetGallery.toolNeeded(by: entry.preset)
    let offer = PresetOffer(isInstalled: isInstalled(entry), tool: tool)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        BlockIcon(symbol: entry.preset.category.icon, tint: entry.preset.category.tint, size: 30)
        VStack(alignment: .leading, spacing: 1) {
          Button { open(entry, offer) } label: { Text(entry.preset.name).font(.headline).lineLimit(1) }
            .buttonStyle(.plain)
            .help("See how it works")
          Text("by \(entry.author)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
      }

      // Two lines always, so every card keeps the same shape.
      Text(entry.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer(minLength: 4)

      HStack(spacing: 8) {
        TagRow(texts: entry.preset.actions.map(PresetChip.text), warning: tool.map { "Needs \($0.name)" })
        Spacer(minLength: 4)
        Button(offer.isInstalled ? "Installed" : "Install") { install(entry, offer) }
          .controlSize(.small)
          .disabled(offer.isInstalled)
          .accessibilityLabel(Text(offer.isInstalled ? "\(entry.preset.name), already added" : "\(offer.installTitle): \(entry.preset.name)"))
          .help(offer.isInstalled ? "Already in your presets" : offer.installTitle)
      }
    }
    .padding(14)
    // One height for every card: the user asked for them all the same.
    .frame(height: 138, alignment: .top)
    .forgeCard(lifts: true)
    .onTapGesture { open(entry, offer) }
    .contextMenu {
      Button("Open") { open(entry, offer) }
      Button("Share…") { share(entry.preset) }
    }
  }

  private func open(_ entry: PresetGallery.Entry, _ offer: PresetOffer) {
    model.presetEditor = PresetEditorRequest(preset: entry.preset, offer: offer)
  }

  private func install(_ entry: PresetGallery.Entry, _ offer: PresetOffer) {
    model.install(entry.preset)
    if let tool = offer.tool { installer.ask(tool) }
  }

  /// One preset to one file, named after it, the same way the Presets screen
  /// hands one over.
  private func share(_ preset: RulePreset) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(preset.name).json"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.export([preset], to: url)
  }

  private func load() async {
    loading = true
    failure = nil
    do {
      entries = ReadyWords.entries + ReadyTools.entries + (try await PresetGallery().entries())
    } catch {
      failure = error.localizedDescription
    }
    loading = false
  }
}

/// How big what a preset writes comes out, as something you can filter by.
///
/// Taken from the resize the preset carries, because that is the only size a
/// preset actually decides: what a file weighs afterwards depends on the file
/// that went in.
enum SizeBand: String, CaseIterable, Hashable {
  case keepsSize
  case upToSmall
  case upToMedium
  case larger

  /// The edges of the bands, along the longest side in pixels.
  private static let small = 1280
  private static let medium = 1920

  init(of preset: RulePreset) {
    let longest = preset.actions.compactMap { action -> Int? in
      guard case .resize(let width, let height, _) = action else { return nil }
      return max(width ?? 0, height ?? 0)
    }.max()

    guard let longest, longest > 0 else { self = .keepsSize; return }
    if longest <= Self.small {
      self = .upToSmall
    } else if longest <= Self.medium {
      self = .upToMedium
    } else {
      self = .larger
    }
  }

  var title: String {
    switch self {
    case .keepsSize: return "Keeps its size"
    case .upToSmall: return "Up to \(Self.small) px"
    case .upToMedium: return "Up to \(Self.medium) px"
    case .larger: return "Bigger than \(Self.medium) px"
    }
  }
}
