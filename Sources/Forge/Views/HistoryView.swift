import SwiftUI

struct HistoryView: View {
  @StateObject private var viewModel = HistoryViewModel()

  var body: some View {
    VStack {
      HStack {
        Text("History")
          .font(.title)
        Spacer()
        Button("Clear History") {
          viewModel.clearHistory()
        }
        .disabled(viewModel.entries.isEmpty)
      }
      .padding()

      if viewModel.entries.isEmpty {
        Spacer()
        Text("No processing history yet.")
          .foregroundColor(.secondary)
        Spacer()
      } else {
        List(viewModel.entries) { entry in
          HStack {
            VStack(alignment: .leading) {
              Text(entry.fileURL.lastPathComponent)
                .font(.body)
                .lineLimit(1)
              Text(entry.timestamp, style: .date)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            statusBadge(for: entry.status)
          }
        }
      }
    }
    .padding()
  }

  func statusBadge(for status: ProcessingStatus) -> some View {
    Text(status.rawValue.capitalized)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(status == .completed ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
      .foregroundColor(status == .completed ? .green : .red)
      .clipShape(Capsule())
  }
}

final class HistoryViewModel: ObservableObject {
  @Published var entries: [ProcessingHistory] = []

  init() {
    loadHistory()
  }

  func loadHistory() {
    Task {
      let history = try? await PersistenceManager.shared.loadHistory()
      await MainActor.run {
        self.entries = (history ?? []).sorted { $0.timestamp > $1.timestamp }
      }
    }
  }

  func clearHistory() {
    // Clear
    entries.removeAll()
    // TODO: PersistenceManager.clearHistory()
  }
}
