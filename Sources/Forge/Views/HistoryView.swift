import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Group {
      if model.history.isEmpty {
        EmptyStateView(icon: "clock", title: "No history yet",
                       message: "Files you convert will show up here.")
      } else {
        List(model.history) { entry in
          HStack(spacing: 12) {
            Image(systemName: icon(for: entry.status))
              .foregroundStyle(color(for: entry.status))
              .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.fileURL.lastPathComponent)
                .lineLimit(1).truncationMode(.middle)
              Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.duration > 0 {
              Text(String(format: "%.1fs", entry.duration))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(entry.status.rawValue.capitalized)
              .font(.caption)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(Capsule().fill(color(for: entry.status).opacity(0.15)))
              .foregroundStyle(color(for: entry.status))
          }
          .padding(.vertical, 2)
        }
      }
    }
    .navigationTitle("History")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(role: .destructive) { model.clearHistory() } label: { Label("Clear", systemImage: "trash") }
          .disabled(model.history.isEmpty)
      }
    }
    .task { await model.refreshHistory() }
  }

  private func color(for status: ProcessingStatus) -> Color {
    switch status {
    case .completed: return .green
    case .failed: return .red
    case .cancelled: return .orange
    }
  }

  private func icon(for status: ProcessingStatus) -> String {
    switch status {
    case .completed: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    case .cancelled: return "minus.circle.fill"
    }
  }
}
