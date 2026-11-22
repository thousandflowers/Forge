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
    // Each of these was accepted, and one half of it quietly dropped:
    // `--overwrite --out folder` replaced the original and never looked at
    // the folder.
    if overwrite, out != nil {
      throw ValidationError("--overwrite replaces the originals where they are, so it takes no --out. Choose one.")
    }
    if overwrite, move {
      throw ValidationError("--move and --overwrite are two different things to do with the originals. Choose one.")
    }
    if noBackup, !overwrite {
      throw ValidationError("--no-backup is about --overwrite, which was not given.")
    }
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
  /// No default of its own: unset means "whatever the app is set to", so
  /// changing "Resizing means" in Settings changes what `forge` does too. A
  /// fixed default here made that setting mean nothing outside the window.
  var fit: ResizeFitMode?

  @Option(help: "Filter to apply: grayscale, sepia, blur, sharpen, invert. Repeat it for more than one.")
  var filter: [FilterType] = []

  // One value at a time: taking everything up to the next option took the
  // file that followed for a second language.
  @Option(
    name: .customLong("ocr-language"),
    help: "Language of the text in a picture, of the speech in a recording, or of the voice that reads a document: it-IT. Several for text: it-IT,en-US. Without it, text is detected; speech is taken to be in the Mac's language."
  )
  var ocrLanguages: [String] = []

  @Option(help: "Answer a question the preset asks, as key=value, e.g. width=640. Unanswered questions take their default.")
  var answer: [String] = []

  /// The languages asked for, whether given one option each or in one list.
  var languages: [String] {
    ocrLanguages.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  @Option(help: "Encoder to use where the container allows more than one: h264, hevc, proRes422, aac, appleLossless, flac, opus.")
  var codec: Codec?

  /// Build the preset this run should use, from a saved one or from the flags.
  func resolve(saved: [RulePreset]) throws -> RulePreset {
    if let preset {
      // A preset is the whole recipe. The options beside it were dropped
      // without a word, which read as if they had been applied.
      let beside = [
        format.map { _ in "--to" }, resize.map { _ in "--resize" }, quality.map { _ in "--quality" },
        fit.map { _ in "--fit" }, filter.isEmpty ? nil : "--filter", codec.map { _ in "--codec" },
      ].compactMap { $0 }
      guard beside.isEmpty else {
        throw ValidationError(
          "--preset is the whole recipe, so \(beside.joined(separator: ", ")) would be ignored. Give the preset alone, or the options alone."
        )
      }
      let matches = saved.filter { $0.name.caseInsensitiveCompare(preset) == .orderedSame }
      guard let match = matches.first else {
        let names = saved.map(\.name).sorted().joined(separator: ", ")
        throw ValidationError("No preset called “\(preset)”. Available: \(names.isEmpty ? "none" : names)")
      }
      guard matches.count == 1 else {
        throw ValidationError("\(matches.count) presets are called “\(preset)”. Rename one in Forge so the name says which.")
      }
      guard match.doesSomething || !match.parameters.isEmpty else {
        throw ValidationError("“\(match.name)” has no steps, so there is nothing for it to do.")
      }
      return match.answered(with: try answers(for: match))
    }
    guard answer.isEmpty else {
      throw ValidationError("--answer answers a preset's question, and no --preset was given.")
    }
    if fit != nil, resize == nil {
      throw ValidationError("--fit says how to fit a new size, and no --resize was given.")
    }

    guard format != nil || resize != nil || quality != nil || !filter.isEmpty || !ocrLanguages.isEmpty || codec != nil else {
      throw ValidationError("Nothing to do: pass --preset, or one of --to, --resize, --quality, --filter.")
    }

    var preset = RulePreset(
      name: "command line",
      description: "Built from command-line options.",
      targetFormat: try targetType(),
      resize: try resizeSpec(),
      quality: try validatedQuality(),
      filters: filter,
      category: .custom,
      ocrLanguages: languages
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
    if let type = UTType(filenameExtension: format), !type.isDynamic { return type }
    // Only then: the formats macOS has no type for and Forge writes anyway.
    // Taking this branch first would have handed back a dynamic type for
    // `txt`, which has a perfectly good one of its own.
    if Toml.handles(format) || Subtitles.writes(format),
       let text = UTType(filenameExtension: format, conformingTo: .plainText) {
      return text
    }
    // WOFF2 has no type on macOS either, and is a font rather than text.
    if ExternalBridge.Fonts.handles(format),
       let font = UTType(filenameExtension: format, conformingTo: .font) {
      return font
    }
    // What pandoc writes and macOS has no name for: rst, org, tex, ipynb.
    if ExternalBridge.pandocWritesFormat(format),
       let text = UTType(filenameExtension: format, conformingTo: .text) {
      return text
    }
    throw ValidationError("“\(format)” is not a format this Mac knows. Try `forge formats`.")
  }

  /// What was asked for and will make no difference, said rather than done
  /// in silence: a quality for a format that has none, an encoder for
  /// something that is not sound or film.
  func notes(for files: [ProcessableFile]) -> [String] {
    var notes: [String] = []
    let target = format.flatMap { UTType(filenameExtension: $0) }
    let kinds = Set(files.compactMap { ConvertKind(fileType: $0.fileType) })
    if quality != nil, let target, target.conforms(to: .image),
       [UTType.png, .tiff, .gif, .bmp, .pdf].contains(where: { target.conforms(to: $0) }) {
      notes.append("--quality does nothing for \(format?.uppercased() ?? "this format"): it keeps every pixel as it is.")
    }
    if let codec, !kinds.isEmpty, kinds.isDisjoint(with: [.audio, .video]) {
      notes.append("--codec \(codec.rawValue) is for sound and film, and none of these files is either.")
    }
    return notes
  }

  /// The answers given with --answer, checked against what the preset asks.
  private func answers(for preset: RulePreset) throws -> [String: Double] {
    var answers: [String: Double] = [:]
    for pair in answer {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, let value = Double(parts[1]) else {
        throw ValidationError("--answer wants key=value with a number, e.g. width=640. Got “\(pair)”.")
      }
      guard let asked = preset.parameters.first(where: { $0.key == parts[0] }) else {
        let keys = preset.parameters.map(\.key).joined(separator: ", ")
        throw ValidationError("“\(preset.name)” does not ask for “\(parts[0])”. It asks for: \(keys.isEmpty ? "nothing" : keys).")
      }
      guard asked.kind.range.contains(value) else {
        throw ValidationError("\(asked.key) is \(Int(asked.kind.range.lowerBound)) to \(Int(asked.kind.range.upperBound)). Got \(parts[1]).")
      }
      answers[asked.key] = value
    }
    return answers
  }

  /// The largest side a picture is asked to have: what the Width question
  /// allows. Without a ceiling, 999999x999999 ran until it was stopped.
  private static let sides = PresetParameter.Kind.width.range

  private func resizeSpec() throws -> ResizeSpec? {
    guard let resize else { return nil }
    let parts = resize.lowercased().split(separator: "x", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else {
      throw ValidationError("--resize wants WIDTHxHEIGHT, e.g. 1280x720. Got “\(resize)”.")
    }
    // A side is left out or it is a whole number: `1.5x2` used to be read as
    // `x2`, and `0x0` as a size.
    func side(_ text: String) throws -> Int? {
      if text.isEmpty { return nil }
      guard let value = Int(text), Self.sides.contains(Double(value)) else {
        throw ValidationError(
          "--resize takes whole numbers from \(Int(Self.sides.lowerBound)) to \(Int(Self.sides.upperBound)), e.g. 1280x720. Got “\(resize)”."
        )
      }
      return value
    }
    let width = try side(parts[0])
    let height = try side(parts[1])
    guard width != nil || height != nil else {
      throw ValidationError("--resize needs at least one side, e.g. 1280x or x720.")
    }
    return ResizeSpec(width: width, height: height, fitMode: fit ?? AppSettings.load().defaultFitMode)
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

    let work = Task {
      do {
        var command = try ForgeCommand.parseAsRoot(arguments)
        if var asynchronous = command as? AsyncParsableCommand {
          try await asynchronous.run()
        } else {
          try command.run()
        }
        // A batch that was stopped reports what it got through, then says it
        // was stopped: 0 would tell a script the conversion succeeded.
        if Task.isCancelled { exit(interruptedStatus) }
      } catch {
        if Task.isCancelled { exit(interruptedStatus) }
        ForgeCommand.exit(withError: error)
      }
    }
    // Ctrl-C or a kill used to end the process mid-file, leaving the empty
    // file that holds the output's name and the half-written scratch beside
    // it. Now it cancels the work, the conversion clears up after itself,
    // and the process leaves as an interrupted one does.
    let stops = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { work.cancel() }
      source.resume()
      return source
    }
    await work.value
    stops.forEach { $0.cancel() }
  }

  /// What a shell reports for a command stopped with Ctrl-C: 128 + SIGINT.
  static let interruptedStatus: Int32 = 128 + SIGINT
}

extension Codec: ExpressibleByArgument {}
