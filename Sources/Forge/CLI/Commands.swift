import ArgumentParser
import Foundation
import UniformTypeIdentifiers

// MARK: - convert

extension ForgeCommand {
  @available(macOS 13, *)
struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Convert files.",
      discussion: """
        Examples:
          forge convert *.png --to jpeg --quality 80 --out ./web
          forge convert photo.heic --preset "Web JPEG" --out ~/Desktop
          forge convert clip.mov --to mp4 --resize 1280x720 --out ./out
          forge convert clip.mov --to gif --out ./out
          forge convert scan.pdf --to txt --ocr-language it-IT --out ./text
          forge convert *.png --to jpeg --overwrite
        """
    )

    @Argument(help: "Files to convert.", completion: .file())
    var files: [String]

    @OptionGroup var recipe: RecipeOptions
    @OptionGroup var destination: DestinationOptions

    @Option(name: [.customShort("j"), .long], help: "How many files to convert at once.")
    var jobs: Int?

    @Flag(name: [.customShort("q"), .long], help: "Only report failures.")
    var quiet = false

    func run() async throws {
      guard !files.isEmpty else { throw ValidationError("No files given.") }

      let (mode, outputURL) = try destination.resolve()
      var settings = destination.settings
      if let jobs { settings.maxConcurrentNative = max(1, min(8, jobs)) }

      let saved = try await PersistenceManager.shared.loadAllPresets()
      let preset = try recipe.resolve(saved: saved)

      let sources = try files.map { path -> ProcessableFile in
        do {
          return try ProcessableFile(url: URL(fileURLWithPath: path))
        } catch {
          throw CLIError("\(path): \(error.localizedDescription)")
        }
      }

      if let outputURL {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
      }

      let reporter = Reporter(names: sources, quiet: quiet)
      let report = await Batch.run(
        sources,
        preset: preset,
        mode: mode,
        destination: outputURL,
        limit: settings.maxConcurrentNative,
        coordinator: ProcessingCoordinator(settings: settings)
      ) { event in
        reporter.report(event)
      }

      if !quiet {
        print(Reporter.summary(report))
      }
      if report.failed > 0 { throw ExitCode.failure }
    }
  }
}

// MARK: - presets

extension ForgeCommand {
  @available(macOS 13, *)
struct Presets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List the presets Forge knows about.",
      discussion: "These are the same presets the app shows, so one saved in the window works here."
    )

    @Flag(help: "Print just the names, one per line, for scripting.")
    var namesOnly = false

    func run() async throws {
      let presets = try await PersistenceManager.shared.loadAllPresets().sorted { $0.name < $1.name }
      guard !presets.isEmpty else {
        print("No presets yet. Open Forge once to have the defaults created.")
        return
      }

      if namesOnly {
        presets.forEach { print($0.name) }
        return
      }

      let width = presets.map(\.name.count).max() ?? 0
      for preset in presets {
        let recipe = preset.toOperations().map(Self.describe).joined(separator: " · ")
        print("\(preset.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(recipe)")
      }
    }

    private static func describe(_ operation: Operation) -> String {
      switch operation {
      case .convertFormat(let to):
        return (to.preferredFilenameExtension ?? to.identifier).uppercased()
      case .resize(let width, let height, let mode):
        let size = "\(width.map(String.init) ?? "auto")×\(height.map(String.init) ?? "auto")"
        return "\(size) \(mode.rawValue)"
      case .quality(let level):
        return "q\(level)"
      case .filter(let type):
        return type.rawValue
      case .recognizeText(let languages):
        return languages.isEmpty ? "read text" : "read text (\(languages.joined(separator: ", ")))"
      case .encode(let codec):
        return codec.title
      }
    }
  }
}

// MARK: - formats

extension ForgeCommand {
  struct Formats: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show what this Mac can read and write.",
      discussion: "Asked of ImageIO and AVFoundation at run time, so it is what your machine really supports."
    )

    @Flag(help: "Only list formats that can be written.")
    var writableOnly = false

    func run() throws {
      if !writableOnly {
        print("Read")
        print("  images: " + Self.list(FormatCatalog.readableImageTypes))
        print("  media:  " + Self.list(FormatCatalog.readableMediaTypes))
        print("")
      }
      if !writableOnly {
        print("Text recognition (\(TextRecognizer.supportedLanguages.count) languages)")
        print("  " + TextRecognizer.supportedLanguages.joined(separator: " "))
        print("")
      }
      print("Write")
      print("  images: " + Self.list(FormatCatalog.writableImageTypes))
      print("  audio:  " + Self.list(Set(FormatCatalog.writableAudioTypes.keys)))
      print("  video:  " + Self.list(FormatCatalog.writableVideoTypes))
    }

    private static func list(_ types: Set<UTType>) -> String {
      Set(types.compactMap { $0.preferredFilenameExtension?.lowercased() })
        .sorted()
        .joined(separator: " ")
    }
  }
}

// MARK: - watch

extension ForgeCommand {
  @available(macOS 13, *)
struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Watch a folder and convert whatever lands in it.",
      discussion: """
        Runs in the foreground until interrupted. Files Forge writes itself are
        ignored, so the destination may sit inside the watched folder.

          forge watch ~/Desktop/incoming --preset "Web JPEG" --out ~/Desktop/web
        """
    )

    @Argument(help: "Folder to watch.", completion: .directory)
    var folder: String

    @OptionGroup var recipe: RecipeOptions
    @OptionGroup var destination: DestinationOptions

    @Flag(help: "Also watch subfolders.")
    var recursive = false

    func run() async throws {
      let watched = URL(fileURLWithPath: folder)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: watched.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
        throw CLIError("\(folder) is not a folder.")
      }

      let (mode, outputURL) = try destination.resolve()
      let saved = try await PersistenceManager.shared.loadAllPresets()
      let preset = try recipe.resolve(saved: saved)
      if let outputURL {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
      }

      let runner = WatchRunner(
        preset: preset,
        mode: mode,
        destination: outputURL,
        settings: destination.settings
      )
      try await runner.run(
        folder: MonitoredFolder(
          url: watched,
          ruleId: preset.id,
          destinationMode: mode,
          destinationURL: outputURL,
          includeSubfolders: recursive
        )
      )
    }
  }
}

// MARK: - Errors

struct CLIError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
