import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// Image conversion through ImageIO and Core Image.
final class ImageProcessor: FileProcessor, @unchecked Sendable {
  let name = "Image Processor"

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
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, inputOptions as CFDictionary) else {
      throw ProcessingError.conversionFailed(reason: "Cannot decode \(input.lastPathComponent)")
    }

    var ciImage = CIImage(cgImage: cgImage)

    for (index, operation) in operations.enumerated() {
      try Task.checkCancellation()
      progress(Double(index) / Double(max(1, operations.count)) * 0.7)
      ciImage = try applyOperation(operation, to: ciImage)
    }
    progress(0.7)

    let outputUTI = determineOutputUTI(from: output, operations: operations)
    guard FormatCatalog.isWritableImage(outputUTI) else {
      let inputType = UTType(filenameExtension: input.pathExtension) ?? .image
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputUTI)
    }

    guard let destination = CGImageDestinationCreateWithURL(
      output as CFURL,
      outputUTI.identifier as CFString,
      1,
      nil
    ) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot write \(outputUTI.preferredFilenameExtension ?? outputUTI.identifier)"
      )
    }

    guard let rendered = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
      throw ProcessingError.conversionFailed(reason: "Failed to render \(input.lastPathComponent)")
    }

    try Task.checkCancellation()

    let options = destinationOptions(for: outputUTI, operations: operations, source: source)
    CGImageDestinationAddImage(destination, rendered, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ProcessingError.conversionFailed(reason: "Failed to write \(output.lastPathComponent)")
    }

    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: (rendered.width, rendered.height),
      duration: Date().timeIntervalSince(start)
    )
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
    return Float(level ?? 85) / 100.0
  }

  // MARK: - Operations

  private func applyOperation(_ operation: Operation, to image: CIImage) throws -> CIImage {
    switch operation {
    case .convertFormat, .quality:
      return image // both are settled when the file is encoded
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
