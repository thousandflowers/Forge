import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures in a PDF, as they were put there: not drawn again.
enum PDFPictures {
  /// Where it can be had as it is it is, and otherwise a PNG of it.
  struct Picture { let type: UTType; let data: Data }

  /// A dot in a corner, or a line: not what anybody calls a picture.
  private static let smallest = 8
  private static let deepest = 8

  /// The chain, made for what the first of them is.
  static func settled(_ actions: [Operation], for file: ProcessableFile) throws -> [Operation] {
    guard let first = try all(in: file.url, most: 1).first else { throw none(file.fileName) }
    let rest = actions.filter { !$0.isFormat }
    return [.convertFormat(to: first.type)] + rest
  }

  private static func none(_ name: String) -> ProcessingError { .conversionFailed(reason: "There are no pictures in \(name).") }

  static func write(from input: URL, to output: URL, progress: (Double) -> Void) throws -> ProcessingResult {
    let start = Date()
    let found = try all(in: input)
    guard let first = found.first else { throw none(input.lastPathComponent) }
    try first.data.write(to: output)
    var extras: [URL] = []
    for (index, picture) in found.enumerated().dropFirst() {
      let place = output.numbered(index + 1, of: found.count).deletingPathExtension().appendingPathExtension(FormatCatalog.fileExtension(for: picture.type) ?? "png")
      try picture.data.write(to: place)
      extras.append(place)
      progress(Double(index + 1) / Double(found.count))
    }
    progress(1)
    return ProcessingResult(outputURL: output, outputSize: Int64(first.data.count), outputDimensions: nil, duration: Date().timeIntervalSince(start), additionalOutputs: extras)
  }

  static func all(in url: URL, most: Int = 10_000) throws -> [Picture] {
    guard let pdf = CGPDFDocument(url as CFURL) else { throw ProcessingError.conversionFailed(reason: "Cannot open \(url.lastPathComponent)") }
    guard pdf.isUnlocked else {
      throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is protected by a password.")
    }
    var found: [Picture] = [], seen: Set<Int> = []
    for number in 1...max(1, pdf.numberOfPages) {
      try Task.checkCancellation()
      guard let page = pdf.page(at: number), found.count < most else { break }
      var resources: CGPDFDictionaryRef?
      // A page's own, or whoever it was handed them by.
      var holder = page.dictionary
      while let here = holder, !CGPDFDictionaryGetDictionary(here, "Resources", &resources) {
        var parent: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(here, "Parent", &parent)
        holder = parent
      }
      if let resources { gather(resources, into: &found, seen: &seen, depth: 0, most: most) }
    }
    return found
  }

