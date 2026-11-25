import SwiftUI

/// A picture, a page and a film, which make room for what is being brought.
/// One under the pointer turns into something Forge makes of it, another thing
/// every time.
struct FileFan: View {
  let isOpen: Bool
  var size: CGFloat = 62
  @State private var formats: [PresetCategory: [String]] = [:]
  @State private var under: PresetCategory?
  @Environment(\.accessibilityReduceMotion) private var isStill

  static let kinds: [PresetCategory] = [.image, .document, .video]

  /// What each becomes on this Mac, the usual things first.
  static func offers() -> [PresetCategory: [String]] {
    Dictionary(uniqueKeysWithValues: kinds.map { category in
      guard let kind = ConvertKind(rawValue: category.rawValue) else { return (category, []) }
      return (category, kind.leading(of: kind.outputGroups.flatMap(\.formats)).filter { $0.type != nil }.map { $0.label.lowercased() })
    })
  }

  var body: some View {
    ZStack {
      ForEach(Array(Self.kinds.enumerated()), id: \.offset) { index, kind in
        let side = CGFloat(index - 1)
        FileTile(kind: kind, formats: formats[kind] ?? [], size: size, tilt: Double(side) * (isOpen ? 16 : 9), isUnder: under == kind && !isOpen)
          .onHover { isIn in
            if isIn { under = kind } else if under == kind { under = nil }
          }
          .offset(x: side * size * (isOpen ? 0.86 : 0.6), y: abs(side) * size * 0.1)
          // In front of the others, or half of what it says is behind them.
          .zIndex(under == kind ? 2 : index == 1 ? 1 : 0)
      }
    }
    .frame(width: size * 3, height: size * 1.4)
    .animation(isStill ? nil : Motion.arrive, value: isOpen)
    .accessibilityHidden(true)
    .task { formats = await Task.detached(priority: .utility) { Self.offers() }.value }
  }
}

private struct FileTile: View {
  let kind: PresetCategory
  let formats: [String]
  let size: CGFloat
  let tilt: Double
  let isUnder: Bool
  /// What its two sides say; its own icon where that is nothing.
  @State private var sides: [String?] = [nil, nil]
  @State private var next = 0
  /// Half turns: at an odd one its back is to the front.
  @State private var turns = 0
  @Environment(\.accessibilityReduceMotion) private var isStill

  var body: some View {
    // The place stays where it is: a tile that left from under the pointer
    // would go up and down for as long as the pointer was at its edge.
    Color.clear
      .frame(width: size, height: size)
      .contentShape(Rectangle())
      .overlay { tile.allowsHitTesting(false) }
      .onChange(of: isUnder) { isIn in
        guard isIn else { return turn(to: nil) }
        guard !formats.isEmpty else { return }
        turn(to: formats[next % formats.count])
        next += 1
      }
  }

  private var tile: some View {
    Turning(half: Double(turns)) { face(sides[$0]) }
    .rotationEffect(.degrees(isUnder ? 0 : tilt))
    .scaleEffect(isUnder && !isStill ? 1.1 : 1)
    .offset(y: isUnder && !isStill ? -size * 0.1 : 0)
    .animation(isStill ? nil : Motion.move, value: isUnder)
  }

  private func face(_ format: String?) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28).fill(kind.tint)
      if let format {
        Text(format)
          .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .padding(.horizontal, size * 0.08)
      } else {
        Image(systemName: kind.icon).font(.system(size: size * 0.52, weight: .medium))
      }
    }
    .foregroundStyle(.white)
    .frame(width: size, height: size)
    .shadow(color: .black.opacity(isUnder ? 0.28 : 0.18), radius: isUnder ? 8 : 5, y: isUnder ? 5 : 3)
  }

  private func turn(to new: String?) {
    guard new != sides[turns % 2] else { return }
    let to = isStill ? turns : turns + 1
    sides[to % 2] = new
    withAnimation(isStill ? nil : Motion.arrive) { turns = to }
  }
}

/// Two sides of one thing: whichever faces the front, and never its reverse.
private struct Turning<Face: View>: View, Animatable {
  var half: Double
  @ViewBuilder let face: (Int) -> Face

  var animatableData: Double {
    get { half }
    set { half = newValue }
  }

  var body: some View {
    let side = Int(half.rounded())
    face(abs(side) % 2)
      .scaleEffect(x: side.isMultiple(of: 2) ? 1 : -1)
      .rotation3DEffect(.degrees(half * 180), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
  }
}
