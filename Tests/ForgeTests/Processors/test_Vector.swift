import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Forge

/// SVG: the one picture format on this machine that ImageIO cannot read and
/// QuickLook can draw.
final class VectorTests: BaseTestCase {

  /// 200 by 100, so anything that loses the proportions is visible in a number.
  private static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">\
    <rect width="200" height="100" fill="#3178c6"/></svg>
    """

  /// The same SVG gzipped, which is all an `.svgz` is. Held as bytes rather
  /// than made here: a test that compresses with the same code it is checking
  /// proves nothing about a file somebody else wrote.
  private static let gzippedSVG = """
    H4sIAAAAAAAAA3WMSw6AIAwFr0Lq3oImagzlMn6ABD/Bxnp88QAu38zk2ev26tnSfhEE5nNEFJFa2vr\
    IHhutNZYClMSZA0EBoMISfWACU4azeZn4V6s1pkRQtaYfpg7Q2e/OvcAXrlt2AAAA
    """

  private func svgFile(_ name: String = "logo.svg") throws -> URL {
    let url = path(name)
    try Self.svg.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func svgzFile(_ name: String = "logo.svgz") throws -> URL {
    let url = path(name)
    try XCTUnwrap(Data(base64Encoded: Self.gzippedSVG, options: .ignoreUnknownCharacters))
      .write(to: url)
    return url
  }

  private func pixels(of url: URL) throws -> (width: Int, height: Int) {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return (
      try XCTUnwrap(properties?[kCGImagePropertyPixelWidth] as? Int),
      try XCTUnwrap(properties?[kCGImagePropertyPixelHeight] as? Int)
    )
  }

  /// The whole point: an SVG becomes a raster without a web view and without
  /// anything installed.
  func test_svg_becomesAnImage() async throws {
    let source = try svgFile()
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .png, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(output.pathExtension, "png")

    // Drawn into a square box, keeping the artwork's own two-to-one shape.
    let size = try pixels(of: output)
    XCTAssertEqual(size.width, VectorProcessor.defaultSide)
    XCTAssertEqual(size.height, VectorProcessor.defaultSide / 2)
  }

  /// A resize decides the size the vector is drawn at, rather than being
  /// applied to a drawing made at some other size.
  func test_svg_isDrawnAtTheSizeAskedFor() async throws {
    let source = try svgFile()
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(
        format: .jpeg,
        resize: ResizeSpec(width: 400, height: 400, fitMode: .proportional),
        category: .image
      ),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let size = try pixels(of: try XCTUnwrap(entry.outputURL))
    XCTAssertEqual(size.width, 400)
    XCTAssertEqual(size.height, 200)
  }

  /// An `.svgz` is refused outright by the QuickLook generator, so it is
  /// unpacked first - and has to end up at the same picture.
  func test_svgz_isUnpackedAndDrawsTheSameThing() async throws {
    let destination = try folder("out")
    let coordinator = coordinator()

    let fromPlain = try await coordinator.processFile(
      try ProcessableFile(url: try svgFile("plain.svg")),
      with: .make(format: .png, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let fromGzipped = try await coordinator.processFile(
      try ProcessableFile(url: try svgzFile("packed.svgz")),
      with: .make(format: .png, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(fromGzipped.status, .completed)
    let plain = try Data(contentsOf: try XCTUnwrap(fromPlain.outputURL))
    let packed = try Data(contentsOf: try XCTUnwrap(fromGzipped.outputURL))
    XCTAssertEqual(plain, packed, "the gzipped SVG drew something else")
  }

  /// Input from outside is not trusted: a file that opens with the gzip magic
  /// and then is not gzipped has to fail, not be read past its end.
  func test_gunzip_refusesSomethingThatIsNotGzipped() throws {
    var bytes = Data([0x1f, 0x8b, 0x08, 0x00])
    bytes.append(Data(repeating: 0x41, count: 40))
    XCTAssertThrowsError(try VectorProcessor.gunzip(bytes))
    XCTAssertThrowsError(try VectorProcessor.gunzip(Data("not gzipped at all".utf8)))
  }

  /// The size the drawing is made at comes from the resize when there is one.
  func test_theDrawingSizeFollowsTheResize() {
    XCTAssertEqual(VectorProcessor.side(for: []), VectorProcessor.defaultSide)
    XCTAssertEqual(
      VectorProcessor.side(for: [.resize(width: 320, height: 200, fitMode: .proportional)]),
      320
    )
    XCTAssertEqual(
      VectorProcessor.side(for: [.resize(width: nil, height: 2048, fitMode: .proportional)]),
      2048
    )
  }
}
