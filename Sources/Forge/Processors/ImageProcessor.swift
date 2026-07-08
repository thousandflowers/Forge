import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// Native image processor using Core Image / ImageIO
final class ImageProcessor: FileProcessor, @unchecked Sendable {
  let name = "Image Processor"
  let isNative = true
  let supportedTypes: [UTType] = {
    var types: [UTType] = []
    let extensions = ["png", "jpeg", "jpg", "tiff", "heic", "webp", "gif", "bmp", "tga", "ico"]
    for ext in extensions {
      if let type = UTType(filenameExtension: ext) {
        types.append(type)
      }
    }
    return types
  }()

  private let ciContext: CIContext

  init() {
    // Use GPU-backed CIContext for performance
    self.ciContext = CIContext(options: [
      .useSoftwareRenderer: false,
      .cacheIntermediates: false
    ])
  }

  func canProcess(_ file: ProcessableFile) -> Bool {
    supportedTypes.contains { file.fileType.conforms(to: $0) }
  }

  func supportedOutputTypes(for input: UTType) -> [UTType] {
    // All common image formats are supported as output
    var types: [UTType] = []
    [ "jpeg", "png", "tiff", "heic", "webp", "bmp", "gif" ].forEach { ext in
      if let type = UTType(filenameExtension: ext) {
        types.append(type)
      }
    }
    return types
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()

    // Validate operations early
    try validateOperations(operations, for: try Self.determineInputType(input))

    // Step 1: Load image source without full caching
    let inputOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
      kCGImageSourceShouldAllowFloat: true
    ]

    guard let source = CGImageSourceCreateWithURL(input as CFURL, inputOptions as CFDictionary) else {
      throw ProcessingError.conversionFailed(reason: "Cannot create image source from \(input.lastPathComponent)")
    }

