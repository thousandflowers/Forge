import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import Forge

@MainActor
final class CutModelTests: ToolTestCase {
  private func film(length: Double = 10, size: CGSize = CGSize(width: 320, height: 200)) throws -> CutModel {
    let url = path("a.mp4")
    try Data("x".utf8).write(to: url)
    let model = try XCTUnwrap(CutModel(file: try ProcessableFile(url: url)))
    model.begin(length: length, seen: size)
    return model
  }

  func test_nothingIsNothing() throws {
    XCTAssertEqual(try film().tools, [])
  }

  func test_theEndsDoNotCross() throws {
    let model = try film()
    model.setFrom(4)
    model.setTo(2)
    XCTAssertEqual(model.to, 4 + CutModel.shortest, accuracy: 0.001)
    model.setFrom(-3)
    XCTAssertEqual(model.from, 0)
    model.setTo(99)
    XCTAssertEqual(model.to, 10)
    model.setFrom(99)
    XCTAssertEqual(model.from, 10 - CutModel.shortest, accuracy: 0.001)
  }

  func test_thePartSlides() throws {
    let model = try film()
    model.setFrom(2); model.setTo(5)
    model.slide(to: 9)
    XCTAssertEqual([model.from, model.to], [7, 10])
    model.slide(to: -1)
    XCTAssertEqual([model.from, model.to], [0, 3])
  }

  func test_aPartIsATrim() throws {
    let model = try film()
    model.setFrom(2); model.setTo(5.12345)
    XCTAssertEqual(model.tools, [.trim(Span(from: 2, to: 5.123))])
    model.setTo(10)
    XCTAssertEqual(model.tools, [.trim(Span(from: 2, to: nil))])
    model.isFast = true
    XCTAssertEqual(model.tools, [.trim(Span(from: 2, to: nil), fast: true)])
    model.turn()
    XCTAssertEqual(model.tools, [.turn(.right), .trim(Span(from: 2, to: nil))], "turned it is encoded again whatever was asked")
  }

  func test_shapes() throws {
    let model = try film()
    model.setShape(.init(across: 1, down: 1))
    XCTAssertEqual(model.box, CGRect(x: 60, y: 0, width: 200, height: 200))
    model.drag(.init(x: 1, y: 1), from: model.box, by: CGSize(width: -100, height: -100))
    XCTAssertEqual(model.box, CGRect(x: 60, y: 0, width: 100, height: 100))
    model.drag(.init(x: -1, y: -1), from: model.box, by: CGSize(width: -500, height: -500))
    XCTAssertEqual(model.box, CGRect(x: 60, y: 0, width: 100, height: 100), "there is no room above it")
    model.drag(.init(x: 1, y: 0), from: model.box, by: CGSize(width: 50, height: 0))
    XCTAssertEqual(model.box.width, 100, "a side alone would be another shape")
    model.move(model.box, by: CGSize(width: 900, height: 900))
    XCTAssertEqual(model.box, CGRect(x: 220, y: 100, width: 100, height: 100))
  }

  func test_freely() throws {
    let model = try film()
    model.drag(.init(x: -1, y: 0), from: model.box, by: CGSize(width: 40, height: 0))
    model.drag(.init(x: 0, y: 1), from: model.box, by: CGSize(width: 0, height: -60))
    XCTAssertEqual(model.box, CGRect(x: 40, y: 0, width: 280, height: 140))
    model.drag(.init(x: 1, y: 1), from: model.box, by: CGSize(width: -900, height: -900))
    XCTAssertEqual(model.box.size, CGSize(width: CutModel.smallest, height: CutModel.smallest))
    XCTAssertEqual(model.tools, [.crop(.box(x: 40, y: 0, width: 16, height: 16))])
    model.showWhole()
    XCTAssertEqual(model.tools, [])
  }

  /// What was in the box is what is in it once it is turned.
  func test_theBoxTurnsWithThePicture() throws {
    let model = try film()
    model.setBox(CGRect(x: 0, y: 0, width: 100, height: 50))
    model.turn()
    XCTAssertEqual(model.box, CGRect(x: 150, y: 0, width: 50, height: 100))
    for _ in 0..<3 { model.turn() }
    XCTAssertEqual(model.box, CGRect(x: 0, y: 0, width: 100, height: 50))
    model.mirror()
    XCTAssertEqual(model.box, CGRect(x: 220, y: 0, width: 100, height: 50))
  }

  /// The box as it is drawn is the box that is cut, whatever was turned first.
  func test_whatIsDrawnIsWhatIsCut() async throws {
    let source = path("real.mp4")
    try await Quarters.film(at: source)
    let model = try XCTUnwrap(CutModel(file: try ProcessableFile(url: source)))
    await model.load()
    XCTAssertEqual(model.seen, CGSize(width: 320, height: 200))
    // The green quarter, which a turn to the right puts at the bottom right.
    model.setBox(CGRect(x: 160, y: 0, width: 160, height: 100))
    model.turn()
    model.mirror()
    model.setTo(1)
    let made = try await run([], on: source, more: model.preset.actions)[0]
    let frame = try Quarters.frame(of: made)
    XCTAssertEqual(Quarters.read(frame), [.green, .green, .green, .green])
    let length = try await seconds(made)
    XCTAssertEqual(length, 1, accuracy: 0.15)
  }

  func test_aPhotographLyingOnItsSide() async throws {
    let source = path("side.jpg")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, Quarters.picture(), [kCGImagePropertyOrientation: 6] as CFDictionary)
    CGImageDestinationFinalize(destination)
    let model = try XCTUnwrap(CutModel(file: try ProcessableFile(url: source)))
    await model.load()
    XCTAssertEqual(model.seen, CGSize(width: 200, height: 320))
    // Seen upright: blue red over white green.
    model.setBox(CGRect(x: 100, y: 0, width: 100, height: 160))
    let made = try await run([], on: source, more: model.preset.actions)[0]
    XCTAssertEqual(try Quarters.read(made), [.red, .red, .red, .red])
  }

  func test_whatCannotBeCut() throws {
    let url = path("a.txt")
    try Data("x".utf8).write(to: url)
    XCTAssertNil(CutModel(file: try ProcessableFile(url: url)))
  }
}
