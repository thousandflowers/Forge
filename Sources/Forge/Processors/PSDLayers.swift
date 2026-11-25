import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a Photoshop document is made of. macOS opens one as the picture it
/// comes to, and its layers are read here.
enum PSDLayers {
  struct Layer { let name: String; let image: CGImage }

  static func reads(_ type: UTType) -> Bool {
    ["com.adobe.photoshop-image", "com.adobe.photoshop-large-image"].contains(type.identifier) || type.goes(by: ["psd", "psb"])
  }

  private static let broken = ProcessingError.conversionFailed(reason: "The layers of this file cannot be read.")
  private static let most = 2000

  /// From the top of it down, each as large as the whole document.
  static func read(_ url: URL) throws -> [Layer] {
    var bytes = Bytes(try Data(contentsOf: url, options: .mappedIfSafe))
    guard try bytes.text(4) == "8BPS" else { throw broken }
    let isLarge = try bytes.int(2) == 2
    bytes.at += 6
    _ = try bytes.int(2)
    let height = try bytes.int(4), width = try bytes.int(4), depth = try bytes.int(2), mode = try bytes.int(2)
    guard (8...32).contains(depth), depth == 8 || depth == 16, mode == 3 || mode == 1, (1...300_000).contains(width), (1...300_000).contains(height) else {
      throw ProcessingError.conversionFailed(reason: "Layers are read from RGB and grayscale Photoshop files, of 8 or 16 bits.")
    }
    for _ in 0..<2 { bytes.at += try bytes.int(4) }
    let sectionLength = try bytes.int(isLarge ? 8 : 4)
    guard sectionLength > 0 else { throw none }
    let infoLength = try bytes.int(isLarge ? 8 : 4)
    // Sixteen bits keep theirs further on, under a name.
    if infoLength == 0 { try findLayers(in: &bytes, upTo: bytes.at + sectionLength, isLarge: isLarge) }
    let count = abs(try bytes.signed(2))
    guard count > 0 else { throw none }
    guard count <= most else { throw broken }

    var records: [Record] = []
    for _ in 0..<count { records.append(try record(&bytes, isLarge: isLarge)) }
    var layers: [Layer] = []
    for record in records {
      var planes: [Int: [UInt8]] = [:]
      for channel in record.channels {
        let end = bytes.at + channel.length
        if record.width > 0, record.height > 0, [0, 1, 2, -1].contains(channel.id) {
          planes[channel.id] = try plane(&bytes, record, depth: depth, isLarge: isLarge, end: end)
        }
        bytes.at = end
      }
      if let image = try image(record, planes, isGray: mode == 1, width: width, height: height) {
        layers.append(Layer(name: record.name, image: image))
      }
    }
    guard !layers.isEmpty else { throw none }
    return layers.reversed()
  }

  private static let none = ProcessingError.conversionFailed(reason: "There are no layers in this file.")

  private struct Record {
    var top = 0, left = 0, width = 0, height = 0
    var channels: [(id: Int, length: Int)] = []
    var name = ""
  }

  private static func findLayers(in bytes: inout Bytes, upTo end: Int, isLarge: Bool) throws {
    bytes.at += try bytes.int(4)
    while bytes.at + 12 < end {
      guard ["8BIM", "8B64"].contains(try bytes.text(4)) else { throw none }
      let key = try bytes.text(4)
      let length = try bytes.int(isLarge && ["Lr16", "Lr32", "Layr"].contains(key) ? 8 : 4)
      if key == "Lr16" || key == "Layr" { return }
      bytes.at += (length + 3) / 4 * 4
    }
    throw none
  }

