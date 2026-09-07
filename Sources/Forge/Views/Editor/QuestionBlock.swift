import SwiftUI

/// One thing the preset asks for, and where the answer comes from: a window
/// once per batch, or the file's own name. Files that say nothing use the
/// default.
struct QuestionBlock: View {
  @Binding var parameter: PresetParameter
  let keyIsSound: Bool
  let remove: () -> Void

  var body: some View {
    BlockCard(title: "Asks for", symbol: "questionmark.circle", tint: LibraryEntry.Group.ask.color, remove: remove) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          TextField("Question", text: $parameter.label)
          Text("{").foregroundStyle(.tertiary)
          TextField("key", text: $parameter.key)
            .frame(width: 80)
            .font(.callout.monospaced())
            .overlay(
              RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.red.opacity(keyIsSound ? 0 : 0.8))
                .padding(-2)
            )
            .help(keyIsSound ? "Spend it in a name template as {\(parameter.key)}" : "Every question needs its own key")
          Text("}").foregroundStyle(.tertiary)
          Text(parameter.kind.unit).foregroundStyle(.secondary).frame(width: 26)
        }

        Picker("Answer", selection: $parameter.source) {
          ForEach(PresetParameter.Source.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 340)

        HStack(spacing: 10) {
          Text("Default")
            .foregroundStyle(.secondary)
          TextField("Default", text: Binding(
            get: { String(format: "%g", parameter.defaultValue) },
            set: { text in
              let typed = Double(text.replacingOccurrences(of: ",", with: ".")) ?? parameter.kind.suggestedDefault
              let range = parameter.kind.range
              parameter.defaultValue = min(max(typed, range.lowerBound), range.upperBound)
            }
          ))
          .frame(width: 80)
          Text(parameter.kind.unit).foregroundStyle(.secondary)
        }

        Text(parameter.source == .prompt
          ? "A small window asks for it once per batch, before the files run."
          : "Read from the file's own name: \(parameter.nameExample) says it. A file that says nothing uses the default.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
