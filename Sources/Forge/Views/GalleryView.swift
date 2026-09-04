import AppKit
import SwiftUI

/// Presets other people have published.
struct GalleryView: View {
  @EnvironmentObject private var model: AppModel
  @State private var entries: [PresetGallery.Entry] = []
  @State private var loading = true
  @State private var failure: String?
  @State private var installed: Set<String> = []

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
        list
      }
    }
    .navigationTitle("Gallery")
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

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        Text("A preset is a name and a list of actions Forge already knows how to run. Installing one cannot make it do anything new.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.bottom, 4)

        ForEach(entries) { entry in
          row(entry)
        }
      }
      .padding(20)
    }
  }

  private func row(_ entry: PresetGallery.Entry) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: entry.preset.category.icon)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 26)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(entry.preset.name).font(.callout.weight(.semibold))
          Text("by \(entry.author)").font(.caption).foregroundStyle(.secondary)
        }
        Text(entry.summary).font(.callout).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          ForEach(entry.preset.actions.map(PresetCard.chip), id: \.self) { chip in
            Text(chip)
              .font(.caption2)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
          }
        }
      }

      Spacer(minLength: 0)

      Button(installed.contains(entry.id) ? "Added" : "Add") {
        model.install(entry.preset)
        installed.insert(entry.id)
      }
      .disabled(installed.contains(entry.id))
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
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
