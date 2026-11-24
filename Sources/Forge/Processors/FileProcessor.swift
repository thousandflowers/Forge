import Foundation
import UniformTypeIdentifiers

/// Result of processing a file
struct ProcessingResult: Sendable {
  let outputURL: URL
  let outputSize: Int64
  let outputDimensions: (width: Int, height: Int)?
  let duration: TimeInterval
  /// Extra files the conversion produced, in order. One input can legitimately
  /// yield many outputs: a twenty-page PDF becomes twenty images.
  let additionalOutputs: [URL]
  /// The quality the encoder settled on, where that was a result rather than a
  /// setting. A size ceiling is kept by writing the file again lower until it
  /// fits, so the number that got there is only known afterwards - and it is
  /// the interesting half of "10 MB, and what did that cost".
  let appliedQuality: Int?
  /// Where the original was copied before it was replaced.
  let backupURL: URL?

  init(
    outputURL: URL,
    outputSize: Int64,
    outputDimensions: (width: Int, height: Int)?,
    duration: TimeInterval,
    additionalOutputs: [URL] = [],
    appliedQuality: Int? = nil,
    backupURL: URL? = nil
  ) {
    self.outputURL = outputURL
    self.outputSize = outputSize
    self.outputDimensions = outputDimensions
    self.duration = duration
    self.additionalOutputs = additionalOutputs
    self.appliedQuality = appliedQuality
    self.backupURL = backupURL
  }
}

/// Protocol for file processors
protocol FileProcessor: AnyObject, Sendable {
  var name: String { get }

  func canProcess(_ file: ProcessableFile) -> Bool

  /// Whether this processor would take the file to that format, judged by the
  /// two formats alone. It is what `process` decides before it starts, asked
  /// ahead of time, so that the sheet offers only what will be attempted.
  /// What is inside a file can still stop a conversion - a film with no
  /// subtitle track has none to give - and that is said when it happens.
  func takes(_ file: ProcessableFile, to target: UTType) -> Bool

  /// Process the input file and write to output location.
  /// - Parameters:
  ///   - input: Source file URL
  ///   - output: Destination file URL (should not exist)
  ///   - operations: List of operations to apply (filtered to supported ones)
  ///   - progress: Closure called with progress 0.0...1.0
  /// - Returns: ProcessingResult with metadata
  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult
}

/// Every processor, in the order they are asked. A processor that reads a file
/// and turns the pair down hands it to the next one that reads it, so whether a
/// file can become something is whether any of them takes it there.
enum Conversions {
  static let processors: [FileProcessor] = [
    // Before the image processor, which would claim an SVG through
    // `readableImageTypes` and then hand ImageIO a file it cannot decode.
    VectorProcessor(),
    ImageProcessor(),
    // Before the media path: AVFoundation lists WebVTT among the types it
    // opens, and then finds no tracks in one, so a subtitle handed to it fails
    // with "contains no audio or video tracks" rather than being converted.
    SubtitleProcessor(),
    MediaProcessor(),
    // Before the document reader: JSON and CSV are plain text as far as the
    // system is concerned, and the document reader would take them.
    DataProcessor(),
    SimpleDocProcessor(),
    ModelProcessor(),
    ArchiveProcessor(),
    // Last: a conversion macOS can do itself is still done by macOS, and a
    // tool the user installed is only asked about what is left over.
    ExternalProcessor(),
  ]

  static func can(_ file: ProcessableFile, become target: UTType) -> Bool {
    processors.contains { $0.canProcess(file) && $0.takes(file, to: target) }
  }

  /// The extension a format is written under, which is how the processors
  /// that work by name know it.
  static func fileExtension(of type: UTType) -> String {
    (FormatCatalog.fileExtension(for: type) ?? type.preferredFilenameExtension ?? "").lowercased()
  }
}

extension URL {
  /// `photo.jpg` becomes `photo-002.jpg`. Used wherever one input yields many
  /// outputs - PDF pages, and the frames of an animation.
  ///
  /// - Parameter total: how many there will be, where that is known, so that
  ///   the thousandth sorts after the nine hundred and ninety-ninth rather than
  ///   between the hundredth and the hundred-and-first.
  func numbered(_ index: Int, of total: Int = 0) -> URL {
    let base = deletingPathExtension().lastPathComponent
    let ext = pathExtension
    let digits = max(3, String(total).count)
    let name = "\(base)-" + String(repeating: "0", count: max(0, digits - String(index).count)) + "\(index)"
    return deletingLastPathComponent()
      .appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
  }
}
