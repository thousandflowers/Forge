import SwiftUI

/// Every format Forge reads, by kind, each one a switch.
struct InputFormatsPopover: View {
  @Binding var chosen: Set<String>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Formats this preset takes").font(.headline)
        Spacer()
        Button("Any") { chosen.removeAll() }
          .disabled(chosen.isEmpty)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(InputFormats.groups) { group in
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 6) {
                Image(systemName: group.kind.icon).foregroundStyle(.secondary)
                Text(group.kind.plural.capitalized).font(.callout.weight(.semibold))
                Spacer()
                Button(group.extensions.allSatisfy(chosen.contains) ? "None" : "All") {
                  if group.extensions.allSatisfy(chosen.contains) {
                    chosen.subtract(group.extensions)
                  } else {
                    chosen.formUnion(group.extensions)
                  }
                }
                .buttonStyle(.borderless)
                .font(.caption)
              }
              FlowLayout(spacing: 6) {
                ForEach(group.extensions, id: \.self) { ext in
                  Chip(ext.uppercased(), selected: chosen.contains(ext)) {
                    if chosen.contains(ext) { chosen.remove(ext) } else { chosen.insert(ext) }
                  }
                }
              }
            }
          }
        }
        .padding(.trailing, 8)
      }
      Text(chosen.isEmpty ? "None chosen: any file Forge can open goes through." : "\(chosen.count) formats chosen.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(16)
    .frame(width: 520, height: 480)
  }
}
