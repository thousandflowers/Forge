import SwiftUI

/// What is looked for, over what it is looked for in.
struct SearchField: View {
  let prompt: String
  @Binding var text: String
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .accessibilityLabel(Text(prompt))
        .onExitCommand { text = "" }
      if !text.isEmpty {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityLabel(Text("Clear search"))
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor, lineWidth: isFocused ? 2 : 0))
    // ⌘F goes to it.
    .background(Button("") { isFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true))
  }
}
