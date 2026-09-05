import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One frame of an image file, with how long it should be shown.
struct ImageFrame {
  let image: CGImage
  /// Seconds this frame is displayed. Still images report zero.
  let duration: Double
}

/// Reading and writing files that hold more than one image.
///
/// Forge used to take frame zero and discard the rest, so an animated GIF came
/// out as a single still and a multi-page TIFF lost every page but the first.
enum ImageFrames {

  /// Loop for ever, the convention for an animated GIF with no explicit count.
  static let infiniteLoop = 0

  /// The resolutions an icon file is expected to carry.
  static let iconSizes = [16, 32, 48, 64, 128, 256]

  /// Scale one image down to the icon sizes it can fill.
  ///
  /// The ICO encoder accepts square images of at most 256 points and refuses
  /// anything else, so a wide photograph is placed on a square, transparent
  /// canvas rather than stretched or cropped: an icon should still show the
  /// whole picture.
  static func iconLadder(from image: CGImage) -> [ImageFrame] {
    let longest = max(image.width, image.height)
    let sizes = iconSizes.filter { $0 <= longest }
    let ladder = sizes.isEmpty ? [min(longest, iconSizes[0])] : sizes

    return ladder.reversed().compactMap { side in
      square(image, side: side).map { ImageFrame(image: $0, duration: 0) }
    }
  }

  /// The image centred on a transparent square of `side` points.
  private static func square(_ image: CGImage, side: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    let longest = max(image.width, image.height)
    guard longest > 0 else { return nil }

    let scale = Double(side) / Double(longest)
    let width = max(1, Double(image.width) * scale)
    let height = max(1, Double(image.height) * scale)
    context.draw(image, in: CGRect(
      x: (Double(side) - width) / 2,
      y: (Double(side) - height) / 2,
      width: width,
      height: height
    ))
    return context.makeImage()
  }

  /// Read every frame, with the delay each one carries.
  static func read(_ source: CGImageSource, options: CFDictionary?) -> [ImageFrame] {
    (0..<CGImageSourceGetCount(source)).compactMap { index in
      guard let image = CGImageSourceCreateImageAtIndex(source, index, options) else { return nil }
      return ImageFrame(image: image, duration: delay(of: source, at: index))
    }
  }

  /// Write frames into one animated or multi-page file.
  static func write(
    _ frames: [ImageFrame],
    to output: URL,
    as type: UTType,
    frameOptions: [CFString: Any],
    loopCount: Int = infiniteLoop
  ) throws {
    guard let destination = CGImageDestinationCreateWithURL(
      output as CFURL,
      type.identifier as CFString,
      frames.count,
      nil
    ) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot write \(FormatCatalog.fileExtension(for: type) ?? type.identifier)"
      )
    }

    if let container = containerProperties(for: type, loopCount: loopCount) {
      CGImageDestinationSetProperties(destination, container as CFDictionary)
    }

    for frame in frames {
      var properties = frameOptions
      if let timing = timingProperties(for: type, duration: frame.duration) {
        properties.merge(timing) { _, new in new }
      }
      CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
    }

    guard CGImageDestinationFinalize(destination) else {
      throw ProcessingError.conversionFailed(reason: "Cannot write \(output.lastPathComponent)")
    }
  }

  // MARK: - Per-format frame timing

  private static func delay(of source: CGImageSource, at index: Int) -> Double {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
      return 0
    }
    for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyHEICSDictionary, kCGImagePropertyPNGDictionary] {
      guard let dictionary = properties[key] as? [CFString: Any] else { continue }
      // The unclamped delay is the one the file actually asked for; the other
      // has a browser-compatibility floor applied to it.
      for delayKey in [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                       kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime,
                       kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime] {
        if let delay = dictionary[delayKey] as? Double, delay > 0 { return delay }
      }
    }
    return 0
  }

  private static func containerProperties(for type: UTType, loopCount: Int) -> [CFString: Any]? {
    if type.conforms(to: .gif) {
      return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]]
    }
    if let heics = UTType("public.heics"), type.conforms(to: heics) {
      return [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: loopCount]]
    }
    return nil
  }

  private static func timingProperties(for type: UTType, duration: Double) -> [CFString: Any]? {
    guard duration > 0 else { return nil }
    if type.conforms(to: .gif) {
      return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]]
    }
    if let heics = UTType("public.heics"), type.conforms(to: heics) {
      return [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSDelayTime: duration]]
    }
    return nil
  }
}
