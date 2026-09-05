import ArgumentParser
import Foundation
import UniformTypeIdentifiers

/// The `forge` command line tool.
///
/// It runs the same engine as the app and reads the same presets, so a preset
/// saved in the window is immediately usable from a script.
@available(macOS 13, *)
struct ForgeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: LaunchMode.toolName,
    abstract: "Batch file conversion on macOS, using only Apple frameworks.",
    version: Bundle.main.shortVersion,
    subcommands: [Convert.self, Presets.self, Formats.self, Watch.self],
    defaultSubcommand: Convert.self
  )
}

// MARK: - Shared options

/// Where converted files go. Mirrors the app's three destination modes.
struct DestinationOptions: ParsableArguments {
  @Option(name: [.customShort("o"), .long], help: "Folder to write converted files into.")
  var out: String?

  @Flag(help: "Move the originals instead of copying them.")
  var move = false

  @Flag(help: "Replace the originals in place. Keeps a backup unless --no-backup.")
  var overwrite = false

  @Flag(name: .customLong("no-backup"), help: "With --overwrite, do not keep a copy of the original.")
  var noBackup = false

  func resolve() throws -> (mode: DestinationMode, url: URL?) {
    switch (overwrite, out) {
    case (true, _):
      return (.overwrite, nil)
    case (false, let path?):
      return (move ? .moveTo : .copyTo, URL(fileURLWithPath: path))
    case (false, nil):
      throw ValidationError("Choose a destination: --out <folder>, or --overwrite to convert in place.")
    }
  }

  var settings: AppSettings {
    var settings = AppSettings.load()
    if overwrite { settings.createBackupBeforeOverwrite = !noBackup }
    return settings
  }
}

/// How to convert. Either a saved preset, or the pieces spelled out.
struct RecipeOptions: ParsableArguments {
  @Option(name: [.customShort("p"), .long], help: "Name of a saved preset.")
  var preset: String?

  @Option(name: [.customShort("t"), .customLong("to")], help: "Target format, by extension (jpeg, png, m4a, mp4…).")
  var format: String?

  @Option(help: "Target size as WIDTHxHEIGHT, e.g. 1280x720.")
  var resize: String?

  @Option(help: "Quality, 1 to 100.")
  var quality: Int?

  @Option(help: "Fit mode when resizing: proportional, cropCenter, stretch, pad.")
  var fit: ResizeFitMode = .proportional

  @Option(help: "Filter to apply: grayscale, sepia, blur, sharpen, invert.")
  var filter: FilterType?

  @Option(
    name: .customLong("ocr-language"),
    parsing: .upToNextOption,
    help: "Languages to look for when reading text, e.g. it-IT. Omit to detect automatically."
  )
  var ocrLanguages: [String] = []

  @Option(help: "Encoder to use where the container allows more than one: h264, hevc, proRes422, aac, appleLossless, flac, opus.")
  var codec: Codec?

  /// Build the preset this run should use, from a saved one or from the flags.
  func resolve(saved: [RulePreset]) throws -> RulePreset {
    if let preset {
      guard let match = saved.first(where: { $0.name.caseInsensitiveCompare(preset) == .orderedSame }) else {
        let names = saved.map(\.name).sorted().joined(separator: ", ")
        throw ValidationError("No preset called “\(preset)”. Available: \(names.isEmpty ? "none" : names)")
      }
      return match
    }

    guard format != nil || resize != nil || quality != nil || filter != nil || !ocrLanguages.isEmpty || codec != nil else {
      throw ValidationError("Nothing to do: pass --preset, or one of --to, --resize, --quality, --filter.")
    }

    var preset = RulePreset(
      name: "command line",
      description: "Built from command-line options.",
      targetFormat: try targetType(),
      resize: try resizeSpec(),
      quality: try validatedQuality(),
      filters: filter.map { [$0] } ?? [],
      category: .custom,
      ocrLanguages: ocrLanguages
    )
    if let codec {
      guard Codec.available.contains(codec) else {
        throw ValidationError("This Mac cannot encode \(codec.title). Try `forge formats`.")
      }
      preset.actions.append(.encode(codec: codec))
    }
    return preset
  }

  private func targetType() throws -> UTType? {
    guard let format else { return nil }
    // The subtitle formats have no type on macOS and are written all the same,
    // so they are named by the extension they are asked for.
    if Subtitles.writes(format), let text = UTType(filenameExtension: format, conformingTo: .plainText) {
      return text
    }
    guard let type = UTType(filenameExtension: format), !type.isDynamic else {
      throw ValidationError("“\(format)” is not a format this Mac knows. Try `forge formats`.")
    }
    return type
  }

  private func resizeSpec() throws -> ResizeSpec? {
    guard let resize else { return nil }
    let parts = resize.lowercased().split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      throw ValidationError("--resize wants WIDTHxHEIGHT, e.g. 1280x720. Got “\(resize)”.")
    }
    let width = Int(parts[0])
    let height = Int(parts[1])
    guard width != nil || height != nil else {
      throw ValidationError("--resize needs at least one side, e.g. 1280x or x720.")
    }
    return ResizeSpec(width: width, height: height, fitMode: fit)
  }

  private func validatedQuality() throws -> Int? {
    guard let quality else { return nil }
    guard (1...100).contains(quality) else {
      throw ValidationError("--quality is 1 to 100. Got \(quality).")
    }
    return quality
  }
}

extension ResizeFitMode: ExpressibleByArgument {}
extension FilterType: ExpressibleByArgument {}

/// Entry point for the command-line side.
///
/// The dispatch lives in a genuinely `async` function on purpose.
/// `AsyncParsableCommand` inherits a synchronous `run()` alongside its async
/// one, and outside an async context the synchronous one wins the overload -
/// which makes every command print its help and exit successfully without
/// doing anything.
@available(macOS 13, *)
enum CLI {
  static func run(_ arguments: [String]) async {
    // `forge watch` runs for hours and its output is usually redirected to a
    // log, where a block-buffered stdout means the file stays empty until the
    // buffer fills or the process exits - and a watcher killed with a signal
    // never gets that far. A terminal line-buffers; a log should too.
    setvbuf(stdout, nil, _IOLBF, 0)

    do {
      var command = try ForgeCommand.parseAsRoot(arguments)
      if var asynchronous = command as? AsyncParsableCommand {
        try await asynchronous.run()
      } else {
        try command.run()
      }
    } catch {
      ForgeCommand.exit(withError: error)
    }
  }
}

extension Codec: ExpressibleByArgument {}
