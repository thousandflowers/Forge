import SwiftUI

/// The files a preset takes, what starts it, and the test they have to pass.
/// Always first on the canvas, never removed. Converting once, the files are
/// already here: the rules only a saved preset needs are folded away.
struct InputBlock: View {
  let conversion: EditorConversion?
  @Binding var category: PresetCategory
  @Binding var inputFormats: Set<String>
  @Binding var nameTrigger: String
  @Binding var gate: Condition?
  @State private var choosingFormats = false
  /// A test that decides whether these files run is not left out of sight.
  @State private var showsRules: Bool

  init(
    conversion: EditorConversion?, category: Binding<PresetCategory>, inputFormats: Binding<Set<String>>,
    nameTrigger: Binding<String>, gate: Binding<Condition?>
  ) {
    self.conversion = conversion
    _category = category
    _inputFormats = inputFormats
    _nameTrigger = nameTrigger
    _gate = gate
    _showsRules = State(initialValue: gate.wrappedValue != nil)
  }

  var body: some View {
    BlockCard(title: "Files that come in", symbol: category.icon, tint: .teal, remove: nil, inline: false) {
      VStack(alignment: .leading, spacing: 10) {
        if let conversion {
          HStack {
            Text(conversion.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(showsRules ? "Hide rules" : "Rules for a saved preset ›") { showsRules.toggle() }
              .buttonStyle(.link)
          }
        } else {
          kindRow
        }

        if conversion == nil || showsRules {
          Divider()
          rules
        }
      }
    }
  }

  /// Which files a saved preset is for.
  private var kindRow: some View {
    HStack(spacing: 10) {
      Picker("Kind", selection: $category) {
        ForEach(PresetCategory.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .labelsHidden()
      .fixedSize()

      if category == .custom {
        Button {
          choosingFormats = true
        } label: {
          Label("Choose formats…", systemImage: "line.3.horizontal.decrease.circle")
        }
        // The anchor keeps one width whatever is chosen: a label that grew
        // with the count moved the popover under the pointer at every click.
        .popover(isPresented: $choosingFormats, arrowEdge: .bottom) { InputFormatsPopover(chosen: $inputFormats) }
        Text(inputFormats.isEmpty ? "Any file Forge opens." : InputFormats.chosen(inputFormats.count))
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        Text("Every \(category.noun) file dropped on Forge, or into a folder it watches.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// What starts a saved preset, and the test its files have to pass.
  private var rules: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Runs when: dropped, or renamed to say so.
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Runs when").foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
        VStack(alignment: .leading, spacing: 6) {
          Text("a file is dropped on Forge, or lands in a folder Forge watches")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 6) {
            Text("or a file is renamed with the word").font(.callout)
            Text("_").foregroundStyle(.tertiary)
            TextField("word", text: $nameTrigger)
              .frame(width: 90)
              .font(.callout.monospaced())
              .accessibilityLabel(Text("Trigger word"))
          }
          if !nameTrigger.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("In a watched folder, foto.jpg renamed to foto_\(nameTrigger.trimmingCharacters(in: .whitespaces)).jpg runs this preset, whatever the folder's own preset is. The word is dropped from the output's name.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      // Only if: a gate on the whole preset.
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Only if").foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
        VStack(alignment: .leading, spacing: 6) {
          Toggle(isOn: Binding(get: { gate != nil }, set: { gate = $0 ? Condition() : nil })) {
            Text("the file passes a test; otherwise it is left alone")
          }
          .toggleStyle(.checkbox)
          .font(.callout)
          if let current = gate {
            ConditionEditor(condition: Binding(get: { current }, set: { gate = $0 }))
          }
        }
      }
    }
  }
}
