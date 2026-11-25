import SwiftUI

/// The three files, before there is a folder. One under the pointer comes up and
/// says what it is; pressed, it is something else. Left alone, it is still.
struct LessonFan: View {
  let size: CGFloat
  let pressed: () -> Void
  @State private var isOpen = false
  @Environment(\.accessibilityReduceMotion) private var isStill

  /// The panel is there first, and then they part.
  private static let wait = 0.3

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(WelcomeSamples.each.enumerated()), id: \.offset) { index, sample in
        let side = CGFloat(index) - CGFloat(WelcomeSamples.each.count - 1) / 2
        LessonTile(sample: sample, size: size, side: side, isOpen: isOpen, pressed: pressed)
          .zIndex(side == 0 ? 1 : 0)
      }
    }
    .frame(height: size * 1.4)
    .onAppear {
      withAnimation(isStill ? nil : Motion.arrive.delay(Self.wait)) { isOpen = true }
    }
  }
}

private struct LessonTile: View {
  let sample: WelcomeSamples.Sample
  let size: CGFloat
  let side: CGFloat
  let isOpen: Bool
  let pressed: () -> Void
  @State private var isUnder = false
  @State private var isTurned = false
  @Environment(\.accessibilityReduceMotion) private var isStill

  var body: some View {
    Button(action: turn) {
      // The place stays where it is: a tile that left from under the pointer
      // went up and down for as long as the pointer was at its edge.
      Color.clear
        .frame(width: size * 1.1, height: size * 1.4)
        .contentShape(Rectangle())
        .overlay { tile }
    }
    .buttonStyle(.plain)
    .onHover { isIn in withAnimation(isStill ? nil : Motion.move) { isUnder = isIn } }
    .accessibilityLabel(Text("\(sample.name).\(isTurned ? sample.to : sample.from)"))
  }

  private var tile: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(sample.kind.tint)
      if isUnder || isTurned {
        Text(isTurned ? sample.to : sample.from)
          .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
          // Turned over with the tile, and so turned back.
          .scaleEffect(x: isTurned && !isStill ? -1 : 1)
          .transition(.opacity)
      } else {
        Image(systemName: sample.kind.icon)
          .font(.system(size: size * 0.52, weight: .medium))
          .transition(.opacity)
      }
    }
    .foregroundStyle(.white)
    .frame(width: size, height: size)
    .shadow(color: .black.opacity(isUnder ? 0.28 : 0.18), radius: isUnder ? 8 : 5, y: isUnder ? 5 : 3)
    .rotation3DEffect(.degrees(isTurned && !isStill ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    .rotationEffect(.degrees(isUnder ? 0 : Double(side) * (isOpen ? 14 : 5)))
    .scaleEffect(isUnder && !isStill ? 1.1 : 1)
    .offset(x: isOpen ? 0 : -side * size * 0.6, y: isUnder && !isStill ? -5 : abs(side) * size * 0.1)
  }

  private func turn() {
    pressed()
    withAnimation(isStill ? nil : Motion.arrive) { isTurned.toggle() }
  }
}
