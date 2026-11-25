import SwiftUI

/// What it was and what came of it, side by side.
struct LessonResult: View {
  let before: NSImage
  let after: NSImage

  var body: some View {
    HStack(spacing: 14) {
      ForEach(Array([before, after].enumerated()), id: \.offset) { _, image in
        Image(nsImage: image).resizable().scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
      }
    }
    .accessibilityElement()
    .accessibilityLabel(Text("Before and after"))
  }
}

/// A few more names, each given by pressing it.
struct LessonExtras: View {
  @ObservedObject var lesson: Lesson

  var body: some View {
    HStack(spacing: 5) {
      ForEach(WelcomeSamples.extras, id: \.word) { extra in
        Button { lesson.give(extra) } label: {
          Text(extra.word)
            .font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(lesson.tried.contains(extra.word) ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            .padding(.horizontal, 7).frame(height: 22)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: Capsule())
            .contentShape(Capsule())
            .opacity(lesson.trying == nil || lesson.trying == extra.word ? 1 : 0.45)
            .overlay { if lesson.trying == extra.word { Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5) } }
        }
        .buttonStyle(.plain)
        .disabled(lesson.trying != nil)
        .accessibilityLabel(Text(extra.word))
        .accessibilityValue(Text(lesson.tried.contains(extra.word) ? "Done" : ""))
      }
    }
  }
}
