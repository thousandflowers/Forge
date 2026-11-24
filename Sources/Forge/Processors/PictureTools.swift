import CoreImage
import Foundation
import Vision

/// What a tool does to one picture.
enum PictureTools {
  static func apply(_ tool: Tool, to image: CIImage) throws -> CIImage {
    switch tool {
    case .turn(let turn): return atTheCorner(image.oriented(turn.orientation))
    case .crop(let crop):
      let size = image.extent.size
      var focus: CGPoint?
      if case .shape = crop { focus = subject(of: image) }
      let box = try crop.box(in: size, around: focus)
      // Boxes are counted from the top and Core Image from the bottom.
      return atTheCorner(image.cropped(to: CGRect(
        x: image.extent.minX + box.minX, y: image.extent.maxY - box.maxY, width: box.width, height: box.height
      )))
    case .removeBackground: return try cutOut(image)
    default: return image
    }
  }

  /// On white, for a format with nothing to see through.
  static func onWhite(_ image: CIImage) -> CIImage {
    image.composited(over: CIImage(color: .white).cropped(to: image.extent))
  }

  private static func atTheCorner(_ image: CIImage) -> CIImage {
    image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
  }

  /// Faces, or else whatever the eye goes to, from the top left. Nil where
  /// nothing stands out, which leaves the middle.
  static func subject(of image: CIImage) -> CGPoint? {
    let faces = VNDetectFaceRectanglesRequest()
    let attention = VNGenerateAttentionBasedSaliencyImageRequest()
    let handler = VNImageRequestHandler(ciImage: image)
    try? handler.perform([faces, attention])
    let found = faces.results?.map(\.boundingBox) ?? []
    let boxes = found.isEmpty ? attention.results?.first?.salientObjects?.map(\.boundingBox) ?? [] : found
    guard let first = boxes.first else { return nil }
    let all = boxes.dropFirst().reduce(first) { $0.union($1) }
    return CGPoint(x: all.midX * image.extent.width, y: (1 - all.midY) * image.extent.height)
  }

  private static func cutOut(_ image: CIImage) throws -> CIImage {
    let handler = VNImageRequestHandler(ciImage: image)
    let mask: CVPixelBuffer?
    if #available(macOS 14, *) {
      let request = VNGenerateForegroundInstanceMaskRequest()
      try handler.perform([request])
      mask = try request.results?.first.map { try $0.generateScaledMaskForImage(forInstances: $0.allInstances, from: handler) }
    } else {
      // People are all that macOS 13 tells from what is behind them.
      let request = VNGeneratePersonSegmentationRequest()
      request.qualityLevel = .accurate
      try handler.perform([request])
      mask = request.results?.first?.pixelBuffer
    }
    guard let mask else {
      throw ProcessingError.conversionFailed(reason: "Nothing in the picture stands out from its background.")
    }
    let cover = CIImage(cvPixelBuffer: mask)
    let fitted = atTheCorner(cover).transformed(by: CGAffineTransform(
      scaleX: image.extent.width / cover.extent.width, y: image.extent.height / cover.extent.height
    ))
    return image.applyingFilter("CIBlendWithMask", parameters: [
      kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: fitted,
    ]).cropped(to: image.extent)
  }
}

private extension Tool.Turn {
  var orientation: CGImagePropertyOrientation {
    switch self {
    case .right: return .right
    case .left: return .left
    case .half: return .down
    case .mirror: return .upMirrored
    case .flip: return .downMirrored
    }
  }
}
