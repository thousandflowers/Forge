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
  static func iconLadder(from image: CGImage, sizes iconSizes: [Int] = iconSizes) -> [ImageFrame] {
    let longest = max(image.width, image.height)
    let sizes = iconSizes.filter { $0 <= longest }
    // A picture smaller than the smallest icon goes on the smallest icon: an
    // 8-pixel picture was offered as an 8-pixel icon, which no icon format takes.
    let ladder = sizes.isEmpty ? [iconSizes[0]] : sizes

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

  /// The squares an icon format holds, or nil for a format that is not one.
  /// ICNS takes fewer than ICO and refuses any other size outright.
  static func iconSizes(for type: UTType) -> [Int]? {
    if type.conforms(to: .ico) { return iconSizes }
    if type.conforms(to: .icns) { return [16, 32, 128, 256, 512] }
    return nil
  }

  /// How many times the animation in this file plays; zero is for ever.
  static func loopCount(of source: CGImageSource) -> Int {
    let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
    let places: [(CFString, CFString)] = [
      (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
      (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount),
      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
      (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
    ]
    for (block, key) in places {
      if let count = (properties[block] as? [CFString: Any])?[key] as? Int { return count }
    }
    return infiniteLoop
  }

  /// Read every frame, with the delay each one carries.
  static func read(_ source: CGImageSource, options: CFDictionary?) -> [ImageFrame] {
    (0..<CGImageSourceGetCount(source)).compactMap { index in
      guard let image = CGImageSourceCreateImageAtIndex(source, index, options) else { return nil }
      return ImageFrame(image: image, duration: delay(of: source, at: index))
    }
  }

  /// Write frames into one animated or multi-page file.
  ///
  /// macOS sometimes refuses a write for what came with the picture rather
  /// than for the picture: a HEIC's own properties in a HEICS, an AVIF asked
  /// for a quality of exactly 100. So a refusal is tried again with less - the
  /// quality alone, then a quality just short of the top - before it is
  /// reported. The picture is the same; what may be lost is its metadata.
  static func write(
    _ frames: [ImageFrame],
    to output: URL,
    as type: UTType,
    frameOptions: [CFString: Any],
    loopCount: Int = infiniteLoop
  ) throws {
    let quality = kCGImageDestinationLossyCompressionQuality
    var bare: [CFString: Any] = [:]
    if let asked = frameOptions[quality] { bare[quality] = asked }
    var gentler = bare
    if let asked = (frameOptions[quality] as? NSNumber)?.doubleValue, asked >= 1 { gentler[quality] = 0.95 }

    for options in [frameOptions, bare, gentler] {
      if try attempt(frames, to: output, as: type, frameOptions: options, loopCount: loopCount) { return }
      // What a refused write leaves behind: the file, and ImageIO's own
      // temporary beside it, named after it with one more dot in front.
      let folder = output.deletingLastPathComponent()
      for leftover in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
      where leftover.lastPathComponent == output.lastPathComponent
        || leftover.lastPathComponent.hasPrefix("." + output.lastPathComponent) {
        try? FileManager.default.removeItem(at: leftover)
      }
    }

    let format = (FormatCatalog.fileExtension(for: type) ?? type.identifier).uppercased()
    let size = frames.first.map { " at \($0.image.width) × \($0.image.height)" } ?? ""
    throw ProcessingError.conversionFailed(
      reason: "Cannot write \(output.lastPathComponent) as \(format)\(size): macOS refused this image in that format. "
        + "Some formats take only certain sizes."
    )
  }

  /// One go at writing them. False is macOS declining; a thrown error is not
  /// being able to start at all.
  private static func attempt(
    _ frames: [ImageFrame],
    to output: URL,
    as type: UTType,
    frameOptions: [CFString: Any],
    loopCount: Int
  ) throws -> Bool {
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

    return CGImageDestinationFinalize(destination)
  }

  // MARK: - Per-format frame timing

  private static func delay(of source: CGImageSource, at index: Int) -> Double {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
      return 0
    }
    for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyHEICSDictionary, kCGImagePropertyPNGDictionary,
                kCGImagePropertyWebPDictionary] {
      guard let dictionary = properties[key] as? [CFString: Any] else { continue }
      // The unclamped delay is the one the file actually asked for; the other
      // has a browser-compatibility floor applied to it.
      for delayKey in [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                       kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime,
                       kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime,
                       // An animated WebP's frames were read with no delay at
                       // all, so the GIF made from one ran flat out.
                       kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime] {
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
