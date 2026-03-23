import SwiftUI

struct BatchProcessingView: View {
  @StateObject private var viewModel = BatchProcessingViewModel()

  var body: some View {
    VStack(spacing: 16) {
      // Header
      HStack {
        Text("Batch Processing")
          .font(.title)
        Spacer()
        Button("Clear") {
          viewModel.clearFiles()
        }
        .disabled(viewModel.files.isEmpty)
      }
      .padding(.horizontal)

      // Drop Zone
      DropZoneView()
        .frame(height: 120)
        .padding(.horizontal)

      // Files List
      if viewModel.files.isEmpty {
        Spacer()
        Text("Drop files here to begin")
          .foregroundColor(.secondary)
          .font(.title2)
        Spacer()
      } else {
        FileListView()
          .environmentObject(viewModel)
      }

      // Controls
      if !viewModel.files.isEmpty {
        Divider()
        ControlPanelView()
          .environmentObject(viewModel)
      }
    }
    .padding(.vertical)
  }
}

// MARK: - Markers for subviews (we'll define them inline for brevity)

struct DropZoneView: View {
  @State private var isDragging = false

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12)
        .stroke(isDragging ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))

      Text("Drag & drop files here")
        .foregroundColor(.secondary)
    }
    .padding(.horizontal)
    .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
      // Will be implemented by ViewModel
      return false
    }
  }
}

fileprivate struct FileListView: View {
  @EnvironmentObject var viewModel: BatchProcessingViewModel

  var body: some View {
    ScrollView {
      Table(viewModel.files) {
        TableColumn("File") { file in
          Text(file.fileName)
            .lineLimit(1)
        }
        TableColumn("Type") { file in
          Text(file.fileType.localizedString ?? file.fileType.identifier)
        }
        TableColumn("Size") { file in
          Text(viewModel.formatSize(file.fileSize))
        }
        TableColumn("Dimensions") { file in
          if let dims = file.dimensions {
            Text("\(dims.width) × \(dims.height)")
          } else {
            Text("-")
          }
        }
        TableColumn("Status") { file in
          if let status = viewModel.status(for: file.id) {
            Text(status).foregroundColor(statusColor(for: status))
          }
        }
      }
    }
    .frame(maxHeight: 300)
  }

  func statusColor(for status: String) -> Color {
    switch status {
    case "Completed": return .green
    case "Failed": return .red
    case "Processing...": return .orange
    default: return .primary
    }
  }
}

fileprivate struct ControlPanelView: View {
  @EnvironmentObject var viewModel: BatchProcessingViewModel
  @State private var selectedPresetID: UUID?
  @State private var destinationMode: DestinationMode = .copyTo
  @State private var destinationFolder: URL?

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        // Preset picker
        VStack(alignment: .leading) {
          Text("Preset:")
            .font(.caption)
          Picker("Preset", selection: $selectedPresetID) {
            ForEach(viewModel.availablePresets) { preset in
              Text(preset.name).tag(Optional(preset.id))
            }
          }
          .pickerStyle(MenuPickerStyle())
          .frame(width: 200)
        }

        // Destination picker
        VStack(alignment: .leading) {
          Text("Destination:")
            .font(.caption)
          Picker("Destination", selection: $destinationMode) {
            ForEach(DestinationMode.allCases, id: \.self) { mode in
              Text(mode.rawValue.capitalized).tag(mode)
            }
          }
          .pickerStyle(SegmentedPickerStyle())
          .frame(width: 300)
        }

        Spacer()

        // Process button
        Button(action: {
          Task {
            await viewModel.startProcessing(
              presetID: selectedPresetID,
              destinationMode: destinationMode,
              destinationFolder: destinationFolder
            )
          }
        }) {
          HStack {
            if viewModel.isProcessing {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text(viewModel.isProcessing ? "Processing..." : "Start Processing")
          }
          .frame(minWidth: 150)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.isProcessing || selectedPresetID == nil)
      }

      HStack {
        Text("Process \(viewModel.files.count) files")
          .font(.caption)
          .foregroundColor(.secondary)

        Spacer()

        if viewModel.isProcessing {
          Button("Cancel") {
            viewModel.cancelProcessing()
          }
        }
      }
    }
    .padding(.horizontal)
  }
}
