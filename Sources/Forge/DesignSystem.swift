import SwiftUI

/// The app's top-level navigation destinations (sidebar).
enum AppSection: String, CaseIterable, Identifiable {
  case process, presets, store, folders, history
  var id: String { rawValue }

  var title: String {
    switch self {
    case .process: return "Convert"
    case .presets: return "Presets"
    case .store: return "Store"
    case .folders: return "Folders"
    case .history: return "History"
    }
  }

  var icon: String {
    switch self {
    case .process: return "arrow.triangle.2.circlepath"
    case .presets: return "slider.horizontal.3"
    case .store: return "bag"
    case .folders: return "folder"
    case .history: return "clock"
    }
  }
}

extension ProcessingStatus {
  var color: Color {
    switch self {
    case .pending, .cancelled, .skipped: return .secondary
    case .processing: return .orange
    case .completed: return .green
    case .failed: return .red
    }
  }

  var systemImage: String {
    switch self {
    case .pending: return "circle"
    case .processing: return "arrow.triangle.2.circlepath"
    case .completed: return "checkmark.circle.fill"
    case .cancelled: return "slash.circle"
    case .skipped: return "arrow.uturn.right.circle"
    case .failed: return "xmark.circle.fill"
    }
  }

  var label: some View {
    Label(displayName, systemImage: systemImage)
      .foregroundStyle(color)
      .font(.callout)
  }
}

/// Reusable empty state (a light stand-in for ContentUnavailableView, macOS 13 compatible).
struct EmptyStateView: View {
  let icon: String
  let title: String
  let message: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 44, weight: .light))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.title3.weight(.semibold))
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .controlSize(.large)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

extension PresetCategory {
  /// What it is about, at a glance, wherever it is drawn.
  var tint: Color {
    switch self {
    case .image: return .teal
    case .video: return .indigo
    case .audio: return .pink
    case .document: return .blue
    case .data: return .green
    case .model: return .orange
    case .subtitle: return .purple
    case .font: return .brown
    case .custom: return .gray
    }
  }
}

/// A few words on a card: a format, a size, what it is about.
struct Tag: View {
  let text: String
  var tint: Color = .secondary

  var body: some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .foregroundStyle(tint == .secondary ? Color.primary.opacity(0.75) : tint)
  }
}

/// As many as fit on one line, and how many more there are: cut off at the edge
/// of the card they said less than nothing.
struct TagRow: View {
  let texts: [String]
  var warning: String? = nil

  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach((0...texts.count).reversed(), id: \.self) { shown in
        HStack(spacing: 5) {
          if let warning { Tag(text: warning, tint: .orange) }
          ForEach(Array(texts.prefix(shown).enumerated()), id: \.offset) { Tag(text: $0.element) }
          if shown < texts.count { Tag(text: "+\(texts.count - shown)") }
        }
        .fixedSize()
      }
    }
    .frame(height: 20, alignment: .leading)
    .help(texts.joined(separator: " · "))
    .accessibilityElement()
    .accessibilityLabel(Text(([warning].compactMap { $0 } + texts).joined(separator: ", ")))
  }
}

/// Sizes measured from Shortcuts on macOS 26, used wherever Forge draws a
/// block, a row or a card. Colours stay Forge's.
enum Metrics {
  static let blockHeight: CGFloat = 43
  static let blockColumn: CGFloat = 600
  static let iconSize: CGFloat = 22
  static let bodyText: CGFloat = 13
  static let blockRadius: CGFloat = 20
  static let cardRadius: CGFloat = 16
}

extension View {
  /// Forge's cards in Shortcuts' shape: flat, generously rounded. One that can
  /// be pressed comes forward under the pointer.
  func forgeCard(radius: CGFloat = Metrics.cardRadius, lifts: Bool = false) -> some View {
    modifier(ForgeCard(radius: radius, lifts: lifts))
  }
}

extension NSColor {
  /// Above the window in the dark as well, where the system's own is below it.
  static let card = NSColor(name: "card") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.075) : .white
  }
}

private struct ForgeCard: ViewModifier {
  let radius: CGFloat
  let lifts: Bool
  @State private var isUnder = false
  @Environment(\.accessibilityReduceMotion) private var isStill

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background(
        shape.fill(Color(nsColor: .card))
          .shadow(color: .black.opacity(isUnder ? 0.14 : 0.05), radius: isUnder ? 10 : 2, y: isUnder ? 4 : 1)
      )
      .overlay(shape.strokeBorder(Color.primary.opacity(isUnder ? 0.12 : 0.06)))
      .contentShape(shape)
      .onHover { isUnder = lifts && $0 }
      .animation(isStill ? nil : .easeOut(duration: 0.15), value: isUnder)
  }
}
