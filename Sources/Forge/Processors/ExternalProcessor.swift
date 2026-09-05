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

  /// pandoc's own answer to what it reads and writes, asked once.
  ///
  /// Empty when pandoc is not here, which is also the answer to "can pandoc
  /// take this file".
  static let pandocFormats: (read: Set<String>, write: Set<String>) = askPandoc()

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

  static func canHandle(_ type: UTType) -> Bool {
    guard let ext = type.preferredFilenameExtension else { return false }
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

  static func plan(from input: URL, to output: URL, operations: [Operation]) -> Plan? {
    let source = input.pathExtension.lowercased()
    let target = output.pathExtension.lowercased()

    if let pandoc = ExternalTools.locate("pandoc"), pandocReads(source), pandocWrites(target) {
      // Standalone, or an HTML output is a fragment with no <head> and an EPUB
      // has no spine: a file somebody can open, not a piece of one.
      return Plan(
        tool: pandoc,
        toolName: "pandoc",
        arguments: ["--standalone", input.path, "-o", output.path]
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

    if !wantsSomethingStill, let ffmpeg = ExternalTools.locate("ffmpeg") {
      var arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path]
      if wantsTheSubtitles {
        // The first subtitle track, and nothing else: without a map, ffmpeg
        // would try to carry the picture and the sound into a .srt.
        arguments += ["-map", "0:s:0"]
      }
      if let size = Self.size(in: operations) {
        // -2 rather than -1 for the side that follows: some encoders refuse an
        // odd number of pixels, and this rounds to an even one.
        arguments += ["-vf", "scale=\(size.width ?? -2):\(size.height ?? -2)"]
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

  private static func size(in operations: [Operation]) -> (width: Int?, height: Int?)? {
    for operation in operations {
      if case .resize(let width, let height, _) = operation, width != nil || height != nil {
        return (width, height)
      }
    }
    return nil
  }

  private static func pandocReads(_ ext: String) -> Bool {
    pandocFormats.read.contains(name(of: ext))
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
    return (list(pandoc, "--list-input-formats"), list(pandoc, "--list-output-formats"))
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
    guard error.localizedDescription.contains("matches no streams") else { return error }
    return ProcessingError.conversionFailed(
      reason: "There are no subtitles in \(input.lastPathComponent)"
    )
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
