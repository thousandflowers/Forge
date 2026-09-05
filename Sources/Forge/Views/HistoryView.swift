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

  @ViewBuilder
  private var menu: some View {
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

    if let preset, let destination = entry.destinationFolder {
      Divider()
      // A conversion that failed because a file was still being written, or a
      // device was briefly busy, is worth one more try - and trying again was
      // the one thing history could not do.
      Button("Convert again with “\(preset.name)”") {
        model.convertFromMenuBar([entry.fileURL], with: preset, into: destination)
      }
      .disabled(!FileManager.default.fileExists(atPath: entry.fileURL.path))
    }
  }

  private var preset: RulePreset? {
    guard let id = entry.ruleId else { return nil }
    return model.presets.first { $0.id == id }
  }
}
