import SwiftUI

/// Lays out chips left to right, wrapping onto a new line when the row is full.
/// `LazyVGrid` cannot do it: its columns are fixed, and these are as wide as
/// the words inside them.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let rows = arrange(subviews, in: width)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(subviews, in: bounds.width) {
      var x = bounds.minX
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y),
          anchor: .topLeading,
          proposal: ProposedViewSize(item.size)
        )
        x += item.size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var items: [(index: Int, size: CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var row = Row()

    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
      if !row.items.isEmpty, needed > width {
        rows.append(row)
        row = Row()
      }
      row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.items.append((index, size))
    }
    if !row.items.isEmpty { rows.append(row) }
    return rows
  }
}
