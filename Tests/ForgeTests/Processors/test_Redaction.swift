import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import Forge

/// Assisted redaction: what was suggested, what a person confirmed, and the gap
/// between the two.
///
/// The gap is the point. A detector's opinion never reaches a file on its own,
/// and most of what is here is that rule holding.
final class RedactionTests: BaseTestCase {

  // MARK: - Nothing happens without a person

  func test_session_startsWithNothingConfirmed() {
    let session = RedactionSession(source: path("scan.png"), candidates: [
      RedactionCandidate(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), kind: .face),
      RedactionCandidate(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1), kind: .text),
    ])

    XCTAssertEqual(session.candidates.count, 2)
    XCTAssertTrue(session.confirmedRegions.isEmpty, "finding something is not agreeing to cover it")
    XCTAssertFalse(session.hasSomethingToDo)
  }

  func test_session_confirmsOneAtATime() {
    var session = RedactionSession(source: path("scan.png"), candidates: [
      RedactionCandidate(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), kind: .face),
      RedactionCandidate(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1), kind: .text),
    ])

    session.toggle(session.candidates[0])
    XCTAssertEqual(session.confirmedRegions.count, 1)
    XCTAssertEqual(session.confirmedRegions.first?.origin.x, 0.1)

    session.toggle(session.candidates[0])
    XCTAssertTrue(session.confirmedRegions.isEmpty, "and it can be taken back")
  }

  /// A region somebody drew is confirmed by the drawing of it.
  func test_session_takesARegionDrawnByHand() {
    var session = RedactionSession(source: path("scan.png"), candidates: [])
    session.add(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))

    XCTAssertEqual(session.candidates.count, 1)
    XCTAssertEqual(session.confirmedRegions.count, 1)
  }

  /// The hard rule, at the only place that could break it.
  func test_redactor_refusesToWriteAnythingWithNothingConfirmed() throws {
    let source = try Fixture.image(at: path("scan.png"))
    let output = path("covered.png")

    XCTAssertThrowsError(
      try Redactor.apply([], style: .blackout, to: source, writing: output),
      "an empty confirmation must produce nothing at all"
    )
    XCTAssertFalse(exists(output))
  }

  // MARK: - What actually reaches the file

  func test_redactor_coversTheConfirmedRegionAndNothingElse() throws {
    let source = try Fixture.image(at: path("scan.png"), width: 200, height: 200)
    let output = path("covered.png")

    // The bottom left quarter, in Vision's coordinates.
    try Redactor.apply(
      [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)],
      style: .blackout,
      to: source,
      writing: output
    )

    XCTAssertTrue(exists(output))
    // A CGImage is measured from the top, so the bottom left quarter is what
    // anybody looking at the picture would call the bottom left.
    XCTAssertEqual(try Self.pixel(of: output, x: 40, y: 160), Self.black, "the confirmed region is covered")
    XCTAssertNotEqual(try Self.pixel(of: output, x: 160, y: 40), Self.black, "and the rest of it is not")
  }

  func test_redactor_neverTouchesTheOriginal() throws {
    let source = try Fixture.image(at: path("scan.png"), width: 120, height: 120)
    let before = size(of: source)
    let untouched = try Self.pixel(of: source, x: 10, y: 110)

    try Redactor.apply(
      [CGRect(x: 0, y: 0, width: 1, height: 1)],
      style: .blackout,
      to: source,
      writing: path("covered.png")
    )

    XCTAssertEqual(size(of: source), before)
    XCTAssertEqual(try Self.pixel(of: source, x: 10, y: 110), untouched)
  }

  func test_redactor_pixellatesTheRegionAndLeavesTheRest() throws {
    let source = try Fixture.image(at: path("scan.png"), width: 200, height: 200)
    let output = path("covered.png")

    try Redactor.apply(
      [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)],
      style: .pixellate,
      to: source,
      writing: output
    )

    XCTAssertTrue(exists(output))
    XCTAssertNotEqual(
      try Self.pixel(of: output, x: 20, y: 180),
      try Self.pixel(of: source, x: 20, y: 180),
      "the covered corner is not the corner that was there"
    )
  }

  // MARK: - What gets suggested

  /// Natural Language reading a line for what it is about, which is what turns
  /// "text" into "somebody's name".
  ///
  /// The half that must always hold is the negative one: a size is not a
  /// person, and calling it one would put a black box over the wrong thing. The
  /// positive half depends on a language model that a machine may not have -
  /// a headless build runner does not - so it stands aside there rather than
  /// failing.
  func test_entities_areReadOutOfRecognisedText() throws {
    XCTAssertNil(RedactionScout.entity(in: "1024 x 768"), "a number is not a person")

    let read = RedactionScout.entity(in: "Eugenio Zamengo")
    try XCTSkipIf(read == nil, "Natural Language has no name model on this machine")
    XCTAssertEqual(read, "Name")
  }

  /// Vision on a picture with words in it. Skipped rather than failed where the
  /// machine's text recognition does not answer: what is under test is what
  /// Forge does with what it gets.
  func test_scout_findsTheTextItCanRead() async throws {
    let source = try Self.page(at: path("letter.png"), saying: "Eugenio Zamengo")

    // Vision needs a graphics context it does not get on a headless build
    // runner, where it fails with "Could not create inference context". That is
    // the machine saying no, not Forge being wrong.
    let found: [RedactionCandidate]
    do {
      found = try await RedactionScout().candidates(in: source)
    } catch {
      throw XCTSkip("Vision cannot run here: \(error.localizedDescription)")
    }

    try XCTSkipIf(found.isEmpty, "text recognition found nothing on this machine")
    XCTAssertTrue(
      found.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 },
      "a candidate with no area is a box nobody can tick"
    )
    XCTAssertTrue(found.contains { $0.text?.isEmpty == false })
  }

  // MARK: - Fixtures

  private static let black: [UInt8] = [0, 0, 0]

  /// A white page with a line of text drawn on it.
  private static func page(at url: URL, saying words: String) throws -> URL {
    let width = 600
    let height = 200
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw Failure("Cannot make a page")
    }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let line = CTLineCreateWithAttributedString(NSAttributedString(
      string: words,
      attributes: [
        .font: CTFontCreateWithName("Helvetica" as CFString, 48, nil),
        .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
      ]
    ))
    context.textPosition = CGPoint(x: 40, y: 80)
    CTLineDraw(line, context)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else {
      throw Failure("Cannot write the page")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot finish the page") }
    return url
  }

  /// One pixel's red, green and blue, measured from the top left.
  private static func pixel(of url: URL, x: Int, y: Int) throws -> [UInt8] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw Failure("Cannot read \(url.lastPathComponent)")
    }

    var pixel = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
      data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw Failure("Cannot sample \(url.lastPathComponent)")
    }
    context.draw(
      image,
      in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height)
    )
    return Array(pixel.prefix(3))
  }
}
