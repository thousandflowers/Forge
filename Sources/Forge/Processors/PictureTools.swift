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
    case .adjust(let what, let much): return adjusted(image, what, Double(much) / 100)
    case .border(let width, let isBlack):
      let side = CGFloat(width)
      let backdrop = CIImage(color: isBlack ? .black : .white).cropped(to: image.extent.insetBy(dx: -side, dy: -side))
      return atTheCorner(image.composited(over: backdrop))
    case .mark(let text): return try marked(image, text)
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

  private static func adjusted(_ image: CIImage, _ what: Tool.Adjustment, _ share: Double) -> CIImage {
    switch what {
    case .blur:
      return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: share * 100]).cropped(to: image.extent)
    case .brightness:
      // A stop at either end: added to, black would go grey.
      return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: share * 2])
    case .contrast: return image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + share * 0.5])
    case .saturation: return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + share])
    }
  }

  /// Words in the bottom right, to be read on light and on dark.
  private static func marked(_ image: CIImage, _ text: String) throws -> CIImage {
    let height = max(10, min(image.extent.width, image.extent.height) * 0.04)
    guard let filter = CIFilter(name: "CITextImageGenerator", parameters: [
      "inputText": text, "inputFontName": "HelveticaNeue-Medium", "inputFontSize": height, "inputScaleFactor": 1,
    ]), let letters = filter.outputImage, letters.extent.width > 0 else {
      throw ProcessingError.conversionFailed(reason: "“\(text)” cannot be written on a picture.")
    }
    // As a mask: what it draws is white on nothing on one Mac and black on another.
    func coloured(_ colour: CIColor) -> CIImage {
      CIImage(color: colour).cropped(to: letters.extent).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: letters])
    }
    let gap = height * 0.8
    let place = CGAffineTransform(
      translationX: image.extent.maxX - letters.extent.maxX - gap, y: image.extent.minY - letters.extent.minY + gap
    )
    let shadow = coloured(CIColor(red: 0, green: 0, blue: 0, alpha: 0.7)).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: height * 0.08])
    return coloured(CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)).transformed(by: place)
      .composited(over: shadow.transformed(by: place).composited(over: image)).cropped(to: image.extent)
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
