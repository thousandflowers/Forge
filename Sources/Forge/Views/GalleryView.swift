import AppKit
import SwiftUI

/// Presets other people have published.
struct GalleryView: View {
  @EnvironmentObject private var model: AppModel
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
    .navigationTitle("Gallery")
    .searchable(text: $search, placement: .toolbar, prompt: "Search presets")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          NSWorkspace.shared.open(GalleryView.contributeURL)
        } label: {
          Label("Share Yours", systemImage: "square.and.arrow.up")
        }
        .help("Open the gallery file on GitHub to add one")
      }
    }
    .task { await load() }
  }

  static let contributeURL = URL(
    string: "https://github.com/thousandflowers/Forge/blob/main/Gallery/presets.json"
  )!

  // MARK: - Browsing

  private var browser: some View {
    VStack(spacing: 0) {
      filterBar
      Divider()
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
      if categories.count > 1 {
        Picker("Type", selection: $category) {
          Text("Any type").tag(PresetCategory?.none)
          ForEach(categories, id: \.self) { category in
            Text(category.rawValue.capitalized).tag(Optional(category))
          }
        }
        .pickerStyle(.menu).fixedSize()
      }

      if bands.count > 1 {
        Picker("Size", selection: $band) {
          Text("Any size").tag(SizeBand?.none)
          ForEach(bands, id: \.self) { band in
            Text(band.title).tag(Optional(band))
          }
        }
        .pickerStyle(.menu).fixedSize()
      }

      if topics.count > 1 {
        Picker("Topic", selection: $topic) {
          Text("Any topic").tag(String?.none)
          ForEach(topics, id: \.self) { topic in
            Text(topic.capitalized).tag(Optional(topic))
          }
        }
        .pickerStyle(.menu).fixedSize()
      }

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
    haystack.append(contentsOf: entry.preset.actions.map(PresetCard.chip))

    return haystack.contains { $0.lowercased().contains(needle) }
  }

  // MARK: - One card

  private func card(_ entry: PresetGallery.Entry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Image(systemName: entry.preset.category.icon)
          .font(.title3)
          .foregroundStyle(.tint)
        Spacer()
        // One share button per entry, next to that entry's own download.
        Button {
          share(entry.preset)
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Share “\(entry.preset.name)”")
        .accessibilityLabel(Text("Share \(entry.preset.name)"))

        Button(isInstalled(entry) ? "Added" : "Add") {
          model.install(entry.preset)
        }
        .disabled(isInstalled(entry))
        .help(isInstalled(entry) ? "Already in your presets" : "Add “\(entry.preset.name)” to your presets")
      }

      Text(entry.preset.name)
        .font(.headline)
        .lineLimit(2)
      Text("by \(entry.author)")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(entry.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer(minLength: 6)

      chipRow(entry.preset.actions.map(PresetCard.chip), tint: Color.secondary.opacity(0.12))
      if let tags = entry.tags, !tags.isEmpty {
        chipRow(tags, tint: Color.accentColor.opacity(0.16))
      }
    }
    .padding(14)
    // A minimum rather than a fixed height: the cards still line up, without
    // the hole a fixed height leaves under a short summary.
    .frame(minHeight: 172, alignment: .top)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
  }

  private func chipRow(_ titles: [String], tint: Color) -> some View {
    FlowLayout(spacing: 5) {
      ForEach(titles, id: \.self) { title in
        Text(title)
          .font(.caption2)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(RoundedRectangle(cornerRadius: 4).fill(tint))
      }
    }
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
      entries = try await PresetGallery().entries()
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
