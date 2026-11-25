import Foundation
import UniformTypeIdentifiers

/// One kind of archive into another, with the tool macOS has for it. Entries go
/// straight from one to the other: nothing in the archive is ever put on the
/// disk, so nothing in it can be put where it should not be.
final class ArchiveProcessor: FileProcessor, @unchecked Sendable {
  let name = "Archive Processor"

  static let tool = URL(fileURLWithPath: "/usr/bin/tar")

  /// What else the same tool reads.
  static let own: Set<String> = ["iso", "cab", "lzh", "lha", "xar", "pkg", "cpio", "deb", "rpm", "txz", "tbz2", "tbz", "dmg", "apk", "jar", "ipa"]

  static let readable: Set<UTType> = Set((["zip", "7z", "rar", "tar", "tgz", "xz", "bz2"] + own).compactMap { ext in
    UTType(filenameExtension: ext).flatMap { $0.isDynamic ? nil : $0 } ?? UTType(filenameExtension: ext, conformingTo: .archive)
  })

  /// What each is written with.
  private static let writers: [String: [String]] = [
    "zip": ["--format", "zip"], "7z": ["--format", "7zip"], "tar": ["--format", "pax"], "tgz": ["-z", "--format", "pax"],
    "txz": ["-J", "--format", "pax"], "tbz2": ["-j", "--format", "pax"], "cpio": ["--format", "cpio"], "iso": ["--format", "iso9660"],
  ]
  /// A disk is copied as a disk, with whatever is on it.
  private static let disks: [String: String] = ["dmg": "UDZO", "iso": "UDTO"]
  static let writable: [UTType] = (Array(writers.keys) + ["dmg"]).sorted().compactMap { UTType(filenameExtension: $0) }

  static func reads(_ type: UTType) -> Bool { readable.contains(type) }

  func canProcess(_ file: ProcessableFile) -> Bool { Self.reads(file.fileType) }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    let source = file.url.pathExtension.lowercased(), wanted = Conversions.fileExtension(of: target)
    if source == "dmg" || wanted == "dmg" { return source != wanted && Self.disks[source] != nil && Self.disks[wanted] != nil }
    return Self.writable.contains(target) && target != file.fileType
  }

  func process(
    _ input: URL, to output: URL, with operations: [Operation], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    let target = output.pathExtension.lowercased(), source = input.pathExtension.lowercased()
    if source == "dmg" || target == "dmg", Self.disks[source] != nil, let format = Self.disks[target] {
      // It puts its own ending on what it writes.
      let made = output.deletingPathExtension().appendingPathExtension(target == "iso" ? "cdr" : "dmg")
      do { try ExternalTools.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["convert", input.path, "-quiet", "-format", format, "-o", made.path]) } catch is CancellationError { throw CancellationError() } catch {
        throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) cannot be read: it may be damaged, or want a password.")
      }
      if made != output { try FileManager.default.moveItem(at: made, to: output) }
      progress(1)
      let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
      return ProcessingResult(outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start))
    }
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