    // Get image properties (optional for some formats)
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, inputOptions as CFDictionary) else {
      throw ProcessingError.conversionFailed(reason: "Cannot decode image")
    }

    var ciImage = CIImage(cgImage: cgImage)

    // Step 2: Apply operations (transformations)
    let filteredOps = filterSupportedOperations(operations, for: try Self.determineInputType(input))

    for (index, op) in filteredOps.enumerated() {
      let opProgress = Double(index) / Double(max(1, filteredOps.count))
      progress(opProgress * 0.7) // 70% of progress before final write

      ciImage = try applyOperation(op, to: ciImage, originalSize: ciImage.extent.size)
    }

    progress(0.7)

    // Step 3: Render and write output
    let outputUTI = determineOutputUTI(from: output, operations: operations)
    let outputType = outputUTI.identifier as CFString

    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, outputType, 1, nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot create destination for \(outputUTI)")
    }

    // Render CIImage to CGImage
    guard let rendered = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
      throw ProcessingError.conversionFailed(reason: "Failed to render image")
    }

    // Set format-specific options
    let options = buildDestinationOptions(for: outputUTI, operations: operations)
    CGImageDestinationAddImage(destination, rendered, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ProcessingError.conversionFailed(reason: "Failed to write image to disk")
    }

    progress(1.0)

    // Step 4: Gather result metadata
    let outputSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64 ?? 0
    let outputDims = (rendered.width, rendered.height)
    let duration = Date().timeIntervalSince(start)

    return ProcessingResult(
      outputURL: output,
      outputSize: outputSize,
      outputDimensions: outputDims,
      duration: duration
    )
  }

  // MARK: - Helpers

  private static func determineInputType(_ url: URL) throws -> UTType {
    guard let type = UTType(filenameExtension: url.pathExtension) else {
      throw ProcessingError.unknownType
    }
    return type
  }

  private func determineOutputUTI(from outputURL: URL, operations: [Operation]) -> UTType {
    // Priority 1: explicit convertFormat operation
    if let convertOp = operations.first(where: {
      if case .convertFormat = $0 { return true } else { return false }
    }) {
      if case .convertFormat(let to) = convertOp {
        return to
      }
    }

    // Priority 2: use URL extension
    if let type = UTType(filenameExtension: outputURL.pathExtension) {
      return type
    }

    // Default to JPEG using known identifier
    return UTType(filenameExtension: "jpeg") ?? UTType("public.jpeg") ?? .png
  }

  private func buildDestinationOptions(for uti: UTType, operations: [Operation]) -> [CFString: Any] {
    var options: [CFString: Any] = [:]

    // JPEG quality
    if uti.conforms(to: .jpeg) {
      let quality = extractQuality(from: operations)
      options[kCGImageDestinationLossyCompressionQuality] = quality
    }

    // WebP quality (if supported)
    if let webpType = UTType(filenameExtension: "webp"), uti.conforms(to: webpType) {
      let quality = extractQuality(from: operations)
      options[kCGImageDestinationLossyCompressionQuality] = quality
    }

    // TIFF compression - note: constant may not be available on all platforms
    // Uncomment if kCGImageDestinationTIFFCompression is available
    // if uti.conforms(to: .tiff) {
    //   options[kCGImageDestinationTIFFCompression] = 5 // LZW
    // }

    return options
  }

  private func extractQuality(from operations: [Operation]) -> Float {
    var quality: Float = 0.85 // Default 85%
    for op in operations {
      if case .quality(let level) = op {
        quality = Float(level) / 100.0
        break
      }
    }
    return quality
  }

  private func applyOperation(_ op: Operation, to image: CIImage, originalSize: CGSize) throws -> CIImage {
    switch op {
    case .convertFormat:
      return image // handled at output

    case .resize(let width, let height, let mode):
      return try applyResize(image, to: width, targetHeight: height, mode: mode)

    case .quality:
      return image // handled at output

    case .compress:
      // For MVP, compress is just quality actually. Later we implement iterative size adjustment.
      return image

    case .filter(let type):
      return applyFilter(image, type: type)

    case .rename:
      return image // naming handled elsewhere
    }
  }

  private func applyResize(_ image: CIImage, to targetWidth: Int?, targetHeight: Int?, mode: ResizeFitMode) throws -> CIImage {
    let originalSize = image.extent.size
    let targetW = targetWidth ?? Int(originalSize.width)
    let targetH = targetHeight ?? Int(originalSize.height)

    guard targetW > 0 && targetH > 0 else { return image }

    let targetSize = CGSize(width: targetW, height: targetH)

    switch mode {
    case .proportional:
      let scale = min(CGFloat(targetW) / originalSize.width, CGFloat(targetH) / originalSize.height)
      let newSize = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)
      return image.transformed(by: CGAffineTransform(scaleX: newSize.width / originalSize.width, y: newSize.height / originalSize.height))

    case .cropCenter:
      let scale = max(CGFloat(targetW) / originalSize.width, CGFloat(targetH) / originalSize.height)
      let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let cropRect = CGRect(
        x: (scaled.extent.width - CGFloat(targetW)) / 2,
        y: (scaled.extent.height - CGFloat(targetH)) / 2,
        width: CGFloat(targetW),
        height: CGFloat(targetH)
      )
      return scaled.cropped(to: cropRect)

    case .stretch:
      let scaleX = CGFloat(targetW) / originalSize.width
      let scaleY = CGFloat(targetH) / originalSize.height
      return image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

    case .pad:
      let scale = min(CGFloat(targetW) / originalSize.width, CGFloat(targetH) / originalSize.height)
      let newSize = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)
      let scaled = image.transformed(by: CGAffineTransform(scaleX: newSize.width / originalSize.width, y: newSize.height / originalSize.height))

      // Create padded canvas
      let padded = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: targetSize))
      let offsetX = (targetSize.width - scaled.extent.width) / 2
      let offsetY = (targetSize.height - scaled.extent.height) / 2
      return padded.composited(over: scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY)))
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
    case .sharpen:
      return image.applyingFilter("CISharpenLuminance", parameters: [:])
    case .invert:
      return image.applyingFilter("CIColorInvert", parameters: [:])
    }
  }
}
