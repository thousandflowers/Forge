import SwiftUI
import AppKit

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var opensAtLogin = LoginItem.isOn

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Window", selection: $model.settings.appearance) {
          ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Text("Sheets and panels let the window show through either way.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Performance") {
        Stepper(value: $model.settings.maxConcurrentNative, in: 1...8) {
          LabeledContent("Max concurrent conversions", value: "\(model.settings.maxConcurrentNative)")
        }
      }
      Section("File handling") {
        Toggle("Create backup before overwrite", isOn: $model.settings.createBackupBeforeOverwrite)
        HStack {
          Text("Backups are kept in \(MonitoredFolder.abbreviated(PersistenceManager.shared.backupsDirectory)).")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Show in Finder") {
            let backups = PersistenceManager.shared.backupsDirectory
            try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([backups])
          }
          .controlSize(.small)
        }
      }
      Section("Without being asked") {
        Toggle("Make copied pictures lighter", isOn: $model.settings.lighterClipboard)
        Toggle("Make screen recordings lighter", isOn: $model.settings.lighterRecordings)
        Toggle("Turn HEIC, WebP and AVIF downloads into JPEGs", isOn: $model.settings.friendlyDownloads)
        Toggle("Convert files I rename to another extension", isOn: $model.settings.convertsRenames)
        Text("On the Desktop, and in Downloads, Documents and Pictures, when you rename in the Finder: photo.pdf becomes a real photo.jpg. "
          + (model.settings.createBackupBeforeOverwrite ? "The original is kept in Backups." : "The original stays beside it."))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(model.settings.createBackupBeforeOverwrite
          ? "A card in the corner says what was done and undoes it. Originals are kept in Backups; a result that would not be lighter is not used."
          : "A card in the corner says what was done and undoes it. Backups are off, so nothing is replaced: the lighter copy is put beside it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("While dragging") {
        // A Mac without one has nothing to turn on.
        if NotchZone.cutout() != nil || model.settings.notchZone {
          Toggle("Use the notch as a drop zone", isOn: $model.settings.notchZone)
        }
        Toggle("Show a menu over the file", isOn: $model.settings.dragMenu)
        LabeledContent("Keys to hold") {
          HStack(spacing: 6) {
            if model.settings.dragMenuKeys != .usual {
              Button("Reset") { model.settings.dragMenuKeys = .usual }.controlSize(.small)
            }
            ForEach(HoldKeys.all) { key in
              Toggle(key.symbol, isOn: Binding(
                get: { model.settings.dragMenuKeys.contains(key.keys) },
                set: { _ in model.settings.dragMenuKeys = model.settings.dragMenuKeys.toggling(key.keys) }
              ))
              .toggleStyle(.button)
              .help(key.name)
              .accessibilityLabel(Text(key.name))
            }
          }
        }
        .disabled(!model.settings.dragMenu)
        IgnoredApps(identifiers: $model.settings.dragMenuIgnored).disabled(!model.settings.dragMenu)
        MenuPresets(chosen: $model.settings.menuPresets, presets: model.usablePresets).disabled(!model.settings.dragMenu)
        Text("Drag a file from anywhere, hold \(model.settings.dragMenuKeys.symbols), and drop it on what it should become. The result goes beside the original, which stays.")
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
        Picker("Spoken in recordings", selection: $model.settings.spokenLanguage) {
          Text("The Mac’s language").tag("")
          ForEach(Transcription.languages, id: \.tag) { Text($0.name).tag($0.tag) }
        }
        TemplateField(title: "Name new files", template: $model.settings.nameTemplate)
        Text("Any preset can override this. A preset that asks a question adds its own token too, so {name}_{maxsize} writes holiday_10MB.jpg.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("When the Mac starts") {
        Toggle("Open Forge at login", isOn: Binding(get: { opensAtLogin }, set: { on in
          do { try LoginItem.set(on) } catch { model.report(error, doing: "changing what opens at login") }
          opensAtLogin = LoginItem.isOn
        }))
        if LoginItem.isWaiting {
          Text("Allow Forge in System Settings › General › Login Items.").font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("When a batch finishes") {
        Toggle("Notify me", isOn: $model.settings.notifyWhenFinished)
        Picker("And then", selection: $model.settings.whenFinished) {
          ForEach(AppSettings.WhenFinished.allCases, id: \.self) { Text($0.title).tag($0) }
        }
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

/// Which presets the menu offers: what is used, or what is chosen.
private struct MenuPresets: View {
  @Binding var chosen: [UUID]
  let presets: [RulePreset]

  var body: some View {
    LabeledContent("Presets in the menu") {
      Menu(chosen.isEmpty ? "What I use most" : "\(chosen.count) I chose") {
        Button("What I use most") { chosen = [] }
        Divider()
        ForEach(presets) { preset in
          Toggle(preset.name, isOn: Binding(
            get: { chosen.contains(preset.id) },
            set: { chosen = $0 ? chosen + [preset.id] : chosen.filter { $0 != preset.id } }
          ))
        }
      }
      .fixedSize()
    }
    Text(chosen.isEmpty
      ? "The ones you use on files like the one in your hand come first. It is learnt from History, on this Mac."
      : "In the order you chose them, and only where they suit the file. Up to \(Suggestions.most) are shown.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

/// Apps the menu keeps out of.
private struct IgnoredApps: View {
  @Binding var identifiers: [String]

  var body: some View {
    LabeledContent("Not in") {
      VStack(alignment: .trailing, spacing: 6) {
        ForEach(identifiers, id: \.self) { identifier in
          HStack(spacing: 6) {
            Text(Self.name(of: identifier))
            Button { identifiers = identifiers.filter { $0 != identifier } } label: { Image(systemName: "minus.circle.fill") }
              .buttonStyle(.plain).foregroundStyle(.secondary)
              .accessibilityLabel(Text("Remove \(Self.name(of: identifier))"))
          }
        }
        Button("Add an App…", action: add).controlSize(.small)
      }
    }
  }

  static func name(of identifier: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.deletingPathExtension().lastPathComponent ?? identifier
  }

  private func add() {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = true
    panel.prompt = "Add"
    guard panel.runModal() == .OK else { return }
    let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !identifiers.contains($0) }
    identifiers = identifiers + added
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
