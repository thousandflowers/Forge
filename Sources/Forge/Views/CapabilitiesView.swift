import AppKit
import SwiftUI

/// What this Mac can do, and what it cannot.
///
/// Doubles as the answer to "which formats does Forge support": the list is
/// computed from the frameworks at run time, so it describes the machine it is
/// running on rather than a claim written months ago.
struct CapabilitiesView: View {
  private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 22) {
        section("Ready to use", of: { if case .available = $0 { return true } else { return false } })
        section("Add from macOS", of: { if case .installable = $0 { return true } else { return false } })
        section("Coming", of: { if case .planned = $0 { return true } else { return false } })
        section("Not included", of: { if case .needsPack = $0 { return true } else { return false } })
        section("Not possible on macOS", of: { if case .unavailable = $0 { return true } else { return false } })
      }
      .padding(20)
    }
    .navigationTitle("Capabilities")
  }

  @ViewBuilder
  private func section(_ title: String, of matches: (Capability.Status) -> Bool) -> some View {
    let capabilities = Capabilities.all.filter { matches($0.status) }
    if !capabilities.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.headline)
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(capabilities) { CapabilityCard(capability: $0) }
        }
      }
    }
  }
}

private struct CapabilityCard: View {
  let capability: Capability

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
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer(minLength: 0)

      detail
    }
    .padding(14)
    .frame(height: 190, alignment: .top)
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
      caption("\(pack.name): needs \(pack.requires), about \(pack.approximateSize).")

    case .unavailable(let reason):
      caption(reason)
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var badge: some View {
    switch capability.status {
    case .available: label("Available", .green)
    case .installable: label("Add", .accentColor)
    case .planned: label("Coming", .blue)
    case .needsPack: label("Not included", .orange)
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
    default: return .secondary
    }
  }
}
