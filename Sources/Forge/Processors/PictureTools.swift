import CoreImage
import Foundation
import Vision

/// What a tool does to one picture.
enum PictureTools {
  /// - Parameter isAlone: not one of many. Followed picture by picture, what an
  ///   animation is of stands still and everything else jumps.
  static func apply(_ tool: Tool, to image: CIImage, isAlone: Bool = true) throws -> CIImage {
    switch tool {
    case .turn(let turn): return atTheCorner(image.oriented(turn.orientation))
    case .crop(let crop):
      let size = image.extent.size
      var focus: CGPoint?
      if case .shape = crop, isAlone { focus = subject(of: image) }
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
    case .enhance: return enhanced(image)
    case .gray: return gray(image)
    case .blurBackground: return try blurredBehind(image)
    case .round(let radius): return rounded(image, CGFloat(radius))
    case .scan: return try scanned(image)
    case .upscale(let times): return try enlarged(image, by: times)
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

  /// The colours given the light each of them has.
  static func gray(_ image: CIImage) -> CIImage {
    image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
  }

  private static func enhanced(_ image: CIImage) -> CIImage {
    var better = image
    for filter in image.autoAdjustmentFilters(options: [.redEye: false, .crop: false, .level: false]) {
      filter.setValue(better, forKey: kCIInputImageKey)
      if let made = filter.outputImage { better = made }
    }
    return better.cropped(to: image.extent)
  }

  /// On a side. Larger and nothing opens it.
  private static let largest = 20_000.0

  /// By arithmetic. macOS has a network for it, made for video calls: tried on a
  /// picture made half as large and back, it was 21 dB further from what it had been.
  private static func enlarged(_ image: CIImage, by times: Int) throws -> CIImage {
    let target = CGRect(x: 0, y: 0, width: image.extent.width * CGFloat(times), height: image.extent.height * CGFloat(times))
    guard max(target.width, target.height) <= largest else {
      throw ProcessingError.conversionFailed(
        reason: "\(times) times as large, it would be \(Int(target.width)) × \(Int(target.height)): the most is \(Int(largest)) on a side."
      )
    }
    return image.clampedToExtent()
      .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(times), kCIInputAspectRatioKey: 1])
      .cropped(to: target)
  }

  private static func rounded(_ image: CIImage, _ radius: CGFloat) -> CIImage {
    let most = min(image.extent.width, image.extent.height) / 2
    guard let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
      "inputExtent": CIVector(cgRect: image.extent), "inputRadius": min(radius, most), "inputColor": CIColor.white,
    ])?.outputImage else { return image }
    return image.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: shape]).cropped(to: image.extent)
  }

  /// The sheet of paper, seen from straight above, with the shadows taken off.
  private static func scanned(_ image: CIImage) throws -> CIImage {
    let request = VNDetectDocumentSegmentationRequest()
    try VNImageRequestHandler(ciImage: image).perform([request])
    guard let sheet = request.results?.first, sheet.confidence > 0.5 else {
      throw ProcessingError.conversionFailed(reason: "There is no sheet of paper to be seen in the picture.")
    }
    let extent = image.extent
    func corner(_ point: CGPoint) -> CIVector {
      CIVector(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height)
    }
    let straight = image.applyingFilter("CIPerspectiveCorrection", parameters: [
      "inputTopLeft": corner(sheet.topLeft), "inputTopRight": corner(sheet.topRight),
      "inputBottomLeft": corner(sheet.bottomLeft), "inputBottomRight": corner(sheet.bottomRight),
    ])
    let flat = atTheCorner(straight)
    return flat.applyingFilter("CIDocumentEnhancer", parameters: ["inputAmount": 1.0]).cropped(to: flat.extent)
  }

  /// What is behind is blurred by itself: blurred with what is in front, a
  /// coloured mist comes out round its edges.
  private static func blurredBehind(_ image: CIImage) throws -> CIImage {
    let mask = try subjectMask(of: image)
    let radius = max(image.extent.width, image.extent.height) * 0.018
    let behind = image.applyingFilter("CIBlendWithMask", parameters: [
      kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask.applyingFilter("CIColorInvert"),
    ]).cropped(to: image.extent)
    let blurred = behind.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
      .cropped(to: image.extent).unpremultiplyingAlpha().settingAlphaOne(in: image.extent)
    return image.applyingFilter("CIBlendWithMask", parameters: [
      kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: mask,
    ]).cropped(to: image.extent)
  }

  static func fitted(_ mask: CIImage, to image: CIImage) -> CIImage {
    atTheCorner(mask).transformed(by: CGAffineTransform(
      scaleX: image.extent.width / mask.extent.width, y: image.extent.height / mask.extent.height
    ))
  }

  private static func cutOut(_ image: CIImage) throws -> CIImage {
    image.applyingFilter("CIBlendWithMask", parameters: [
      kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: try subjectMask(of: image),
    ]).cropped(to: image.extent)
  }

  /// White where what the picture is of is.
  private static func subjectMask(of image: CIImage) throws -> CIImage {
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
    return fitted(cover, to: image)
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
