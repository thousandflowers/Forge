import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file made lighter without anybody saying how, and left alone when it
/// cannot be.
///
/// Trying is the only way to know: a noisy film asked for in AV1 came out
/// heavier than it went in. So it is written to scratch, weighed, and handed
/// over only if it is worth having.
enum Lighter {
  /// Less than this and what is given up is not worth what is saved.
  private static let smallestSaving = 0.05

  static func isWorthIt(from before: Int64, to after: Int64) -> Bool {
    after > 0 && before > 0 && Double(before - after) / Double(before) >= smallestSaving
  }

  /// The lighter copy, or nil when there is none worth having.
  static func run(_ file: ProcessableFile, coordinator: ProcessingCoordinator, into folder: URL) async throws -> ProcessingResult? {
    guard let preset = preset(for: file) else { return nil }
    let fileManager = FileManager.default
    let scratch = fileManager.temporaryDirectory.appendingPathComponent("ForgeLighter-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: scratch) }

    let made = try await coordinator.preview(file, with: preset, into: scratch)
    guard isWorthIt(from: file.fileSize, to: made.outputSize) else { return nil }

    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let kept = folder.appendingPathComponent("\(UUID().uuidString).\(made.outputURL.pathExtension)")
    try fileManager.moveItem(at: made.outputURL, to: kept)
    return ProcessingResult(
      outputURL: kept, outputSize: made.outputSize, outputDimensions: made.outputDimensions, duration: made.duration
    )
  }

  /// One picture with nothing see-through in it. Written as a photograph, an
  /// animation is its first frame and a cut-out has a box around it.
  private static func losesNothingAsAPhotograph(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
    return (properties[kCGImagePropertyHasAlpha] as? Bool) != true
  }

  /// What to try, by kind. Nil for what nothing here makes lighter.
  static func preset(for file: ProcessableFile) -> RulePreset? {
    let actions: [Operation]
    switch ConvertKind(fileType: file.fileType) {
    case .image:
      guard losesNothingAsAPhotograph(file.url) else { return nil }
      actions = [.convertFormat(to: file.fileType == .heic ? .heic : .jpeg), .quality(level: 78)]
    case .video: actions = [.convertFormat(to: .mpeg4Movie), .encode(codec: .hevc)]
    case .audio: actions = [.convertFormat(to: UTType("com.apple.m4a-audio") ?? .mpeg4Audio)]
    default: return nil
    }
    return RulePreset(name: "Lighter", description: "", category: .custom, actions: actions)
  }
}
