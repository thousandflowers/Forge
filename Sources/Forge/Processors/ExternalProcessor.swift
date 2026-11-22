import Foundation
import UniformTypeIdentifiers

/// The conversions this Mac can do only because somebody installed the tool
/// for them.
///
/// Forge keeps no table of what these tools support. A table would be wrong
/// the day either of them gains a format, and both answer the question
/// themselves: pandoc lists its input and output formats, and ffmpeg's whole
/// job is to work out which muxer a filename means - so it is asked by being
/// run, and its own complaint is what comes back when it cannot.
///
/// Nothing here is downloaded or bundled. The tool is the user's, installed
/// with the user's own package manager, and Forge only notices it.
enum ExternalBridge {

  struct Plan {
    let tool: URL
    let toolName: String
    let arguments: [String]
    /// A tool that insists on naming its own output writes into this folder,
    /// and whatever lands there is moved to where the conversion wanted it.
    var collectFrom: URL?
  }

  /// LibreOffice, which is an application rather than a command on PATH.
  ///
  /// Looked for where it installs, and on PATH as well, since Homebrew's cask
  /// and a hand-built copy both leave a `soffice` somewhere a shell can see.
  static var libreOffice: URL? {
    if let onPath = ExternalTools.locate("soffice") { return onPath }
    let applications = [
      URL(fileURLWithPath: "/Applications"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]
    for folder in applications {
      let candidate = folder
        .appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// Fonts, which macOS reads and cannot write: CoreText can list a font's
  /// tables and has no public API to make one. fonttools can, and this is the
  /// part of it with a command of its own - WOFF2 in both directions.
  ///
  /// WOFF version 1 is deliberately absent: fonttools exposes no command for
  /// it, and driving its library through `python3 -c` is a different promise
  /// from running a tool the user installed.
  enum Fonts {
    static let sfnt: Set<String> = ["ttf", "otf"]
    static let packed: Set<String> = ["woff2"]

    static func handles(_ ext: String) -> Bool {
      sfnt.contains(ext.lowercased()) || packed.contains(ext.lowercased())
    }

    /// What fonttools should be told to do, or nothing when the pair is not
    /// one it has a command for - ttf to otf among them, which is a change of
    /// outline format rather than a change of container.
    static func arguments(from source: String, to target: String, input: URL, output: URL) -> [String]? {
      if sfnt.contains(source), packed.contains(target) {
        return ["ttLib.woff2", "compress", "-o", output.path, input.path]
      }
      if packed.contains(source), sfnt.contains(target) {
        return ["ttLib.woff2", "decompress", "-o", output.path, input.path]
      }
      return nil
    }
  }

  /// pandoc's own answer to what it reads and writes, asked once.
  ///
  /// Empty when pandoc is not here, which is also the answer to "can pandoc
  /// take this file". Asked again after a tool is installed: a pandoc that
  /// arrived while the app was open answered nothing when it was not here, and
  /// keeping that answer would hide every format it just added.
  static var pandocFormats: (read: Set<String>, write: Set<String>) {
    formats.answer(askPandoc)
  }

  /// Forget what the tools said about themselves.
  static func forgetToolFormats() { formats.clear() }

  /// Whether pandoc has been asked yet. Reading this never runs it.
  static var pandocHasAnswered: Bool { formats.peek() != nil }

  /// Ask pandoc now, off the main thread, so the first question a window
  /// asks already has its answer.
  static func warmUp() {
    Task.detached(priority: .utility) { _ = pandocFormats }
  }

  private static let formats = FormatAnswers()

  private final class FormatAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var known: (read: Set<String>, write: Set<String>)?

    func answer(_ ask: () -> (read: Set<String>, write: Set<String>)) -> (read: Set<String>, write: Set<String>) {
      lock.lock()
      if let known { lock.unlock(); return known }
      lock.unlock()

      let asked = ask()

      lock.lock()
      known = asked
      lock.unlock()
      return asked
    }

    /// What is already known, without asking.
    func peek() -> (read: Set<String>, write: Set<String>)? {
      lock.lock()
      defer { lock.unlock() }
      return known
    }

    func clear() {
      lock.lock()
      known = nil
      lock.unlock()
    }
  }

  /// A format is what pandoc calls it; an extension is what a file is called.
  /// These are the few where the two differ - the rest of the list is used as
  /// it comes back, so a pandoc that learns a format needs no change here.
  private static let extensionNames = [
    "md": "markdown",
    "tex": "latex",
    "adoc": "asciidoc",
    "htm": "html",
    "txt": "plain",
  ]

  /// Whether pandoc reads a file of this extension, as far as it has said.
  /// Asked when a file is first looked at, which can be while a window is
  /// being drawn, so pandoc is not run for the answer.
  static func pandocIsKnownToRead(_ ext: String) -> Bool {
    formats.peek()?.read.contains(name(of: ext)) ?? false
  }

  /// Whether pandoc writes this format. Runs pandoc if it has not been asked.
  static func pandocWritesFormat(_ ext: String) -> Bool { pandocWrites(ext) }

  static func canHandle(_ type: UTType) -> Bool {
    guard let ext = type.preferredFilenameExtension else { return false }
    if Fonts.handles(ext) { return ExternalTools.locate("fonttools") != nil }
    if pandocReads(ext) { return true }
    // ffmpeg is asked about a pair rather than about a file, so anything
    // time-based is worth offering it and nothing else is.
    let isTimeBased = type.conforms(to: .audiovisualContent) || type.conforms(to: .audio)
    if ExternalTools.locate("ffmpeg") != nil, isTimeBased { return true }
    // LibreOffice opens what an office suite opens. Rather than list those
    // formats - which would go stale and is a list nobody can finish - it is
    // offered anything that is neither a picture nor a recording, and only
    // after every processor that reads the format natively has declined.
    return libreOffice != nil && !isTimeBased && !type.conforms(to: .image)
  }

  /// Whether a tool on this Mac writes the format - what `plan` would find a
  /// writer for, asked of the target alone. Pictures stay ImageIO's, which
  /// hands WebP to cwebp itself.
  static func canWrite(_ type: UTType) -> Bool {
    guard let ext = FormatCatalog.fileExtension(for: type) ?? type.preferredFilenameExtension else {
      return false
    }
    if type.conforms(to: .image) {
      return ImageProcessor.isWebP(type) && ExternalTools.locate("cwebp") != nil
    }
    if Fonts.handles(ext) { return ExternalTools.locate("fonttools") != nil }
    // Only what pandoc has already said: this is asked from view bodies, and
    // running pandoc there waited on a subprocess in the middle of a SwiftUI
    // update - the app aborted at launch. `warmUp` asks it in the background.
    if let known = formats.peek(), known.write.contains(name(of: ext)) { return true }
    let isTimeBased = type.conforms(to: .audiovisualContent) || type.conforms(to: .audio)
    return isTimeBased && ExternalTools.locate("ffmpeg") != nil
  }

  /// The subtitle formats ffmpeg writes. It reads the track out of a film and
  /// has no writer for the rest: asked for an SBV it answered "Unable to
  /// choose an output format", which went to the user as it stood.
  private static let subtitlesFFmpegWrites: Set<String> = ["srt", "vtt", "webvtt"]

  private static func isASubtitleNoToolWrites(_ target: String) -> Bool {
    Subtitles.carriesCues(target) && !subtitlesFFmpegWrites.contains(target)
  }

  /// Whether `plan` would find a tool for the pair, judged by the two
  /// extensions: the same conditions in the same order. The conformance tests
  /// fail if the two part.
  ///
  /// This is asked while a sheet is being drawn, so pandoc is consulted only
  /// if it has already answered: running it there waited on a subprocess in
  /// the middle of a SwiftUI update.
  static func couldPlan(from source: String, to target: String) -> Bool {
    if isASubtitleNoToolWrites(target) { return false }
    let nowhere = URL(fileURLWithPath: "/dev/null")
    if ExternalTools.locate("fonttools") != nil,
       Fonts.arguments(from: source, to: target, input: nowhere, output: nowhere) != nil {
      return true
    }
    if ExternalTools.locate("pandoc") != nil, let known = formats.peek(),
       source == "txt" ? !known.read.isEmpty : known.read.contains(name(of: source)),
       known.write.contains(name(of: target)) {
      return true
    }

    let sourceType = UTType(filenameExtension: source)
    let wantsTheSubtitles = Subtitles.carriesCues(target)
      && (sourceType?.conforms(to: .audiovisualContent) ?? false)
    let wantsSomethingStill = !wantsTheSubtitles && (UTType(filenameExtension: target).map {
      $0.conforms(to: .image) || $0.conforms(to: .text) || $0.conforms(to: .pdf)
    } ?? false)
    let sourceIsTimeBased = sourceType.map {
      $0.conforms(to: .audiovisualContent) || $0.conforms(to: .audio)
    } ?? false
    if !wantsSomethingStill, sourceIsTimeBased, ExternalTools.locate("ffmpeg") != nil { return true }
    return wantsSomethingStill && libreOffice != nil
  }

  static func plan(from input: URL, to output: URL, operations: [Operation]) -> Plan? {
    let source = input.pathExtension.lowercased()
    let target = output.pathExtension.lowercased()
    if isASubtitleNoToolWrites(target) { return nil }

    if let fonttools = ExternalTools.locate("fonttools"),
       let arguments = Fonts.arguments(from: source, to: target, input: input, output: output) {
      return Plan(tool: fonttools, toolName: "fonttools", arguments: arguments)
    }

    if let pandoc = ExternalTools.locate("pandoc"), pandocReads(source), pandocWrites(target) {
      // Standalone, or an HTML output is a fragment with no <head> and an EPUB
      // has no spine: a file somebody can open, not a piece of one.
      return Plan(
        tool: pandoc,
        toolName: "pandoc",
        // Plain text is read as Markdown, which it is a subset of: pandoc has
        // no reader called "plain", so a .txt could not become an EPUB.
        arguments: ["--standalone"] + (source == "txt" ? ["-f", "markdown"] : []) + [input.path, "-o", output.path]
      )
    }

    // ffmpeg turns time into time. A picture or a document as the target is
    // not a conversion it should be offered: an audio file asked for a JPEG
    // deserves "Forge cannot convert WAV to JPEG", not ffmpeg's account of an
    // output file with no streams in it.
    let targetType = UTType(filenameExtension: target)
    var wantsSomethingStill = targetType.map {
      $0.conforms(to: .image) || $0.conforms(to: .text) || $0.conforms(to: .pdf)
    } ?? false

    // With one exception: a subtitle asked of a film is a track inside it, and
    // pulling that out is time-based work whatever the file is called.
    let wantsTheSubtitles = Subtitles.carriesCues(target)
      && (UTType(filenameExtension: source)?.conforms(to: .audiovisualContent) ?? false)
    if wantsTheSubtitles { wantsSomethingStill = false }

    // ffmpeg is for time-based files, and asked about nothing else. Without
    // this it took anything that was not a picture or a document, fonts
    // included: a TTF handed to it came back as "Invalid data found when
    // processing input".
    let sourceIsTimeBased = UTType(filenameExtension: source).map {
      $0.conforms(to: .audiovisualContent) || $0.conforms(to: .audio)
    } ?? false

    if !wantsSomethingStill, sourceIsTimeBased, let ffmpeg = ExternalTools.locate("ffmpeg") {
      var arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path]
      if wantsTheSubtitles {
        // The first subtitle track, and nothing else: without a map, ffmpeg
        // would try to carry the picture and the sound into a .srt.
        arguments += ["-map", "0:s:0"]
      }
      // Sound asked of a film is the sound alone. Without this the picture
      // went into the .m4a as well, since the container will hold one.
      if targetType.map(MediaProcessor.isSoundOnly) ?? false {
        arguments.append("-vn")
      } else if !wantsTheSubtitles {
        // Every picture, every soundtrack and every subtitle, not ffmpeg's
        // choice of one of each. The question marks let a film without one
        // through.
        arguments += ["-map", "0:v?", "-map", "0:a?"]
        // Subtitles only where the container has a way to hold them: an MP4 or
        // a MOV as mov_text, Matroska and WebM as text of their own. Mapped into
        // anything else - an MXF, an AVI - ffmpeg stopped looking for an encoder.
        if ["mp4", "m4v", "mov"].contains(target) { arguments += ["-map", "0:s?", "-c:s", "mov_text"] }
        if target == "mkv" { arguments += ["-map", "0:s?", "-c:s", "srt"] }
        if target == "webm" { arguments += ["-map", "0:s?", "-c:s", "webvtt"] }
      }
      // An Ogg file holds Opus unless something else was asked for. Left to
      // itself, an ffmpeg built without Vorbis puts FLAC in it - which is what
      // `--to opus` produced, and which macOS cannot then read back.
      if ["ogg", "oga", "opus"].contains(target), MediaProcessor.chosenCodec(in: operations) == nil {
        arguments += ["-c:a", "libopus"]
      }
      // MXF takes sound at 48 kHz and nothing else; a film recorded at 44.1
      // failed with ffmpeg's "only 48khz is implemented".
      if target == "mxf" { arguments += ["-ar", "48000"] }
      if let filter = Self.scaling(in: operations) { arguments += ["-vf", filter] }
      // The encoder that was asked for, and how hard to squeeze: both were
      // dropped on this path, so a codec chosen for an MKV made no difference.
      for operation in operations {
        switch operation {
        case .encode(let codec):
          if let name = Self.ffmpegName[codec] { arguments += [codec.isVideo ? "-c:v" : "-c:a", name] }
        case .quality(let level):
          if targetType.map(MediaProcessor.isSoundOnly) ?? false {
            arguments += ["-b:a", "\(MediaProcessor.bitrate(forQuality: level, channels: 2) / 1000)k"]
          } else {
            // 100 is visually lossless and 1 is barely a picture: the encoders'
            // own scale runs the other way, from about 16 to about 40.
            arguments += ["-crf", "\(40 - level * 24 / 100)"]
          }
        default:
          break
        }
      }
      // ffmpeg carries every tag across unless told otherwise, so a privacy
      // level was a promise this path did not keep. It removes a named tag or
      // all of them; the thorough level takes all, which errs the safe way.
      switch PrivacyFilter.policy(in: operations) {
      case .keepAll: break
      case .stripLocation: arguments += ["-metadata", "location=", "-metadata", "location-eng="]
      case .stripAll: arguments += ["-map_metadata", "-1"]
      }
      arguments.append(output.path)
      return Plan(tool: ffmpeg, toolName: "ffmpeg", arguments: arguments)
    }

    if !wantsSomethingStill { return nil }

    if let office = libreOffice {
      // LibreOffice names its own output, after the input and the format it
      // was asked for, so it is given a folder to itself and the one file
      // that appears is moved into place.
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-office-\(UUID().uuidString)", isDirectory: true)
      return Plan(
        tool: office,
        toolName: "LibreOffice",
        arguments: [
          // A profile of its own: converting while LibreOffice is open in
          // front of somebody otherwise fails on a locked user directory.
          "-env:UserInstallation=file://\(folder.path)/profile",
          "--headless",
          "--convert-to", target,
          "--outdir", folder.path,
          input.path,
        ],
        collectFrom: folder
      )
    }

    return nil
  }

  /// What ffmpeg calls each encoder.
  private static let ffmpegName: [Codec: String] = [
    .h264: "libx264", .hevc: "libx265", .proRes422: "prores_ks", .proRes4444: "prores_ks",
    .aac: "aac", .appleLossless: "alac", .flac: "flac", .linearPCM: "pcm_s16le", .opus: "libopus",
  ]

  /// The new size as ffmpeg's scale filter, honouring the fit. A bare scale to
  /// both sides stretched every film, whatever fit had been chosen.
  private static func scaling(in operations: [Operation]) -> String? {
    for operation in operations {
      guard case .resize(let width, let height, let mode) = operation, width != nil || height != nil else { continue }
      // -2 rather than -1 for a side that follows: some encoders refuse an odd
      // number of pixels, and this rounds to an even one.
      guard let width, let height else { return "scale=\(width ?? -2):\(height ?? -2)" }
      switch mode {
      case .stretch:
        return "scale=\(width):\(height)"
      case .proportional:
        return "scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2"
      case .cropCenter:
        return "scale=\(width):\(height):force_original_aspect_ratio=increase,crop=\(width):\(height)"
      case .pad:
        return "scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2"
      }
    }
    return nil
  }

  private static func size(in operations: [Operation]) -> (width: Int?, height: Int?)? {
    for operation in operations {
      if case .resize(let width, let height, _) = operation, width != nil || height != nil {
        return (width, height)
      }
    }
    return nil
  }

  private static func pandocReads(_ ext: String) -> Bool {
    ext.lowercased() == "txt" ? !pandocFormats.read.isEmpty : pandocFormats.read.contains(name(of: ext))
  }

  private static func pandocWrites(_ ext: String) -> Bool {
    pandocFormats.write.contains(name(of: ext))
  }

  private static func name(of ext: String) -> String {
    let lowercased = ext.lowercased()
    return extensionNames[lowercased] ?? lowercased
  }

  private static func askPandoc() -> (read: Set<String>, write: Set<String>) {
    guard let pandoc = ExternalTools.locate("pandoc") else { return ([], []) }
    // Its own internal formats are in both lists - `json`, `native` and `xml`
    // are how pandoc writes down a document it has parsed, not JSON or XML as
    // anybody means them. Left in, a CSV asked for XML became pandoc's notes
    // on a table, reported as converted.
    let itsOwn: Set<String> = ["json", "native", "xml"]
    return (
      list(pandoc, "--list-input-formats").subtracting(itsOwn),
      list(pandoc, "--list-output-formats").subtracting(itsOwn)
    )
  }

  private static func list(_ tool: URL, _ argument: String) -> Set<String> {
    let process = Process()
    process.executableURL = tool
    process.arguments = [argument]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    guard (try? process.run()) != nil else { return [] }
    let said = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: said, encoding: .utf8) else {
      return []
    }
    return Set(
      text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }
    )
  }
}

