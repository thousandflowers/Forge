import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Forge

/// The shape and the edges of a converted picture. Each of these came out
/// wrong on the released build and was reported as converted.
final class ImageGeometryTests: BaseTestCase {

  // MARK: - Fixtures and readers

  /// One flat, opaque colour: any pixel that differs was put there by Forge.
  private func flatImage(at url: URL, width: Int, height: Int, bits: Int = 8) throws -> URL {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
    ))
    context.setFillColor(CGColor(srgbRed: 30 / 255, green: 60 / 255, blue: 90 / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let type = try XCTUnwrap(UTType(filenameExtension: url.pathExtension))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  private struct Pixels {
    let width: Int, height: Int, bytes: [UInt8]
    /// Red, green, blue, alpha, counted from the top left.
    func at(_ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(bytes[(y * width + x) * 4 + $0]) } }
  }

  private func pixels(of url: URL) throws -> Pixels {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(CGContext(
      data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Pixels(width: image.width, height: image.height, bytes: bytes)
  }

  private func properties(of url: URL) throws -> [CFString: Any] {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
  }

  private func convert(_ source: URL, with preset: RulePreset) async throws -> URL {
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: try folder("out-\(UUID().uuidString.prefix(6))")
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    return try XCTUnwrap(entry.outputURL)
  }

  private func assertFlat(_ url: URL, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let picture = try pixels(of: url)
    let middle = picture.at(picture.width / 2, picture.height / 2)
    let edges = [
      (0, picture.height / 2), (picture.width - 1, picture.height / 2),
      (picture.width / 2, 0), (picture.width / 2, picture.height - 1),
      (0, 0), (picture.width - 1, picture.height - 1),
    ]
    for (x, y) in edges {
      let pixel = picture.at(x, y)
      for channel in 0..<4 {
        XCTAssertEqual(
          pixel[channel], middle[channel], accuracy: 3,
          "\(message): pixel (\(x),\(y)) is \(pixel), the middle is \(middle)", file: file, line: line
        )
      }
    }
  }

  // MARK: - Orientation

  /// A phone held upright stores a sideways picture and a note saying which
  /// way is up. The box was applied to the stored pixels, so "300 wide" on a
  /// portrait photo came out 225 wide.
  func test_aPhotoStoredSidewaysIsResizedTheWayItIsSeen() async throws {
    let source = try Fixture.image(
      at: path("portrait.jpg"), width: 400, height: 300,
      metadata: [kCGImagePropertyOrientation: 6]
    )
    XCTAssertEqual(try properties(of: source)[kCGImagePropertyOrientation] as? Int, 6)

    let output = try await convert(
      source,
      with: .make(format: .jpeg, resize: ResizeSpec(width: 150, height: nil, fitMode: .proportional), category: .image)
    )

    let written = try properties(of: output)
    let orientation = written[kCGImagePropertyOrientation] as? Int ?? 1
    let stored = (written[kCGImagePropertyPixelWidth] as? Int ?? 0, written[kCGImagePropertyPixelHeight] as? Int ?? 0)
    let seen = orientation >= 5 ? (stored.1, stored.0) : stored
    XCTAssertEqual(seen.0, 150, "the picture as displayed is 150 wide")
    XCTAssertEqual(seen.1, 200, "and keeps its 3:4 shape")
  }

  // MARK: - Edges

  /// 800x600 fitted to a height of 400 is 533.33 wide. The picture was drawn
  /// that wide on a canvas 534 wide, and the last column was a quarter picture
  /// and three quarters nothing: a light line down the edge of every JPEG.
  func test_aResizeToAFractionalSizeHasCleanEdges() async throws {
    let source = try flatImage(at: path("flat.png"), width: 800, height: 600)

    let output = try await convert(
      source,
      with: .make(format: .png, resize: ResizeSpec(width: nil, height: 400, fitMode: .proportional), category: .image)
    )

    let picture = try pixels(of: output)
    XCTAssertEqual(picture.height, 400)
    XCTAssertEqual(picture.width, 533)
    try assertFlat(output, "resized")
  }

  func test_aCropAndAPadHaveCleanEdges() async throws {
    let source = try flatImage(at: path("flat.png"), width: 801, height: 599)

    for mode in [ResizeFitMode.cropCenter, .stretch] {
      let output = try await convert(
        source,
        with: .make(format: .png, resize: ResizeSpec(width: 333, height: 250, fitMode: mode), category: .image)
      )
      let picture = try pixels(of: output)
      XCTAssertEqual([picture.width, picture.height], [333, 250], "\(mode)")
      try assertFlat(output, "\(mode)")
    }
  }

  /// A blur reaches past the edge of the picture, and what is past the edge is
  /// nothing: the border faded to transparent, or to white in a JPEG.
  func test_aBlurDoesNotFadeTheBorders() async throws {
    let source = try flatImage(at: path("flat.png"), width: 400, height: 300)

    let output = try await convert(source, with: .make(format: .png, filters: [.blur], category: .image))

    try assertFlat(output, "blurred")
  }

  // MARK: - Depth

  /// Sixteen bits a channel in, eight out, in every format, with no word said.
  func test_aSixteenBitPictureStaysSixteenBit() async throws {
    let source = try flatImage(at: path("deep.png"), width: 64, height: 64, bits: 16)
    XCTAssertEqual(try properties(of: source)[kCGImagePropertyDepth] as? Int, 16)

    for format in [UTType.png, .tiff] {
      let output = try await convert(source, with: .make(format: format, category: .image))
      XCTAssertEqual(try properties(of: output)[kCGImagePropertyDepth] as? Int, 16, format.identifier)
    }
  }

  // MARK: - Text

  /// A file with pages gave up the text of its first and nothing else.
  func test_everyPageOfAMultiPageImageIsRead() async throws {
    let first = try Fixture.textImage(at: path("one.png"), text: "PAGE ONE ALPHA")
    let second = try Fixture.textImage(at: path("two.png"), text: "PAGE TWO BRAVO")
    let pages = path("pages.tiff")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(pages as CFURL, UTType.tiff.identifier as CFString, 2, nil))
    for page in [first, second] {
      let source = try XCTUnwrap(CGImageSourceCreateWithURL(page as CFURL, nil))
      CGImageDestinationAddImage(destination, try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), nil)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let output = try await convert(pages, with: .make(format: .plainText, category: .image))
    let text = try String(contentsOf: output, encoding: .utf8).uppercased()

    XCTAssertTrue(text.contains("ALPHA"), text)
    XCTAssertTrue(text.contains("BRAVO"), "the second page was not read: \(text)")
  }

  // MARK: - What a second pass found

  /// One side alone, with Crop, Pad or Stretch, used the original for the side
  /// nobody named: 800 x 600 asked for "1600 wide, cropped" came back
  /// 1600 x 600. With one side there is nothing to crop or pad to; the shape
  /// is kept.
  func test_oneSideAloneKeepsTheShapeWhateverTheFit() async throws {
    let source = try flatImage(at: path("flat.png"), width: 800, height: 600)
    for mode in [ResizeFitMode.cropCenter, .pad, .stretch, .proportional] {
      let output = try await convert(source, with: .make(
        format: .png, resize: ResizeSpec(width: 1600, height: nil, fitMode: mode), category: .image
      ))
      let result = try pixels(of: output)
      XCTAssertEqual([result.width, result.height], [1600, 1200], "\(mode)")
    }
  }

  /// Invert was done on light as the pipeline holds it, not as the eye reads
  /// it: mid grey came back nearly white (128 became 229). A photographic
  /// negative sends 128 to 127.
  func test_invertIsAPhotographicNegative() async throws {
    let source = path("grey.png")
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 128 / 255, green: 64 / 255, blue: 200 / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let output = try await convert(source, with: .make(format: .png, filters: [.invert], category: .image))
    let pixel = try pixels(of: output).at(20, 20)
    for (got, want) in zip(pixel.prefix(3), [127, 191, 55]) {
      XCTAssertEqual(got, want, accuracy: 3, "\(pixel)")
    }
  }

  /// ICNS takes squares of a few sizes and refused everything else. An icon
  /// made from a wide picture shows the whole picture on a square, as an ICO does.
  func test_aWidePictureBecomesAnICNSOnASquare() async throws {
    let source = try flatImage(at: path("wide.png"), width: 640, height: 480)
    let icns = try XCTUnwrap(UTType("com.apple.icns"))
    try XCTSkipUnless(FormatCatalog.isWritableImage(icns), "this Mac writes no ICNS")

    let output = try await convert(source, with: .make(format: icns, category: .image))
    let result = try pixels(of: output)
    XCTAssertEqual(result.width, result.height)
    XCTAssertEqual(result.at(result.width / 2, 2)[3], 0, "the bars above and below are clear, not stretched picture")
  }

  /// An animation's loop count became "for ever" whatever it had been.
  func test_anAnimationKeepsHowManyTimesItPlays() async throws {
    let source = path("thrice.gif")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.gif.identifier as CFString, 3, nil))
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary)
    for shade in [0.2, 0.5, 0.8] {
      let context = try XCTUnwrap(CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
      CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.25]
      ] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let output = try await convert(source, with: .make(format: .gif, category: .image))
    let read = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
    let whole = try XCTUnwrap(CGImageSourceCopyProperties(read, nil) as? [CFString: Any])
    let gif = try XCTUnwrap(whole[kCGImagePropertyGIFDictionary] as? [CFString: Any])
    XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount] as? Int, 3)
    XCTAssertEqual(CGImageSourceGetCount(read), 3)
  }
}
