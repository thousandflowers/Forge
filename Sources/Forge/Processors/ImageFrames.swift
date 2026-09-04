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
        reason: "Cannot write \(type.preferredFilenameExtension ?? type.identifier)"
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
