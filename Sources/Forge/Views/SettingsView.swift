import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section("Performance") {
        Stepper(value: $model.settings.maxConcurrentNative, in: 1...8) {
          LabeledContent("Max concurrent conversions", value: "\(model.settings.maxConcurrentNative)")
        }
      }
      Section("File handling") {
        Toggle("Create backup before overwrite", isOn: $model.settings.createBackupBeforeOverwrite)
        Text("Backups are kept in \(PersistenceManager.shared.backupsDirectory.path).")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("About") {
        LabeledContent("Version", value: Bundle.main.shortVersion)
        LabeledContent("Frameworks", value: "Core Image · AVFoundation · PDFKit")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
    .onChange(of: model.settings) { _ in model.saveSettings() }
  }
}

extension Bundle {
  /// The version shown in Settings, read from the bundle rather than typed
  /// into the view, where it went stale.
  var shortVersion: String {
    let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return version ?? "development build"
  }
}
