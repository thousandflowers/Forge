import SwiftUI

/// The app's top-level navigation destinations (sidebar).
enum AppSection: String, CaseIterable, Identifiable {
  case process, presets, folders, history, settings
  var id: String { rawValue }

  var title: String {
    switch self {
    case .process: return "Convert"
    case .presets: return "Presets"
    case .folders: return "Folders"
    case .history: return "History"
    case .settings: return "Settings"
    }
  }

  var icon: String {
    switch self {
    case .process: return "arrow.triangle.2.circlepath"
    case .presets: return "slider.horizontal.3"
    case .folders: return "folder"
    case .history: return "clock.arrow.circlepath"
    case .settings: return "gearshape"
    }
  }
}

/// Per-file status shown in the batch table.
enum FileStatus: String {
  case pending = "Pending"
  case processing = "Processing"
  case completed = "Completed"
  case failed = "Failed"

  var color: Color {
    switch self {
    case .pending: return .secondary
    case .processing: return .orange
    case .completed: return .green
    case .failed: return .red
    }
  }

  var systemImage: String {
    switch self {
    case .pending: return "circle"
    case .processing: return "arrow.triangle.2.circlepath"
    case .completed: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    }
  }
}

func statusLabel(_ status: FileStatus) -> some View {
  Label(status.rawValue, systemImage: status.systemImage)
    .foregroundStyle(status.color)
    .font(.callout)
}

func formatBytes(_ bytes: Int64) -> String {
  let f = ByteCountFormatter()
  f.countStyle = .file
  return f.string(fromByteCount: bytes)
}

/// Reusable empty state (a light stand-in for ContentUnavailableView, macOS 13 compatible).
struct EmptyStateView: View {
  let icon: String
  let title: String
  let message: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 44, weight: .light))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.title3.weight(.semibold))
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .controlSize(.large)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}
