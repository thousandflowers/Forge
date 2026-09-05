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
      Section("What everything starts from") {
        Picker("Resizing means", selection: $model.settings.defaultFitMode) {
          ForEach(ResizeFitMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Stepper(value: $model.settings.defaultQuality, in: 1...100) {
          LabeledContent("Quality when a preset says none", value: "\(model.settings.defaultQuality)")
        }
        Picker("Metadata", selection: $model.settings.privacy) {
          ForEach(PrivacyPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Text(model.settings.privacy.summary + " A preset, a batch, or a file named _privacy can ask for more.")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("Name new files", text: $model.settings.nameTemplate)
        Text("{name} is the original's name. A preset that asks a question adds its own token, so {name}_{maxsize} writes holiday_10MB.jpg. Any preset can override all of this.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("When a batch finishes") {
        Toggle("Notify me", isOn: $model.settings.notifyWhenFinished)
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
  /// The version, read from the bundle rather than typed into a view where it
  /// goes stale.
  ///
  /// Installed as `forge`, the tool is reached through a symlink, and
  /// `Bundle.main` then describes the folder the link sits in rather than the
  /// app. Following the executable back to its own bundle is what makes
  /// `forge --version` report the same number the app does.
  var shortVersion: String {
    if let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
      return version
    }
    return Self.versionFromExecutablePath() ?? "development build"
  }

  static func versionFromExecutablePath() -> String? {
    guard let executable = CommandLine.arguments.first else { return nil }
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
    // .../Forge.app/Contents/MacOS/Forge -> .../Forge.app/Contents/Info.plist
    let contents = resolved.deletingLastPathComponent().deletingLastPathComponent()
    let plist = contents.appendingPathComponent("Info.plist")

    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
      return nil
    }
    return info["CFBundleShortVersionString"] as? String
  }
}
