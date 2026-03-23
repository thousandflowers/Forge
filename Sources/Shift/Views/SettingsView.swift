import SwiftUI

struct SettingsView: View {
  @StateObject private var viewModel = SettingsViewModel()

  var body: some View {
    Form {
      Section(header: Text("Processors")) {
        Toggle("Native Processors", isOn: $viewModel.settings.nativeProcessorsEnabled)
          .disabled(true) // always on

        Toggle("Enable External Tools", isOn: $viewModel.settings.externalProcessorsEnabled)
          .help("Enable support for external CLI tools like ImageMagick, FFmpeg, LibreOffice")

        if viewModel.settings.externalProcessorsEnabled {
          VStack(alignment: .leading) {
            Text("External Tools:")
              .font(.caption)
              .foregroundColor(.secondary)
            ForEach(viewModel.availableTools, id: \.self) { tool in
              HStack {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundColor(.green)
                Text(tool)
              }
            }
          }
          .padding(.leading)
        }
      }

      Section(header: Text("Performance")) {
        HStack {
          Text("Max Concurrent Native")
          Spacer()
          Stepper(value: $viewModel.settings.maxConcurrentNative, in: 1...8) {
            Text("\(viewModel.settings.maxConcurrentNative)")
          }
          .frame(width: 80)
        }

        HStack {
          Text("Max Concurrent External")
          Spacer()
          Stepper(value: $viewModel.settings.maxConcurrentExternal, in: 1...2) {
            Text("\(viewModel.settings.maxConcurrentExternal)")
          }
          .frame(width: 80)
          .disabled(!viewModel.settings.externalProcessorsEnabled)
        }

        HStack {
          Text("Memory Warning Threshold (MB)")
          Spacer()
          TextField("MB", value: $viewModel.settings.memoryWarningThresholdMB, format: .number)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .frame(width: 80)
        }
      }

      Section(header: Text("File Handling")) {
        Toggle("Create Backup Before Overwrite", isOn: $viewModel.settings.createBackupBeforeOverwrite)
        Toggle("Show Notifications", isOn: $viewModel.settings.showNotifications)
      }

      Section(header: Text("About")) {
        HStack {
          Text("Version")
          Spacer()
          Text("1.0.0 (Alpha)")
            .foregroundColor(.secondary)
        }
        HStack {
          Text("Build")
          Spacer()
          Text("2025-03-24")
            .foregroundColor(.secondary)
        }
      }
    }
    .padding()
    .frame(width: 600, height: 500)
    .onAppear {
      viewModel.loadSettings()
    }
  }
}

final class SettingsViewModel: ObservableObject {
  @Published var settings: AppSettings = .load()
  @Published var availableTools: [String] = []

  func loadSettings() {
    // Detect external tools if enabled
    if settings.externalProcessorsEnabled {
      availableTools = detectExternalTools()
    } else {
      availableTools = []
    }
  }

  private func detectExternalTools() -> [String] {
    var tools: [String] = []
    let commonTools = ["imagemagick", "libreoffice", "ffmpeg", "blender", "inkscape", "pandoc"]
    for tool in commonTools {
      if ProcessInfo.processInfo.environment["PATH"]?.contains(tool) == true ||
         FileManager.default.fileExists(atPath: "/usr/local/bin/\(tool)") ||
         FileManager.default.fileExists(atPath: "/opt/homebrew/bin/\(tool)") {
        tools.append(tool)
      }
    }
    return tools
  }
}
