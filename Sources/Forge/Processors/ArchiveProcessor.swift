import Foundation
import UniformTypeIdentifiers

/// One kind of archive into another, with the tool macOS has for it. Entries go
/// straight from one to the other: nothing in the archive is ever put on the
/// disk, so nothing in it can be put where it should not be.
final class ArchiveProcessor: FileProcessor, @unchecked Sendable {
  let name = "Archive Processor"

  static let tool = URL(fileURLWithPath: "/usr/bin/tar")

  static let readable: Set<UTType> = Set(["zip", "7z", "rar", "tar", "tgz", "xz", "bz2"].compactMap { UTType(filenameExtension: $0) })

  /// What each is written with.
  private static let writers: [String: [String]] = [
    "zip": ["--format", "zip"], "7z": ["--format", "7zip"], "tar": ["--format", "pax"], "tgz": ["-z", "--format", "pax"],
  ]
  static let writable: [UTType] = writers.keys.sorted().compactMap { UTType(filenameExtension: $0) }

  static func reads(_ type: UTType) -> Bool { readable.contains(type) }

  func canProcess(_ file: ProcessableFile) -> Bool { Self.reads(file.fileType) }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool { Self.writable.contains(target) && target != file.fileType }

  func process(
    _ input: URL, to output: URL, with operations: [Operation], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    let target = output.pathExtension.lowercased()
    guard let writer = Self.writers[target] else {
      throw ProcessingError.unsupportedConversion(
        from: UTType(filenameExtension: input.pathExtension) ?? .archive, to: UTType(filenameExtension: target) ?? .data
      )
    }
    progress(0.1)
    do {
      try ExternalTools.run(Self.tool, ["-c"] + writer + ["-f", output.path, "@" + input.path])
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ProcessingError.conversionFailed(
        reason: "\(input.lastPathComponent) cannot be read: it may be damaged, or want a password."
      )
    }
    progress(1)
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    return ProcessingResult(outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start))
  }
}
