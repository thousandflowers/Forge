import SwiftUI

/// Every block that can be added: click a tile, or drag it onto the canvas.
/// Grouped by what it is for, coloured by group, narrowed by the search.
struct BlockLibraryView: View {
  @Binding var search: String
  let entries: [LibraryEntry]
  let available: (LibraryEntry) -> Bool
  let add: (LibraryEntry) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search blocks", text: $search)
          .textFieldStyle(.plain)
          .accessibilityLabel(Text("Search blocks"))
        if !search.isEmpty {
          Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
      }
      .font(.body)
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
      .padding(14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ForEach(LibraryEntry.Group.allCases, id: \.self) { group in
            let inGroup = entries.filter { $0.group == group }
            if !inGroup.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                  Circle().fill(group.color).frame(width: 8, height: 8)
                  Text(group.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
                ForEach(inGroup) { entry in
                  tile(entry)
                }
              }
            }
          }
          if entries.isEmpty {
            Text("No block matches “\(search)”.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.top, 20)
          }
        }
        .padding(14)
      }
    }
    .frame(width: 300)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
  }

  /// One block in the library: coloured icon, name, what it does. The whole
  /// tile is a button, and the whole tile drags onto the canvas.
  private func tile(_ entry: LibraryEntry) -> some View {
    let usable = available(entry)
    return LibraryTileButton(usable: usable) {
      add(entry)
    } label: {
      HStack(spacing: 10) {
        BlockIcon(symbol: entry.symbol, tint: entry.group.color, size: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.title).font(.callout.weight(.medium))
          Text(entry.summary).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Image(systemName: usable ? "plus.circle.fill" : "checkmark.circle")
          .font(.body)
          .foregroundStyle(usable ? entry.group.color : Color.secondary)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(entry.group.color.opacity(0.25)))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .disabled(!usable)
    .opacity(usable ? 1 : 0.45)
    .onDrag { NSItemProvider(object: entry.id as NSString) }
    .help(usable ? "Click, or drag onto the canvas" : "Already on the canvas")
    .accessibilityLabel(Text("Add \(entry.title)"))
  }
}
