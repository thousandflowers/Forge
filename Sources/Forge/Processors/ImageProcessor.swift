import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// Image conversion through ImageIO and Core Image.
final class ImageProcessor: FileProcessor, @unchecked Sendable {
  let name = "Image Processor"

  /// Quality used when a preset does not say. Measured rather than picked:
  /// dropping from 85 to 80 takes about a third off the file, and below 80 the
  /// curve flattens - 80 to 70 saves another three per cent.
  static let defaultQuality = 80

  private let ciContext: CIContext

  init() {
    self.ciContext = CIContext(options: [
      .useSoftwareRenderer: false,
      .cacheIntermediates: false
    ])
  }

  func canProcess(_ file: ProcessableFile) -> Bool {
    FormatCatalog.isReadableImage(file.fileType)
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    let inputOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
      kCGImageSourceShouldAllowFloat: true
    ]

    guard let source = CGImageSourceCreateWithURL(input as CFURL, inputOptions as CFDictionary) else {
      throw ProcessingError.conversionFailed(reason: "Cannot read \(input.lastPathComponent)")
    }

    // Every frame, not just the first. An animated GIF used to convert to a
    // single still and a multi-page TIFF lost all but its first page.
    let frames = ImageFrames.read(source, options: inputOptions as CFDictionary)
    guard !frames.isEmpty else {
      throw ProcessingError.conversionFailed(reason: "Cannot decode \(input.lastPathComponent)")
    }

    let outputUTI = determineOutputUTI(from: output, operations: operations)
    let inputType = UTType(filenameExtension: input.pathExtension) ?? .image

    // An image asked for text is a reading job, not a conversion.
    if outputUTI.conforms(to: .plainText) {
      return try Self.recognizeText(
        in: frames[0].image,
        languages: languages(from: operations),
        to: output,
        start: start,
        progress: progress
      )
    }

    // WebP is one macOS reads but cannot write. If this Mac has cwebp, use it
    // rather than refusing a conversion the machine can plainly do. Forge does
    // not ship or download the encoder; it only notices one that is there.
    if Self.isWebP(outputUTI), let cwebp = ExternalTools.locate("cwebp") {
      let image = try transform(frames[0].image, with: operations)
      progress(0.9)
      try Self.writeWebP(image, to: output, using: cwebp, quality: quality(from: operations))
      progress(1.0)

      let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
      return ProcessingResult(
        outputURL: output,
        outputSize: attributes[.size] as? Int64 ?? 0,
        outputDimensions: (image.width, image.height),
        duration: Date().timeIntervalSince(start),
        additionalOutputs: []
      )
    }

