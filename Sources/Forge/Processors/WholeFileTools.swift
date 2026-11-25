import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What is made of a file as a whole, whoever would otherwise convert it.
enum WholeFileTools {
  /// Nil where nothing of the kind is asked.
  static func attempt(
    _ operations: [Operation], on input: URL, of type: UTType, to output: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult? {
    for tool in operations.tools {
      switch tool {
      case .digest(let digest): return try DigestProcessor.write(digest, of: input, to: output, progress: progress)
      case .tidy(let tidying):
        guard let language = Tidier.language(of: type), output.pathExtension.lowercased() == input.pathExtension.lowercased() else {
          throw ProcessingError.conversionFailed(reason: "“\(tool.title)” keeps a file in the format it is in.")
        }
        return try Tidier.write(tidying, of: input, as: language, to: output)
      case .tables: return try await TableReader.write(from: input, to: output, progress: progress)
      case .pictures: return try PDFPictures.write(from: input, to: output, progress: progress)
      case .layers: return try await layers(operations, of: input, to: output, progress: progress)
      default: continue
      }
    }
    return nil
  }

  /// Each is a picture like any other, and whatever else is asked is done to it.
  private static func layers(
    _ operations: [Operation], of input: URL, to output: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    let layers = try PSDLayers.read(input)
    let rest = operations.filter { $0 != .tool(.layers) }
    let images = ImageProcessor()
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("forge-layers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    var first: ProcessingResult?, extras: [URL] = []
    for (index, layer) in layers.enumerated() {
      try Task.checkCancellation()
      let drawn = scratch.appendingPathComponent("\(index).png")
      guard let destination = CGImageDestinationCreateWithURL(drawn as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ProcessingError.conversionFailed(reason: "A layer could not be written")
      }
      CGImageDestinationAddImage(destination, layer.image, nil)
      guard CGImageDestinationFinalize(destination) else { throw ProcessingError.conversionFailed(reason: "A layer could not be written") }
      let place = index == 0 ? output : named(output.numbered(index + 1, of: layers.count), layer.name)
      let result = try await images.process(drawn, to: place, with: rest) { _ in }
      if index == 0 { first = result } else { extras.append(place) }
      progress(Double(index + 1) / Double(layers.count))
    }
    guard let first else { throw ProcessingError.conversionFailed(reason: "There are no layers in this file.") }
    return ProcessingResult(
      outputURL: output, outputSize: first.outputSize, outputDimensions: first.outputDimensions, duration: Date().timeIntervalSince(start), additionalOutputs: extras
    )
  }

  /// By what it is called, as much of that as a name can hold.
  private static func named(_ url: URL, _ name: String) -> URL {
    let tidy = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.controlCharacters))
    guard !tidy.isEmpty else { return url }
    let stem = url.deletingPathExtension().lastPathComponent
    return url.deletingLastPathComponent().appendingPathComponent("\(stem) \(tidy).\(url.pathExtension)")
  }
}
