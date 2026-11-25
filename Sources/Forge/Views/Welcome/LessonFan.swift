import SwiftUI

/// The three files, before there is a folder. One under the pointer turns into
/// something it can really be made into, another thing every time. Left alone,
/// it is still.
struct LessonFan: View {
  let size: CGFloat
  let formats: [[String]]
  let pressed: () -> Void
  @State private var isOpen = false
  @Environment(\.accessibilityReduceMotion) private var isStill

  /// The panel is there first, and then they part.
  private static let wait = 0.3

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(WelcomeSamples.each.enumerated()), id: \.offset) { index, sample in
        let side = CGFloat(index) - CGFloat(WelcomeSamples.each.count - 1) / 2
        LessonTile(sample: sample, formats: formats.indices.contains(index) ? formats[index] : [], size: size, side: side, isOpen: isOpen, pressed: pressed)
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
  let formats: [String]
  let size: CGFloat
  let side: CGFloat
  let isOpen: Bool
  let pressed: () -> Void
  @State private var isUnder = false
  /// What it is now; its own icon when it is nothing else.
  @State private var format: String?
  @State private var next = 0
  /// Half turns: at an odd one its back is to the front, and is written backwards.
  @State private var turns = 0
  @Environment(\.accessibilityReduceMotion) private var isStill

  var body: some View {
    Button(action: press) {
      // The place stays where it is: a tile that left from under the pointer
      // went up and down for as long as the pointer was at its edge.
      Color.clear
        .frame(width: size * 1.1, height: size * 1.4)
        .contentShape(Rectangle())
        .overlay { tile }
    }
    .buttonStyle(.plain)
    .onHover { isIn in
      withAnimation(isStill ? nil : Motion.move) { isUnder = isIn }
      isIn ? become() : settle()
    }
    .accessibilityLabel(Text("\(sample.name).\(format ?? sample.from)"))
  }

  private var tile: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(sample.kind.tint)
      Group {
        if let format {
          Text(format)
            .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, size * 0.08)
        } else {
          Image(systemName: sample.kind.icon).font(.system(size: size * 0.52, weight: .medium))
        }
      }
      .transition(.opacity)
      .scaleEffect(x: turns.isMultiple(of: 2) ? 1 : -1)
    }
    .foregroundStyle(.white)
    .frame(width: size, height: size)
    .shadow(color: .black.opacity(isUnder ? 0.28 : 0.18), radius: isUnder ? 8 : 5, y: isUnder ? 5 : 3)
    .rotation3DEffect(.degrees(Double(turns) * 180), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    .rotationEffect(.degrees(isUnder ? 0 : Double(side) * (isOpen ? 14 : 5)))
    .scaleEffect(isUnder && !isStill ? 1.1 : 1)
    .offset(x: isOpen ? 0 : -side * size * 0.6, y: isUnder && !isStill ? -5 : abs(side) * size * 0.1)
  }

  private func press() {
    pressed()
    become()
  }

  private func become() {
    guard !formats.isEmpty else { return }
    turn(to: formats[next % formats.count])
    next += 1
  }

  private func settle() {
    if format != nil { turn(to: nil) }
  }

  private func turn(to new: String?) {
    withAnimation(isStill ? nil : Motion.arrive) {
      format = new
      if !isStill { turns += 1 }
    }
  }
}
