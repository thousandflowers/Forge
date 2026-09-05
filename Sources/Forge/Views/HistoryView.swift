import AppKit
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
          HistoryRow(entry: entry)
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

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.fileURL.lastPathComponent)
          .lineLimit(1).truncationMode(.middle)

        if let reason = entry.errorMessage, entry.status != .completed {
          // The reason was recorded all along and shown nowhere.
          Text(reason)
            .font(.caption)
            .foregroundStyle(entry.status.color)
            .lineLimit(2)
        } else if let landed {
          Text(landed)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }

        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2).foregroundStyle(.tertiary)
      }

      Spacer()

      if let duration = entry.durationText {
        Text(duration)
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }

      // The same actions as the context menu, somewhere they can be found
      // without knowing to right-click.
      Menu {
        menu
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.vertical, 2)
    .contextMenu { menu }
  }

  /// Where the conversion put things, in one line: a preset with two formats
  /// writes two files, and both are now accounted for.
  private var landed: String? {
    guard let output = entry.outputURL else { return nil }
    let extras = entry.outputs.count - 1
    let folder = output.deletingLastPathComponent().lastPathComponent
    return extras > 0
      ? "\(output.lastPathComponent) and \(extras) more, in \(folder)"
      : "\(output.lastPathComponent), in \(folder)"
  }

  /// What can be done about a past run, most useful first.
  ///
  /// A run and a preset are the same thing said twice, so the first action is
  /// the one that turns one into the other: a conversion done once becomes a
  /// conversion that can be done again, edited, exported, published. The rest
  /// run it again, on files chosen now or on the same ones.
  @ViewBuilder
  private var menu: some View {
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
