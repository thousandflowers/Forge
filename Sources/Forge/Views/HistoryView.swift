import AppKit
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel

  @State private var confirmingClear = false
  var body: some View {
    Group {
      if model.history.isEmpty {
        EmptyStateView(icon: "clock", title: "No history yet",
                       message: "Files you convert will show up here.")
      } else {
        List {
          ForEach(HistoryDay.days(of: model.history)) { day in
            Section(day.title) {
              ForEach(day.entries) { HistoryRow(entry: $0) }
            }
          }
        }
      }
    }
    .navigationTitle("History")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(role: .destructive) { confirmingClear = true } label: { Text("Clear History…") }
          .disabled(model.history.isEmpty)
      }
    }
    // Every past run, with what failed and why, went in one click.
    .confirmationDialog("Clear the history?", isPresented: $confirmingClear) {
      Button("Clear History", role: .destructive) { model.clearHistory() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every past conversion goes, with what failed and why. The converted files stay where they are.")
    }
    .task { await model.refreshHistory() }
  }
}

/// What was converted on one day, the latest first.
struct HistoryDay: Identifiable {
  let id: Date
  let entries: [ProcessingHistory]
  let title: String

  static func days(of history: [ProcessingHistory], now: Date = Date(), calendar: Calendar = .current) -> [HistoryDay] {
    Dictionary(grouping: history) { calendar.startOfDay(for: $0.timestamp) }
      .sorted { $0.key > $1.key }
      .map { day, entries in HistoryDay(id: day, entries: entries.sorted { $0.timestamp > $1.timestamp }, title: title(of: day, now: now, calendar: calendar)) }
  }

  private static func title(of day: Date, now: Date, calendar: Calendar) -> String {
    let ago = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
    switch ago {
    case 0: return "Today"
    case 1: return "Yesterday"
    default: return day.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: Locale(identifier: "en_US"), calendar: calendar))
    }
  }
}

/// One conversion, and what can be done about it.
///
/// A row used to say that a file had failed and nothing else: not why, not
/// where the output went, and with a duration of "0.0s" on anything quick.
/// The status was also said twice, once as a coloured icon and again as a
/// word in a capsule beside it.
private struct HistoryRow: View {
  @EnvironmentObject private var model: AppModel
  let entry: ProcessingHistory

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: entry.status.systemImage)
        .foregroundStyle(entry.status.color)
        .font(.title3)
        .help(entry.status.displayName)
        // VoiceOver read the symbol's own name: "selected", "close".
        .accessibilityLabel(entry.status.displayName)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.fileURL.lastPathComponent)
          .lineLimit(1).truncationMode(.middle)

        if let reason = entry.errorMessage, entry.status != .completed {
          // The reason was recorded all along and shown nowhere.
          Text(reason)
            .font(.caption)
            .foregroundStyle(entry.status.color)
            .lineLimit(2)
        } else if entry.isUndone {
          Text("Undone").font(.caption).foregroundStyle(.secondary)
        } else if let landed {
          Text(landed)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }

      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
        // What took no time is not worth a number.
        if entry.duration >= 1, let duration = entry.durationText { Text(duration) }
      }
      .font(.caption).foregroundStyle(.secondary).monospacedDigit()

      // The same actions as the context menu, somewhere they can be found
      // without knowing to right-click.
      Menu {
        menu
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("More")
    }
    .padding(.vertical, 4)
    .contextMenu { menu }
  }

  /// Where the conversion put things, in one line: a preset with two formats
  /// writes two files, and both are now accounted for.
  private var landed: String? {
    guard let output = entry.outputURL else { return nil }
    let extras = entry.outputs.count - 1
    let folder = output.deletingLastPathComponent().lastPathComponent
    return extras > 0
      ? "→ \(output.lastPathComponent) and \(extras) more in the \(folder) folder"
      : "→ \(output.lastPathComponent) in the \(folder) folder"
  }

  /// What can be done about a past run, most useful first.
  ///
  /// A run and a preset are the same thing said twice, so the first action is
  /// the one that turns one into the other: a conversion done once becomes a
  /// conversion that can be done again, edited, exported, published. The rest
  /// run it again, on files chosen now or on the same ones.
  @ViewBuilder
  private var menu: some View {
    if Undo.isPossible(for: entry) {
      Button("Undo") { model.undo(entry) }
      Divider()
    }
    if entry.isRepeatable {
      Button("Save as a Preset") { model.savePreset(from: entry) }

      Button("Run on Other Files…") {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Run the same steps on these."
        if panel.runModal() == .OK { model.reapply(entry, to: panel.urls) }
      }

      // The original may have moved, been renamed, or been replaced in place by
      // this very conversion. What is gone is said out loud rather than
      // silently dropped, and what is here still goes through the ordinary
      // confirmation before anything is replaced.
      Button("Run Again on the Same File") { model.rerun(entry) }
        .disabled(!FileManager.default.fileExists(atPath: entry.fileURL.path))

      Divider()
    }

    ForEach(entry.outputs, id: \.self) { output in
      Button("Show \(output.lastPathComponent) in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([output])
      }
      .disabled(!FileManager.default.fileExists(atPath: output.path))
    }

    Button("Show the original in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
    }
    .disabled(!FileManager.default.fileExists(atPath: entry.fileURL.path))
  }
}