/// Runs the conversions the frameworks cannot, through a tool the user
/// installed. Asked last, so anything macOS can do itself is still done by
/// macOS.
final class ExternalProcessor: FileProcessor, @unchecked Sendable {
  let name = "External Tools"

  func canProcess(_ file: ProcessableFile) -> Bool {
    ExternalBridge.canHandle(file.fileType)
  }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    ExternalBridge.couldPlan(from: file.url.pathExtension.lowercased(), to: Conversions.fileExtension(of: target))
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    let inputType = UTType(filenameExtension: input.pathExtension) ?? .data
    let outputType = UTType(filenameExtension: output.pathExtension) ?? .data

    guard let plan = ExternalBridge.plan(from: input, to: output, operations: operations) else {
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputType)
    }

    // These tools report progress on their own terms and in their own format.
    // Rather than parse it, a file is one step: it either converts or it does
    // not.
    progress(0.1)

    if let folder = plan.collectFrom {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    defer {
      if let folder = plan.collectFrom { try? FileManager.default.removeItem(at: folder) }
    }

    do {
      try ExternalTools.run(plan.tool, plan.arguments)
    } catch {
      throw Self.explain(error, about: input)
    }

    if let folder = plan.collectFrom {
      try Self.collect(from: folder, to: output, wanted: output.pathExtension, tool: plan.toolName)
    }
    progress(1.0)

    guard FileManager.default.fileExists(atPath: output.path) else {
      throw ProcessingError.conversionFailed(
        reason: "\(plan.toolName) reported success and wrote nothing"
      )
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  /// Say what went wrong in the terms of the file rather than the tool's.
  ///
  /// Asked for a subtitle track that is not there, ffmpeg answers "Stream map
  /// '' matches no streams. To ignore this, add a trailing '?' to the map",
  /// which is true, is about a flag the user never typed, and does not say the
  /// film has no subtitles in it.
  static func explain(_ error: Error, about input: URL) -> Error {
    let said = error.localizedDescription

    // ffmpeg could not read the file either. Its own account - "moov atom not
    // found" - is true and means nothing to anybody who has not written a
    // demuxer; what it means is that the file is not whole.
    if said.contains("[in#") || said.contains("Error opening input")
        || said.contains("Invalid data found when processing input") {
      return ProcessingError.conversionFailed(
        reason: "\(input.lastPathComponent) cannot be opened: it looks damaged or incomplete. "
          + "If it is still being copied or downloaded, try again once it has arrived."
      )
    }

    if said.contains("matches no streams") {
      return ProcessingError.conversionFailed(
        reason: "There are no subtitles in \(input.lastPathComponent)"
      )
    }

    // fonttools reads a WOFF2 with what Python has; writing one needs the
    // brotli module, which pip does not install alongside it. Its answer is a
    // traceback ending in "No module named brotli", which says nothing about
    // what to do next.
    if said.contains("No module named brotli") {
      return ProcessingError.conversionFailed(
        reason: "fonttools is here but cannot write WOFF2 without its brotli module. "
          + "`pip3 install --user brotli` adds it."
      )
    }

    return error
  }

  /// Move what a tool wrote under its own name to where the conversion wanted
  /// it. The folder is this conversion's alone, so the file with the right
  /// extension in it is the file that was just made - and a tool that exits
  /// successfully having written nothing is a failure, not an empty result.
  static func collect(from folder: URL, to output: URL, wanted: String, tool: String) throws {
    let written = (try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    )) ?? []

    guard let made = written.first(where: {
      $0.pathExtension.lowercased() == wanted.lowercased()
    }) else {
      throw ProcessingError.conversionFailed(
        reason: "\(tool) finished without writing a \(wanted.uppercased())"
      )
    }

    if FileManager.default.fileExists(atPath: output.path) {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: made)
    } else {
      try FileManager.default.moveItem(at: made, to: output)
    }
  }
}
