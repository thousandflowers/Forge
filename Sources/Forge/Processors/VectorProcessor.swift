import Foundation
import Compression
import CoreGraphics
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// SVG, drawn by QuickLook and then handed to the image path.
///
/// ImageIO has no SVG decoder, and this was written off as needing a web view.
/// It does not: the system ships a QuickLook generator for SVG, so asking for a
/// representation at the size wanted is a framework call like any other. What
/// comes back is a raster, which is all a PNG, a JPEG or a PDF page needs.
///
/// Everything after the drawing - resizing, filters, quality, which format to
/// write - belongs to `ImageProcessor`, which already does it for every other
/// picture on the machine.
final class VectorProcessor: FileProcessor, @unchecked Sendable {
  let name = "Vector Processor"

  /// The longest side of the drawing when nothing asks for a size. QuickLook
  /// fits the artwork into the box it is given and keeps the proportions, so
  /// this is a ceiling rather than a shape.
  static let defaultSide = 1024

  /// A gzipped SVG says how large it unpacks to, in a trailer anybody can
  /// write. The claim is honoured up to here and no further.
  private static let maximumUnpackedBytes = 64 * 1024 * 1024

  private let images = ImageProcessor()

  func canProcess(_ file: ProcessableFile) -> Bool {
    FormatCatalog.isRasterizableVector(file.fileType)
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-vector-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let plain = try Self.unpacked(input, into: scratch)
    let raster = try await Self.draw(plain, side: Self.side(for: operations), into: scratch)
    progress(0.5)

    return try await images.process(raster, to: output, with: operations) { fraction in
      progress(0.5 + fraction / 2)
    }
  }

  /// How large to draw. A resize already says what size the picture should end
  /// up at, and drawing straight to it spares the one indignity a vector never
  /// has to suffer: being rasterized at one size and scaled to another.
  static func side(for operations: [Operation]) -> Int {
    let asked = operations.compactMap { operation -> Int? in
      guard case .resize(let width, let height, _) = operation else { return nil }
      return [width, height].compactMap { $0 }.max()
    }
    return max(asked.max() ?? defaultSide, 1)
  }

  private static func draw(_ url: URL, side: Int, into folder: URL) async throws -> URL {
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: side, height: side),
      scale: 1,
      representationTypes: .thumbnail
    )

    let image: CGImage = try await withCheckedThrowingContinuation { continuation in
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
        if let drawing = representation?.cgImage {
          continuation.resume(returning: drawing)
        } else {
          continuation.resume(
            throwing: ProcessingError.conversionFailed(
              reason: "Cannot draw \(url.lastPathComponent): "
                + (error?.localizedDescription ?? "QuickLook returned nothing")
            )
          )
        }
      }
    }

    let destination = folder.appendingPathComponent("drawing.png")
    guard let sink = CGImageDestinationCreateWithURL(
      destination as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot hold the drawing of \(url.lastPathComponent)"
      )
    }
    CGImageDestinationAddImage(sink, image, nil)
    guard CGImageDestinationFinalize(sink) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot hold the drawing of \(url.lastPathComponent)"
      )
    }
    return destination
  }

  /// An `.svgz` is a gzipped `.svg`, and the QuickLook generator refuses one
  /// outright, so it is unpacked into scratch first. A plain SVG is handed on
  /// as it stands.
  static func unpacked(_ input: URL, into folder: URL) throws -> URL {
    let data = try Data(contentsOf: input, options: .mappedIfSafe)
    guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
      return input
    }
    let plain = folder.appendingPathComponent("unpacked.svg")
    try gunzip(data).write(to: plain)
    return plain
  }

  /// RFC 1952: a ten-byte header, the optional fields the flags claim, raw
  /// DEFLATE, then a CRC and the unpacked size.
  static func gunzip(_ data: Data) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
      throw ProcessingError.conversionFailed(reason: "Not a gzipped file")
    }

    let flags = bytes[3]
    var start = 10

    if flags & 0x04 != 0 {                                            // FEXTRA
      guard start + 1 < bytes.count else { throw Self.truncated }
      start += 2 + (Int(bytes[start]) | Int(bytes[start + 1]) << 8)
    }
    for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {   // FNAME, FCOMMENT
      guard start < bytes.count, let end = bytes[start...].firstIndex(of: 0) else {
        throw Self.truncated
      }
      start = end + 1
    }
    if flags & 0x02 != 0 { start += 2 }                               // FHCRC

    let end = bytes.count - 8
    guard start < end else { throw Self.truncated }
    let deflated = Array(bytes[start..<end])

    // The trailer is a CRC and then the unpacked size, little-endian, so the
    // size is the last four bytes. It is a hint rather than a promise: it is
    // clamped, and a buffer that turns out to be too small is grown rather
    // than believed.
    let claimed = (0..<4).reduce(0) { $0 | Int(bytes[end + 4 + $1]) << (8 * $1) }
    var capacity = min(max(claimed, 64 * 1024), maximumUnpackedBytes)

    while true {
      var unpacked = Data(count: capacity)
      let written = unpacked.withUnsafeMutableBytes { destination -> Int in
        guard let target = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return deflated.withUnsafeBufferPointer { source -> Int in
          guard let origin = source.baseAddress else { return 0 }
          return compression_decode_buffer(
            target, capacity, origin, deflated.count, nil, COMPRESSION_ZLIB
          )
        }
      }

      // A buffer filled to the brim may have had the rest cut off it, so a
      // full one is not trusted either.
      if written > 0, written < capacity {
        // The decoder does not check what it is given: raw DEFLATE made of
        // whatever bytes happened to be there still returns a length. The
        // trailer says how much should have come out, and that is the check.
        guard written == claimed else {
          throw ProcessingError.conversionFailed(
            reason: "This file is not the gzip it says it is"
          )
        }
        return unpacked.prefix(written)
      }
      guard capacity < maximumUnpackedBytes else {
        throw ProcessingError.conversionFailed(reason: "Cannot unpack this file")
      }
      capacity = min(capacity * 2, maximumUnpackedBytes)
    }
  }

  private static let truncated = ProcessingError.conversionFailed(
    reason: "This file claims to be gzipped and stops in the middle"
  )
}
