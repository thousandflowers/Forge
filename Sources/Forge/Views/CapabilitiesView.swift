import SwiftUI

/// What this Mac can do, and what it cannot.
///
/// Doubles as the answer to "which formats does Forge support": the list is
/// computed from the frameworks at run time, so it describes the machine it is
/// running on rather than a claim written months ago.
struct CapabilitiesView: View {
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        section("Ready to use", Capabilities.all.filter(\.status.isAvailable))
        section("Coming", Capabilities.all.filter { if case .planned = $0.status { return true } else { return false } })
        section("Would need an addition", Capabilities.all.filter { if case .needsPack = $0.status { return true } else { return false } })
        section("Not possible on macOS", Capabilities.all.filter { if case .unavailable = $0.status { return true } else { return false } })
      }
      .padding(20)
    }
    .navigationTitle("Capabilities")
  }

  @ViewBuilder
  private func section(_ title: String, _ capabilities: [Capability]) -> some View {
    if !capabilities.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(title)
          .font(.headline)
        ForEach(capabilities) { CapabilityRow(capability: $0) }
      }
    }
  }
}

private struct CapabilityRow: View {
  let capability: Capability

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: capability.symbol)
        .font(.title3)
        .foregroundStyle(tint)
        .frame(width: 26)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(capability.title).font(.callout.weight(.semibold))
          badge
        }
        Text(capability.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
        detail
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
  }

  @ViewBuilder
  private var detail: some View {
    switch capability.status {
    case .available(let detail):
      Text(detail)
        .font(.caption)
        .foregroundStyle(.tertiary)
    case .planned:
      EmptyView()
    case .needsPack(let pack):
      Text("\(pack.name) — needs \(pack.requires), about \(pack.approximateSize).")
        .font(.caption)
        .foregroundStyle(.tertiary)
    case .unavailable(let reason):
      Text(reason)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var badge: some View {
    switch capability.status {
    case .available:
      label("Available", .green)
    case .planned:
      label("Coming", .blue)
    case .needsPack:
      label("Not included", .orange)
    case .unavailable:
      label("Unavailable", .secondary)
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
    capability.status.isAvailable ? .accentColor : .secondary
  }
}
