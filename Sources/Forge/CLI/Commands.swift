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
struct Extensions: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The optional tools Forge hosts builds of.",
    discussion: """
      Forge converts with Apple's frameworks and needs none of these. An \
      extension adds what no framework on the Mac can do. It is downloaded on \
      request, checked against the checksum in Forge's manifest, and kept in \
      Forge's own folder rather than on your PATH.
      """,
    subcommands: [List.self, Add.self, Remove.self],
    defaultSubcommand: List.self
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "What is on offer, and what is already here."
    )

    func run() async throws {
      let manager = ExtensionManager.shared
      let installed = Dictionary(
        manager.installedExtensions().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
      )
      let offered = try await manager.availableExtensions()

      guard !offered.isEmpty else {
        print("The manifest lists no tools.")
        return
      }

      for tool in offered {
        let build = tool.build(for: .current)
        let size = build.map { ByteCountFormatter.string(fromByteCount: $0.sizeBytes, countStyle: .file) }
        let state: String
        if let here = installed[tool.id] {
          state = here.version == tool.version ? "installed" : "installed \(here.version), \(tool.version) offered"
        } else if build == nil {
          state = "no build for this Mac"
        } else {
          state = "available, \(size ?? "unknown size")"
        }
        print("\(tool.id)  \(tool.version)  \(state)")
        print("  \(tool.description). \(tool.license). \(tool.sourceURL)")
      }
    }
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Download a tool and put it where Forge will find it."
    )

    @Argument(help: "The tool's name, as `forge extensions list` prints it.")
    var tool: String

    @Flag(name: .customLong("yes"), help: "Agree to the download without being asked.")
    var agreed = false

    func run() async throws {
      let manager = ExtensionManager.shared
      guard let offer = try await manager.availableExtensions().first(where: { $0.id == tool }) else {
        throw ValidationError("Forge does not offer a tool called \(tool).")
      }
      guard let build = offer.build(for: .current) else {
        throw ValidationError("There is no \(offer.displayName) build for this Mac's processor.")
      }

      // A download writes to the user's machine, so what is about to arrive is
      // printed first and agreed to explicitly - the same rule the app follows
      // before it runs a Homebrew command.
      print("\(offer.displayName) \(offer.version), \(offer.license)")
      print("  \(offer.description)")
      print("  \(build.url.absoluteString)")
      print("  \(ByteCountFormatter.string(fromByteCount: build.sizeBytes, countStyle: .file)), sha256 \(build.sha256)")
      guard agreed else {
        throw ValidationError("Pass --yes to download it.")
      }

      let reported = LastPercent()
      let installed = try await manager.install(offer.id) { fraction in
        if let step = reported.crossed(fraction) { print("  \(step)%") }
      }
      print("Installed \(installed.id) \(installed.version) in \(installed.path.path)")
    }
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Delete a tool Forge fetched. Only Forge's own copy is touched."
    )

    @Argument(help: "The tool's name.")
    var tool: String

    func run() async throws {
      try await ExtensionManager.shared.remove(tool)
      print("Removed \(tool).")
    }
  }

  /// Prints every tenth of a download rather than every packet.
  private final class LastPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0

    func crossed(_ fraction: Double) -> Int? {
      let step = Int(fraction * 10) * 10
      lock.lock()
      defer { lock.unlock() }
      guard step > last else { return nil }
      last = step
      return step
    }
  }
}

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
      case .limitSize(let bytes):
        return "under \(Int64(bytes).formatted(.byteCount(style: .file)))"
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
      Set(types.compactMap { FormatCatalog.fileExtension(for: $0)?.lowercased() })
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
