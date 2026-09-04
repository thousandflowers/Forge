import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Convert files from Shortcuts, using a preset saved in the app.
///
/// The engine and the presets are the ones the window and the command line
/// use, so a preset made once works in all three.
@available(macOS 13, *)
struct ConvertFilesIntent: AppIntent {
  static var title: LocalizedStringResource = "Convert Files"
  static var description = IntentDescription(
    "Convert files with one of Forge's presets, using only Apple frameworks."
  )

  @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
  var files: [IntentFile]

  @Parameter(title: "Preset", description: "The name of a preset saved in Forge.")
  var presetName: String

  @Parameter(title: "Save Into", description: "Folder to write the converted files into.")
  var destination: IntentFile?

  static var parameterSummary: some ParameterSummary {
    Summary("Convert \(\.$files) with \(\.$presetName)")
  }

  func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
    let presets = try await PersistenceManager.shared.loadAllPresets()
    guard let preset = presets.first(where: {
      $0.name.caseInsensitiveCompare(presetName) == .orderedSame
    }) else {
      let names = presets.map(\.name).sorted().joined(separator: ", ")
      throw ConversionIntentError.noSuchPreset(asked: presetName, available: names)
    }

    guard let folder = destination?.fileURL else {
      throw ConversionIntentError.noDestination
    }

    let sources = files.compactMap { file -> ProcessableFile? in
      guard let url = file.fileURL else { return nil }
      return try? ProcessableFile(url: url)
    }
    guard !sources.isEmpty else { throw ConversionIntentError.nothingToConvert }

    let settings = AppSettings.load()
    let coordinator = ProcessingCoordinator(settings: settings)
    let collected = OutputCollector()

    let report = await Batch.run(
      sources,
      preset: preset,
      mode: .copyTo,
      destination: folder,
      limit: settings.maxConcurrentNative,
      coordinator: coordinator
    ) { event in
      guard case .finished(_, _, let output, _) = event, let output else { return }
      collected.add(output)
    }

    guard report.failed == 0 else {
      throw ConversionIntentError.someFailed(count: report.failed)
    }
    return .result(value: collected.files())
  }
}

@available(macOS 13, *)
enum ConversionIntentError: Error, CustomLocalizedStringResourceConvertible {
  case noSuchPreset(asked: String, available: String)
  case noDestination
  case nothingToConvert
  case someFailed(count: Int)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .noSuchPreset(let asked, let available):
      return "Forge has no preset called “\(asked)”. It has: \(available)"
    case .noDestination:
      return "Choose a folder to save the converted files into."
    case .nothingToConvert:
      return "None of those files is one Forge can open."
    case .someFailed(let count):
      return "\(count) file\(count == 1 ? "" : "s") could not be converted."
    }
  }
}

/// Collects outputs from the batch, which reports them off the main actor.
private final class OutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []

  func add(_ url: URL) {
    lock.lock()
    urls.append(url)
    lock.unlock()
  }

  func files() -> [IntentFile] {
    lock.lock()
    defer { lock.unlock() }
    return urls.map { IntentFile(fileURL: $0) }
  }
}

/// Makes the action discoverable in Shortcuts without the app being opened
/// first.
@available(macOS 13, *)
struct ForgeShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ConvertFilesIntent(),
      phrases: ["Convert files with \(.applicationName)"],
      shortTitle: "Convert Files",
      systemImageName: "hammer"
    )
  }
}