    guard FormatCatalog.isWritableImage(outputUTI) || FormatCatalog.isWritableVideo(outputUTI) else {
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputUTI)
    }

    var rendered: [ImageFrame] = []
    rendered.reserveCapacity(frames.count)
    for (index, frame) in frames.enumerated() {
      try Task.checkCancellation()
      rendered.append(ImageFrame(image: try transform(frame.image, with: operations), duration: frame.duration))
      progress(Double(index + 1) / Double(frames.count) * 0.9)
    }

    // An animation asked to become a movie is written as one, which is what
    // turns a GIF back into video.
    var extras: [URL] = []
    // What the encoder was asked for, until a ceiling settles on something else.
    var settled: Float? = isLossy(outputUTI) ? quality(from: operations) : nil
    if FormatCatalog.isWritableVideo(outputUTI) {
      try await MovieWriter.write(rendered, to: output, as: outputUTI) { progress(0.9 + $0 * 0.1) }
    } else {
      let options = destinationOptions(for: outputUTI, operations: operations, source: source)
      extras = try writeFrames(rendered, to: output, as: outputUTI, options: options)

      // A size ceiling is a promise about the result rather than a setting for
      // the encoder, so it is kept the only way a promise about a result can
      // be: write it, measure it, and write it again lower until it fits.
      if let ceiling = Self.sizeCeiling(from: operations) {
        settled = try squeeze(rendered, to: output, as: outputUTI, options: options, ceiling: ceiling)
      }
    }
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: (rendered[0].image.width, rendered[0].image.height),
      duration: Date().timeIntervalSince(start),
      additionalOutputs: extras,
      appliedQuality: settled.map { Int(($0 * 100).rounded()) }
    )
  }

  /// Put the frames where they belong: one file if the format can hold them
  /// all, otherwise one file each, the way PDF pages are handled.
  private func writeFrames(
    _ frames: [ImageFrame],
    to output: URL,
    as type: UTType,
    options: [CFString: Any]
  ) throws -> [URL] {
    // An icon file is expected to carry several resolutions; one picture in an
    // .ico is a picture with an .ico extension.
    if type.conforms(to: .ico), let first = frames.first {
      try ImageFrames.write(
        ImageFrames.iconLadder(from: first.image),
        to: output, as: type, frameOptions: options
      )
      return []
    }

    if frames.count == 1 || FormatCatalog.holdsMultipleFrames(type) {
      try ImageFrames.write(frames, to: output, as: type, frameOptions: options)
      return []
    }

    var extras: [URL] = []
    for (index, frame) in frames.enumerated() {
      let destination = index == 0 ? output : output.numbered(index + 1)
      try ImageFrames.write([frame], to: destination, as: type, frameOptions: options)
      if index > 0 { extras.append(destination) }
    }
    return extras
  }

  /// Apply the preset's operations to one frame and render it.
  private func transform(_ image: CGImage, with operations: [Operation]) throws -> CGImage {
    var ciImage = CIImage(cgImage: image)
    for operation in operations {
      ciImage = try applyOperation(operation, to: ciImage)
    }
    guard let rendered = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
      throw ProcessingError.conversionFailed(reason: "Failed to render frame")
    }
    return rendered
  }

  // MARK: - Text

  static func recognizeText(
    in image: CGImage,
    languages: [String],
    to output: URL,
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) throws -> ProcessingResult {
    progress(0.3)
    let text = try TextRecognizer.text(in: image, languages: languages)
    progress(0.9)
    try text.write(to: output, atomically: true, encoding: .utf8)
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  private func languages(from operations: [Operation]) -> [String] {
    operations.compactMap { operation -> [String]? in
      guard case .recognizeText(let languages) = operation else { return nil }
      return languages
    }.first ?? []
  }

  // MARK: - Output

  private func determineOutputUTI(from outputURL: URL, operations: [Operation]) -> UTType {
    let requested = operations.compactMap { operation -> UTType? in
      guard case .convertFormat(let to) = operation else { return nil }
      return to
    }.first
    return requested ?? UTType(filenameExtension: outputURL.pathExtension) ?? .jpeg
  }

  /// Carry the source's metadata across, and add the encoder settings the
  /// requested operations imply. Conversions used to drop EXIF, GPS and
  /// orientation on every single image.
  private func destinationOptions(
    for uti: UTType,
    operations: [Operation],
    source: CGImageSource
  ) -> [CFString: Any] {
    var options: [CFString: Any] = [:]

    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
      // The pixel dimensions belong to the source; a resize makes them wrong,
      // and ImageIO fills in the real ones anyway.
      options = properties
      options.removeValue(forKey: kCGImagePropertyPixelWidth)
      options.removeValue(forKey: kCGImagePropertyPixelHeight)
    }

    if isLossy(uti) {
      options[kCGImageDestinationLossyCompressionQuality] = quality(from: operations)
    }
    return options
  }

  static func isWebP(_ uti: UTType) -> Bool {
    guard let webp = UTType("org.webmproject.webp") else { return false }
    return uti.conforms(to: webp)
  }

  /// Hand the image to cwebp as a lossless PNG, so the only lossy step is the
  /// one that was asked for.
  private static func writeWebP(_ image: CGImage, to output: URL, using cwebp: URL, quality: Float) throws {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("forge-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: scratch) }

    guard let destination = CGImageDestinationCreateWithURL(
      scratch as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
      throw ProcessingError.conversionFailed(reason: "Cannot stage the image for cwebp")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ProcessingError.conversionFailed(reason: "Cannot stage the image for cwebp")
    }

    try ExternalTools.run(cwebp, [
      "-quiet",
      "-q", String(Int((quality * 100).rounded())),
      scratch.path,
      "-o", output.path,
    ])
  }

  static func sizeCeiling(from operations: [Operation]) -> Int? {
    operations.compactMap { if case .limitSize(let bytes) = $0 { return bytes } else { return nil } }
      .filter { $0 > 0 }
      .min()
  }

  /// Write the image again, smaller, until it is under the ceiling.
  ///
  /// Quality goes first because it costs the least visibly; once there is no
  /// quality left to give, the pixels go. Both have a floor: past it the file
  /// is not the file anybody asked for, and saying so beats handing back
  /// something unrecognisable that happens to be small.
  /// - Returns: the quality it settled on, which is what the ceiling cost.
  @discardableResult
  private func squeeze(
    _ frames: [ImageFrame],
    to output: URL,
    as uti: UTType,
    options: [CFString: Any],
    ceiling: Int
  ) throws -> Float {
    let lowestQuality: Float = 0.2
    let smallestScale: CGFloat = 0.15
    let attemptsAllowed = 12

    var quality = (options[kCGImageDestinationLossyCompressionQuality] as? Float) ?? 0.8
    var scale: CGFloat = 1
    var current = frames
    var attempts = 0

    while try Self.fileSize(of: output) > ceiling {
      try Task.checkCancellation()
      attempts += 1
      guard attempts <= attemptsAllowed else { break }

      var next = options
      if isLossy(uti), quality > lowestQuality {
        quality = max(lowestQuality, quality - 0.12)
        next[kCGImageDestinationLossyCompressionQuality] = quality
      } else {
        scale *= 0.82
        guard scale >= smallestScale else { break }
        let width = max(16, Int(CGFloat(frames[0].image.width) * scale))
        current = try frames.map { frame in
          ImageFrame(
            image: try transform(frame.image, with: [.resize(width: width, height: nil, fitMode: .proportional)]),
            duration: frame.duration
          )
        }
        if isLossy(uti) { next[kCGImageDestinationLossyCompressionQuality] = quality }
      }

      _ = try writeFrames(current, to: output, as: uti, options: next)
    }

    let finalSize = try Self.fileSize(of: output)
    guard finalSize <= ceiling else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot get \(output.lastPathComponent) under "
          + "\(Int64(ceiling).formatted(.byteCount(style: .file))); the smallest it goes is "
          + "\(Int64(finalSize).formatted(.byteCount(style: .file)))."
      )
    }
    return quality
  }

  private static func fileSize(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
  }

  /// Quality only means something for formats that throw information away.
  private func isLossy(_ uti: UTType) -> Bool {
    [UTType.jpeg, .heic, UTType("public.avif"), UTType("public.jpeg-2000")]
      .compactMap { $0 }
      .contains { uti.conforms(to: $0) }
  }

  private func quality(from operations: [Operation]) -> Float {
    let level = operations.compactMap { operation -> Int? in
      guard case .quality(let level) = operation else { return nil }
      return level
    }.first
    return Float(level ?? Self.defaultQuality) / 100.0
  }

  // MARK: - Operations

  private func applyOperation(_ operation: Operation, to image: CIImage) throws -> CIImage {
    switch operation {
    case .convertFormat, .quality, .recognizeText, .encode, .limitSize:
      return image // settled when the file is written
    case .resize(let width, let height, let mode):
      return applyResize(image, targetWidth: width, targetHeight: height, mode: mode)
    case .filter(let type):
      return applyFilter(image, type: type)
    }
  }

  private func applyResize(
    _ image: CIImage,
    targetWidth: Int?,
    targetHeight: Int?,
    mode: ResizeFitMode
  ) -> CIImage {
    let original = image.extent.size
    let targetW = CGFloat(targetWidth ?? Int(original.width))
    let targetH = CGFloat(targetHeight ?? Int(original.height))
    guard targetW > 0, targetH > 0, original.width > 0, original.height > 0 else { return image }

    switch mode {
    case .proportional:
      let scale = min(targetW / original.width, targetH / original.height)
      return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    case .stretch:
      return image.transformed(by: CGAffineTransform(
        scaleX: targetW / original.width,
        y: targetH / original.height
      ))

    case .cropCenter:
      let scale = max(targetW / original.width, targetH / original.height)
      let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let crop = CGRect(
        x: scaled.extent.origin.x + (scaled.extent.width - targetW) / 2,
        y: scaled.extent.origin.y + (scaled.extent.height - targetH) / 2,
        width: targetW,
        height: targetH
      )
      return scaled.cropped(to: crop).transformed(
        by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y)
      )

    case .pad:
      let scale = min(targetW / original.width, targetH / original.height)
      let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let canvas = CGRect(x: 0, y: 0, width: targetW, height: targetH)
      let centred = scaled.transformed(by: CGAffineTransform(
        translationX: (targetW - scaled.extent.width) / 2 - scaled.extent.origin.x,
        y: (targetH - scaled.extent.height) / 2 - scaled.extent.origin.y
      ))
      // The image goes over the backdrop, not under it. Reversed, the padding
      // covered the picture and the result was the wrong size as well.
      let backdrop = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: canvas)
      return centred.composited(over: backdrop).cropped(to: canvas)
    }
  }

  private func applyFilter(_ image: CIImage, type: FilterType) -> CIImage {
    switch type {
    case .grayscale:
      return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    case .sepia:
      return image.applyingFilter("CISepiaTone", parameters: [:])
    case .blur:
      return image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10.0])
        .cropped(to: image.extent)
    case .sharpen:
      return image.applyingFilter("CISharpenLuminance", parameters: [:])
    case .invert:
      return image.applyingFilter("CIColorInvert", parameters: [:])
    }
  }
}
