import Foundation
import ImageIO
import ModelIO
import SceneKit
import SceneKit.ModelIO
import UniformTypeIdentifiers

/// 3D models, through ModelIO and SceneKit, which are part of macOS, and
/// `Meshes` for what neither of them reads. FBX is nobody's.
final class ModelProcessor: FileProcessor, @unchecked Sendable {
  let name = "Model Processor"

  func canProcess(_ file: ProcessableFile) -> Bool {
    guard let ext = file.url.pathExtension.nilIfEmpty?.lowercased() else { return false }
    return MDLAsset.canImportFileExtension(ext) || Self.own.contains(ext)
  }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    Self.writes(Conversions.fileExtension(of: target)) || (FormatCatalog.isWritableImage(target) && !FormatCatalog.isTexture(target))
  }

  /// SceneKit's, where ModelIO has no reader.
  private static let scenes: Set<String> = ["scn"]
  private static let sceneWritten: Set<String> = ["dae", "scn", "usdz"]
  static let own = Meshes.readable.union(scenes)
  static let written = Meshes.writable.union(sceneWritten)

  private static func writes(_ ext: String) -> Bool { MDLAsset.canExportFileExtension(ext) || written.contains(ext) }

  private let images = ImageProcessor()

  private static func asset(of input: URL) throws -> MDLAsset {
    let ext = input.pathExtension.lowercased()
    if Meshes.readable.contains(ext) { return Meshes.asset(try Meshes.read(input)) }
    guard scenes.contains(ext) else { return MDLAsset(url: input) }
    guard let scene = try? SCNScene(url: input) else { throw Meshes.broken }
    return MDLAsset(scnScene: scene)
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    let picture = UTType(filenameExtension: output.pathExtension).map(FormatCatalog.isWritableImage) ?? false
    guard let outputExtension = output.pathExtension.nilIfEmpty, picture || Self.writes(outputExtension.lowercased()) else {
      let from = UTType(filenameExtension: input.pathExtension) ?? .data
      let to = UTType(filenameExtension: output.pathExtension) ?? .data
      throw ProcessingError.unsupportedConversion(from: from, to: to)
    }

    progress(0.2)
    let asset = try Self.asset(of: input)
    guard asset.count > 0 else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) contains no geometry")
    }

    progress(0.6)
    try Task.checkCancellation()

    if picture {
      let drawn = FileManager.default.temporaryDirectory.appendingPathComponent("forge-model-\(UUID().uuidString).png")
      defer { try? FileManager.default.removeItem(at: drawn) }
      guard let sink = CGImageDestinationCreateWithURL(drawn as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Meshes.broken }
      CGImageDestinationAddImage(sink, try ModelPicture.draw(asset), nil)
      guard CGImageDestinationFinalize(sink) else { throw Meshes.broken }
      return try await images.process(drawn, to: output, with: operations) { progress(0.6 + $0 * 0.4) }
    }

    // Model I/O names what is inside a file after the file: the root of a USD,
    // the material library of an OBJ. Written straight to Forge's scratch
    // name, a model came out with a root called `_forge_` and a string of
    // digits. So it is written under the model's own name, in a folder of its
    // own, and moved into place.
    let stem = input.deletingPathExtension().lastPathComponent
    let workshop = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-model-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workshop, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workshop) }

    let named = workshop.appendingPathComponent("\(stem).\(outputExtension)")
    let wanted = outputExtension.lowercased()
    if MDLAsset.canExportFileExtension(wanted) {
      try asset.export(to: named)
    } else if Meshes.writable.contains(wanted) {
      try Meshes.data(try Meshes.of(asset), as: wanted).write(to: named)
    } else {
      guard SCNScene(mdlAsset: asset).write(to: named, options: nil, delegate: nil, progressHandler: nil) else {
        throw ProcessingError.conversionFailed(reason: "macOS cannot write \(input.lastPathComponent) as \(wanted.uppercased()).")
      }
    }

    let scratch = output.deletingPathExtension().lastPathComponent
    for made in try FileManager.default.contentsOfDirectory(at: workshop, includingPropertiesForKeys: nil) {
      // Companions keep the scratch name, which is how they are found and
      // given the real one when the conversion lands; what names them inside
      // the model is changed to match.
      let landing = made.lastPathComponent == named.lastPathComponent
        ? output
        : output.deletingLastPathComponent().appendingPathComponent("\(scratch).\(made.pathExtension)")
      if let text = try? String(contentsOf: made, encoding: .utf8), text.contains("\(stem).") {
        try text.replacingOccurrences(of: "\(stem).", with: "\(scratch).").write(to: landing, atomically: true, encoding: .utf8)
      } else {
        try? FileManager.default.removeItem(at: landing)
        try FileManager.default.moveItem(at: made, to: landing)
      }
    }
    progress(1.0)

    // Some formats are more than one file: an OBJ keeps its materials in a
    // library beside it, written under the same name. Said out loud here, it
    // is named and moved with the model instead of staying behind as scratch.
    let beside = (try? FileManager.default.contentsOfDirectory(
      at: output.deletingLastPathComponent(), includingPropertiesForKeys: nil
    )) ?? []
    let companions = beside.filter {
      $0.lastPathComponent != output.lastPathComponent && $0.deletingPathExtension().lastPathComponent == scratch
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start),
      additionalOutputs: companions
    )
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
