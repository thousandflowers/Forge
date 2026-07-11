import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section("Performance") {
        Stepper(value: $model.settings.maxConcurrentNative, in: 1...8) {
          LabeledContent("Max concurrent conversions", value: "\(model.settings.maxConcurrentNative)")
        }
        HStack {
          Text("Memory warning threshold")
          Spacer()
          TextField("MB", value: $model.settings.memoryWarningThresholdMB, format: .number)
            .frame(width: 70).multilineTextAlignment(.trailing)
          Text("MB").foregroundStyle(.secondary)
        }
      }
      Section("File handling") {
        Toggle("Create backup before overwrite", isOn: $model.settings.createBackupBeforeOverwrite)
        Toggle("Preserve original metadata", isOn: $model.settings.preserveOriginalMetadata)
        Toggle("Show notifications", isOn: $model.settings.showNotifications)
      }
      Section("About") {
        LabeledContent("Version", value: "0.1.0 (Alpha)")
        LabeledContent("Frameworks", value: "Core Image · AVFoundation · PDFKit")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
    .onChange(of: model.settings) { _ in model.saveSettings() }
  }
}
