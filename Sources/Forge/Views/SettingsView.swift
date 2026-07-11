import SwiftUI

struct SettingsView: View {
  @StateObject private var viewModel = SettingsViewModel()

  var body: some View {
    Form {
      Section(header: Text("Processors")) {
        Toggle("Native Processors", isOn: $viewModel.settings.nativeProcessorsEnabled)
          .disabled(true) // always on
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
          Text("0.1.0 (Alpha)")
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
  }
}

final class SettingsViewModel: ObservableObject {
  @Published var settings: AppSettings = .load()
}
