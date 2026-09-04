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
    return ExternalTools.locate("ffmpeg") != nil
      && (type.conforms(to: .audiovisualContent) || type.conforms(to: .audio))
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
    let wantsSomethingStill = targetType.map {
      $0.conforms(to: .image) || $0.conforms(to: .text) || $0.conforms(to: .pdf)
    } ?? false

    if !wantsSomethingStill, let ffmpeg = ExternalTools.locate("ffmpeg") {
      var arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path]
      if let size = Self.size(in: operations) {
        // -2 rather than -1 for the side that follows: some encoders refuse an
        // odd number of pixels, and this rounds to an even one.
        arguments += ["-vf", "scale=\(size.width ?? -2):\(size.height ?? -2)"]
      }
      arguments.append(output.path)
      return Plan(tool: ffmpeg, toolName: "ffmpeg", arguments: arguments)
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
    try ExternalTools.run(plan.tool, plan.arguments)
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
}