  private static func record(_ bytes: inout Bytes, isLarge: Bool) throws -> Record {
    var made = Record()
    made.top = try bytes.signed(4)
    made.left = try bytes.signed(4)
    made.height = try bytes.signed(4) - made.top
    made.width = try bytes.signed(4) - made.left
    let channels = try bytes.int(2)
    guard channels <= 64, made.width <= 300_000, made.height <= 300_000 else { throw broken }
    for _ in 0..<channels { made.channels.append((try bytes.signed(2), try bytes.int(isLarge ? 8 : 4))) }
    guard try bytes.text(4) == "8BIM" else { throw broken }
    bytes.at += 8
    let end = try bytes.int(4) + bytes.at
    bytes.at += try bytes.int(4)
    bytes.at += try bytes.int(4)
    let length = try bytes.int(1)
    made.name = String(data: try bytes.take(length), encoding: .macOSRoman) ?? ""
    bytes.at += (4 - (length + 1) % 4) % 4
    // Written again in full, where a name has more in it than the old one holds.
    while bytes.at + 12 <= end {
      bytes.at += 4
      let key = try bytes.text(4)
      let size = try bytes.int(isLarge && ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"].contains(key) ? 8 : 4)
      let after = bytes.at + size
      if key == "luni", size >= 4 {
        let count = try bytes.int(4)
        if count * 2 <= size { made.name = String(data: try bytes.take(count * 2), encoding: .utf16BigEndian)?.replacingOccurrences(of: "\0", with: "") ?? made.name }
      }
      bytes.at = after
    }
    bytes.at = end
    return made
  }

  /// One channel, at eight bits: what is shown of a layer by itself.
  private static func plane(_ bytes: inout Bytes, _ record: Record, depth: Int, isLarge: Bool, end: Int) throws -> [UInt8] {
    let size = depth / 8, row = record.width * size, count = record.width * record.height
    let way = try bytes.int(2)
    var made: [UInt8]
    switch way {
    case 0: made = [UInt8](try bytes.take(row * record.height))
    case 1:
      let lengths = try (0..<record.height).map { _ in try bytes.int(isLarge ? 4 : 2) }
      made = []
      made.reserveCapacity(row * record.height)
      for length in lengths { made += try unpacked(try bytes.take(length), to: row) }
    case 2, 3:
      let packed = try bytes.take(max(0, end - bytes.at))
      made = [UInt8](try Data(packed.dropFirst(2)).unpacked(to: row * record.height, COMPRESSION_ZLIB))
      guard made.count == row * record.height else { throw broken }
      if way == 3 { undoDifferences(&made, row: row, size: size) }
    default: throw broken
    }
    guard size == 2 else { return made }
    return (0..<count).map { made[$0 * 2] }
  }

  private static func undoDifferences(_ made: inout [UInt8], row: Int, size: Int) {
    for start in stride(from: 0, to: made.count, by: row) {
      if size == 1 {
        for index in (start + 1)..<max(start + 1, start + row) { made[index] &+= made[index - 1] }
      } else {
        for index in stride(from: start + 2, to: start + row, by: 2) {
          let sum = (UInt16(made[index]) << 8 | UInt16(made[index + 1])) &+ (UInt16(made[index - 2]) << 8 | UInt16(made[index - 1]))
          made[index] = UInt8(sum >> 8)
          made[index + 1] = UInt8(sum & 0xFF)
        }
      }
    }
  }

  /// Runs, as PackBits writes them.
  static func unpacked(_ data: Data, to size: Int) throws -> [UInt8] {
    let packed = [UInt8](data)
    var made: [UInt8] = []
    made.reserveCapacity(size)
    var at = 0
    while at < packed.count, made.count < size {
      let head = Int(Int8(bitPattern: packed[at]))
      at += 1
      if head >= 0 {
        guard at + head + 1 <= packed.count else { throw broken }
        made += packed[at..<(at + head + 1)]
        at += head + 1
      } else if head > -128 {
        guard at < packed.count else { throw broken }
        made += [UInt8](repeating: packed[at], count: 1 - head)
        at += 1
      }
    }
    guard made.count == size else { throw broken }
    return made
  }

  /// On a page as large as the document. A folder has nothing on it, and is
  /// left out.
  private static func image(_ record: Record, _ planes: [Int: [UInt8]], isGray: Bool, width: Int, height: Int) throws -> CGImage? {
    guard let red = planes[0] else { return nil }
    let green = isGray ? red : planes[1] ?? red, blue = isGray ? red : planes[2] ?? red, alpha = planes[-1]
    var pixels = [UInt8](repeating: 0, count: red.count * 4)
    for index in red.indices {
      pixels[index * 4] = red[index]
      pixels[index * 4 + 1] = green[index]
      pixels[index * 4 + 2] = blue[index]
      pixels[index * 4 + 3] = alpha?[index] ?? 255
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(pixels) as CFData), let layer = CGImage(
      width: record.width, height: record.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: record.width * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ), let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw broken }
    context.draw(layer, in: CGRect(x: record.left, y: height - record.top - record.height, width: record.width, height: record.height))
    return context.makeImage()
  }

  /// Read from the front, and never past the end.
  private struct Bytes {
    let data: Data
    var at = 0

    init(_ data: Data) { self.data = data }

    mutating func take(_ count: Int) throws -> Data {
      guard count >= 0, at >= 0, count <= data.count, at <= data.count - count else { throw PSDLayers.broken }
      defer { at += count }
      return data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + count))
    }

    mutating func int(_ count: Int) throws -> Int {
      let value = try take(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      guard value <= UInt64(Int32.max) else { throw PSDLayers.broken }
      return Int(value)
    }

    mutating func signed(_ count: Int) throws -> Int {
      let value = try take(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      return count == 2 ? Int(Int16(truncatingIfNeeded: value)) : Int(Int32(truncatingIfNeeded: value))
    }

    mutating func text(_ count: Int) throws -> String { String(decoding: try take(count), as: UTF8.self) }
  }
}