  private static func gather(_ resources: CGPDFDictionaryRef, into found: inout [Picture], seen: inout Set<Int>, depth: Int, most: Int) {
    var objects: CGPDFDictionaryRef?
    guard depth < deepest, CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return }
    for (_, stream) in streams(in: objects).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) where found.count < most {
      guard seen.insert(unsafeBitCast(stream, to: Int.self)).inserted, let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
      switch name("Subtype", in: dictionary) {
      case "Image": if let picture = picture(stream, dictionary) { found.append(picture) }
      case "Form":
        var inner: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner { gather(inner, into: &found, seen: &seen, depth: depth + 1, most: most) }
      default: break
      }
    }
  }

  private final class Found { var streams: [(name: String, stream: CGPDFStreamRef)] = [] }

  private static func streams(in dictionary: CGPDFDictionaryRef) -> [(name: String, stream: CGPDFStreamRef)] {
    let found = Found()
    CGPDFDictionaryApplyBlock(dictionary, { key, object, info in
      var stream: CGPDFStreamRef?
      if CGPDFObjectGetValue(object, .stream, &stream), let stream, let info {
        Unmanaged<Found>.fromOpaque(info).takeUnretainedValue().streams.append((String(cString: key), stream))
      }
      return true
    }, Unmanaged.passUnretained(found).toOpaque())
    return found.streams
  }

  private static func name(_ key: String, in dictionary: CGPDFDictionaryRef) -> String? {
    var value: UnsafePointer<CChar>?
    return CGPDFDictionaryGetName(dictionary, key, &value) ? value.map { String(cString: $0) } : nil
  }

  private static func number(_ key: String, in dictionary: CGPDFDictionaryRef) -> Int? {
    var value: CGPDFInteger = 0
    return CGPDFDictionaryGetInteger(dictionary, key, &value) ? value : nil
  }

  private static func picture(_ stream: CGPDFStreamRef, _ dictionary: CGPDFDictionaryRef) -> Picture? {
    guard let width = number("Width", in: dictionary), let height = number("Height", in: dictionary), width >= smallest, height >= smallest else { return nil }
    var isMask: CGPDFBoolean = 0
    if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isMask), isMask != 0 { return nil }
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
    var mask: CGPDFStreamRef?
    CGPDFDictionaryGetStream(dictionary, "SMask", &mask)
    // With a mask of its own it is a JPEG and something else besides.
    if mask == nil {
      if format == .jpegEncoded { return Picture(type: .jpeg, data: data) }
      if format == .JPEG2000 { return Picture(type: UTType("public.jpeg-2000") ?? .jpeg, data: data) }
    }
    let image: CGImage?
    if format == .raw {
      image = raw(data, dictionary, width: width, height: height)
    } else {
      image = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
    guard var image else { return nil }
    if let mask, let cover = gray(mask), let cut = masked(image, by: cover) { image = cut }
    let made = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(made, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? Picture(type: .png, data: made as Data) : nil
  }

  private static func masked(_ image: CGImage, by mask: CGImage) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let context = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.clip(to: all, mask: mask)
    context.draw(image, in: all)
    return context.makeImage()
  }

  private static func gray(_ stream: CGPDFStreamRef) -> CGImage? {
    var format = CGPDFDataFormat.raw
    guard let dictionary = CGPDFStreamGetDictionary(stream), let width = number("Width", in: dictionary), let height = number("Height", in: dictionary),
          let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
    guard format == .raw else { return CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
    return made(data, width, height, bits: number("BitsPerComponent", in: dictionary) ?? 8, space: CGColorSpaceCreateDeviceGray())
  }

  private static func raw(_ data: Data, _ dictionary: CGPDFDictionaryRef, width: Int, height: Int) -> CGImage? {
    let bits = number("BitsPerComponent", in: dictionary) ?? 8
    var object: CGPDFObjectRef?
    guard CGPDFDictionaryGetObject(dictionary, "ColorSpace", &object), let object, let space = space(of: object) else { return nil }
    return made(data, width, height, bits: bits, space: space)
  }

  private static func made(_ data: Data, _ width: Int, _ height: Int, bits: Int, space: CGColorSpace) -> CGImage? {
    let row = (width * bits * space.numberOfComponents + 7) / 8
    // Packed in a way that was not unpacked, and so not a picture yet.
    guard data.count >= row * height, let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * space.numberOfComponents, bytesPerRow: row, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: bits == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0), provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent
    )
  }

  private static func space(of object: CGPDFObjectRef, depth: Int = 0) -> CGColorSpace? {
    guard depth < 4 else { return nil }
    var named: UnsafePointer<CChar>?
    if CGPDFObjectGetValue(object, .name, &named), let named {
      switch String(cString: named) {
      case "DeviceGray", "CalGray", "G": return CGColorSpaceCreateDeviceGray()
      case "DeviceRGB", "CalRGB", "RGB": return CGColorSpace(name: CGColorSpace.sRGB)
      case "DeviceCMYK", "CMYK": return CGColorSpaceCreateDeviceCMYK()
      default: return nil
      }
    }
    var array: CGPDFArrayRef?
    guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) > 0, CGPDFArrayGetName(array, 0, &named), let named else { return nil }
    switch String(cString: named) {
    case "ICCBased":
      var stream: CGPDFStreamRef?, format = CGPDFDataFormat.raw
      guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
      let count = number("N", in: dictionary) ?? 3
      if let profile = CGPDFStreamCopyData(stream, &format), let own = CGColorSpace(iccData: profile), own.numberOfComponents == count { return own }
      return count == 1 ? CGColorSpaceCreateDeviceGray() : count == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpace(name: CGColorSpace.sRGB)
    case "CalGray": return CGColorSpaceCreateDeviceGray()
    case "CalRGB": return CGColorSpace(name: CGColorSpace.sRGB)
    case "Indexed", "I":
      var base: CGPDFObjectRef?, last: CGPDFInteger = 0
      guard CGPDFArrayGetObject(array, 1, &base), let base, let under = self.space(of: base, depth: depth + 1), CGPDFArrayGetInteger(array, 2, &last), (0...255).contains(last) else { return nil }
      var table: Data?
      var string: CGPDFStringRef?, stream: CGPDFStreamRef?, format = CGPDFDataFormat.raw
      if CGPDFArrayGetString(array, 3, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
        table = Data(bytes: bytes, count: CGPDFStringGetLength(string))
      } else if CGPDFArrayGetStream(array, 3, &stream), let stream {
        table = CGPDFStreamCopyData(stream, &format) as Data?
      }
      guard let table, table.count >= (last + 1) * under.numberOfComponents else { return nil }
      return CGColorSpace(indexedBaseSpace: under, last: last, colorTable: [UInt8](table))
    default: return nil
    }
  }
}
