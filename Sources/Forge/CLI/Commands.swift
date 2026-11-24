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

    private static func complain(_ line: String) {
      FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    func run() async throws {
      guard !files.isEmpty else { throw ValidationError("No files given.") }

      let (mode, outputURL) = try destination.resolve()
      var settings = destination.settings
      if let jobs { settings.maxConcurrentNative = max(1, min(8, jobs)) }

      // Asked before the files are looked at: what pandoc reads decides
      // whether an .rst or an .org is a file Forge knows. The tool can wait
      // for the answer; a window cannot, and uses whatever is known by then.
      _ = ExternalBridge.pandocFormats
      let preset = try recipe.resolve(saved: try await ForgeCommand.presets())

      // Each path is taken on its own. One that could not be opened used to
      // stop the whole batch before anything was converted; it is now a
      // failure like any other, said, counted, and gone past.
      var sources: [ProcessableFile] = []
      var turnedAway = 0
      for path in files {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
          Self.complain("failed     \(path): this is a folder. Give the files in it, for example \(path)/*")
          turnedAway += 1
          continue
        }
        do {
          let file = try ProcessableFile(url: URL(fileURLWithPath: path))
          // The preset says which files it is for; the window only offers it
          // for those, and from here it was run on anything.
          guard preset.accepts(file.url) else {
            Self.complain("failed     \(file.fileName): “\(preset.name)” is not for this kind of file")
            turnedAway += 1
            continue
          }
          sources.append(file)
        } catch {
          Self.complain("failed     \(path): \(error.localizedDescription)")
          turnedAway += 1
        }
      }
      for note in recipe.notes(for: sources) { Self.complain("note       \(note)") }

      if let outputURL {
        do {
          try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        } catch {
          throw ValidationError("Cannot use \(outputURL.path) as the destination: \(error.localizedDescription)")
        }
        guard FileManager.default.isWritableFile(atPath: outputURL.path) else {
          throw ValidationError("Cannot write into \(outputURL.path): it is read-only.")
        }
      }

      let reporter = Reporter(names: sources, quiet: quiet)
      var report = await Batch.run(
        sources,
        preset: preset,
        mode: mode,
        destination: outputURL,
        limit: settings.maxConcurrentNative,
        coordinator: ProcessingCoordinator(settings: settings)
      ) { event in
        reporter.report(event)
      }
      report.failed += turnedAway

      // To stderr, with the problems: stdout is the converted paths and
      // nothing else, so that `> converted.txt` is a list of files.
      if !quiet {
        Self.complain(Reporter.summary(report))
      }
      if report.failed > 0 { throw ExitCode.failure }
    }
  }
}

// MARK: - the presets the tool knows

extension ForgeCommand {
  /// The saved presets, or the ones Forge starts with where none has been
  /// saved. The app writes its defaults the first time it opens, so on a Mac
  /// where only the tool had been used the README's own example -
  /// `--preset "Web JPEG"` - answered "Available: none".
  static func presets() async throws -> [RulePreset] {
    let saved = (try? await PersistenceManager.shared.loadAllPresets()) ?? []
    return saved.isEmpty ? await AppModel.defaultPresets : saved
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
      let presets = try await ForgeCommand.presets().sorted { $0.name < $1.name }
      for file in await PersistenceManager.shared.presetFilesThatDoNotRead() {
        FileHandle.standardError.write(Data("note       \(file) is in the presets folder and cannot be read as a preset\n".utf8))
      }

      if namesOnly {
        presets.forEach { print($0.name) }
        return
      }

      let width = presets.map(\.name.count).max() ?? 0
      for preset in presets {
        let recipe = preset.actions.map(Self.describe).joined(separator: " · ")
        // Turned off in the app: it still runs by name, and says so here.
        let state = preset.isEnabled ? "" : "  (turned off in Forge)"
        print("\(preset.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(recipe)\(state)")
      }
    }

    static func describe(_ operation: Operation) -> String {
      switch operation {
      case .convertFormat(let to):
        return (FormatCatalog.fileExtension(for: to) ?? to.identifier).uppercased()
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
      case .film(let settings):
        return settings.summary
      case .limitSize(let bytes):
        return "under \(Int64(bytes).formatted(.byteCount(style: .file)))"
      case .when(let condition, _, _):
        return "if \(condition.summary)"
      case .split(let branches):
        return "\(branches.count) copies"
      case .join:
        return "join"
      case .merge(let kind):
        return "merge into \(kind.title)"
      case .stripMetadata(let policy):
        switch policy {
        case .keepAll: return "keeps all metadata"
        case .stripLocation: return "no location"
        case .stripAll: return "no identifying metadata"
        }
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
      // Everything Forge converts, kind by kind: it used to list pictures,
      // sound and film and leave out documents, data, subtitles, models and
      // fonts, and whatever an installed tool adds.
      func row(_ title: String, _ extensions: [String]) {
        guard !extensions.isEmpty else { return }
        print("  \((title + ":").padding(toLength: 13, withPad: " ", startingAt: 0)) " + extensions.joined(separator: " "))
      }
      func names(_ formats: [OutputFormat]) -> [String] {
        Set(formats.compactMap { $0.type.flatMap(FormatCatalog.fileExtension(for:))?.lowercased() }).sorted()
      }
      let pandoc = ExternalBridge.pandocFormats

      if !writableOnly {
        print("Read")
        for group in InputFormats.groups { row(group.kind.plural, group.extensions) }
        if !pandoc.read.isEmpty { row("pandoc", pandoc.read.sorted()) }
        print("")
        print("Text recognition (\(TextRecognizer.supportedLanguages.count) languages)")
        print("  " + TextRecognizer.supportedLanguages.joined(separator: " "))
        print("")
      }
      print("Write")
      row("images", names(OutputFormat.imagesWithTools))
      row("audio", names(OutputFormat.audio))
      row("video", names(OutputFormat.video))
      row("documents", names(OutputFormat.documents))
      row("data", names(OutputFormat.data))
      row("subtitles", names(OutputFormat.subtitles))
      row("3D models", names(OutputFormat.models))
      row("fonts", names(OutputFormat.fonts))
      if !pandoc.write.isEmpty { row("pandoc", pandoc.write.sorted()) }
      if ExternalTools.locate("ffmpeg") != nil {
        row("ffmpeg", ["sound and film into any container it writes, by extension (see `ffmpeg -muxers`)"])
      }
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
          forge watch ~/Desktop --preset "Web JPEG" --out ~/Desktop --only-renamed
        """
    )

    @Argument(help: "Folder to watch.", completion: .directory)
    var folder: String

    @OptionGroup var recipe: RecipeOptions
    @OptionGroup var destination: DestinationOptions

    @Flag(help: "Also watch subfolders.")
    var recursive = false

    @Flag(help: "Leave every file alone but the ones whose names say what they want: photo_2MB.heic, photo_privacy.heic, or a preset's own word.")
    var onlyRenamed = false

    func run() async throws {
      let watched = URL(fileURLWithPath: folder)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: watched.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
        throw CLIError("\(folder) is not a folder.")
      }

      let (mode, outputURL) = try destination.resolve()
      _ = ExternalBridge.pandocFormats
      let saved = try await ForgeCommand.presets()
      let preset = try recipe.resolve(saved: saved)
      if let outputURL {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
      }

      let runner = WatchRunner(
        preset: preset,
        mode: mode,
        destination: outputURL,
        settings: destination.settings,
        others: saved,
        onlyWhenRenamed: onlyRenamed
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
