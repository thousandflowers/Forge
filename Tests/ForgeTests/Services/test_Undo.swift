import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// Putting things back the way they were.
final class UndoTests: BaseTestCase {
  private let png = RulePreset(name: "t", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])

  private func convert(_ source: URL, _ mode: DestinationMode, to folder: URL? = nil, preset: RulePreset? = nil, backups: Bool = true) async throws -> ProcessingHistory {
    var settings = AppSettings()
    settings.createBackupBeforeOverwrite = backups
    return try await coordinator(settings: settings).processFile(
      try ProcessableFile(url: source), with: preset ?? png, destinationMode: mode, destinationURL: folder
    ) { _ in }
  }

  /// Deleted rather than put in the Trash: these are test files, and the Trash
  /// is somebody's.
  @discardableResult
  private func undo(_ entry: ProcessingHistory) throws -> URL? {
    try Undo.run(entry) { try FileManager.default.removeItem(at: $0) }
  }

  func test_aCopyIsTakenAwayAndTheOriginalIsNotTouched() async throws {
    let source = try Fixture.image(at: path("a.png")), before = try Data(contentsOf: source)
    let entry = try await convert(source, .copyTo, to: try folder("out"))
    XCTAssertTrue(Undo.isPossible(for: entry))
    try undo(entry)
    XCTAssertFalse(exists(try XCTUnwrap(entry.outputURL)))
    XCTAssertEqual(try Data(contentsOf: source), before)
  }

  func test_aReplacedOriginalComesBack() async throws {
    let source = try Fixture.image(at: path("a.png")), before = try Data(contentsOf: source)
    let entry = try await convert(source, .overwrite)
    XCTAssertFalse(exists(source))
    try undo(entry)
    XCTAssertEqual(try Data(contentsOf: source), before)
    XCTAssertEqual(contents(of: workspace).filter { $0.hasPrefix("a.") }, ["a.png"])
  }

  /// The output has the original's own name: it is the file being put back.
  func test_anOriginalReplacedUnderItsOwnNameComesBack() async throws {
    let source = try Fixture.image(at: path("a.png"), width: 400, height: 300), before = try Data(contentsOf: source)
    let small = RulePreset(name: "t", description: "", category: .image, actions: [.resize(width: 100, height: nil, fitMode: .proportional)])
    let entry = try await convert(source, .overwrite, preset: small)
    XCTAssertNotEqual(try Data(contentsOf: source), before)
    try undo(entry)
    XCTAssertEqual(try Data(contentsOf: source), before)
  }

  /// In a watched folder an original put back looks like a file arriving, and
  /// its name still asks for what was undone.
  @MainActor
  func test_aWatchedFolderDoesNotTakeWhatWasPutBack() async throws {
    let source = try Fixture.image(at: path("a_2MB.png"))
    let model = AppModel(persistence: store)
    model.undo(try await convert(source, .overwrite)) { try FileManager.default.removeItem(at: $0) }
    XCTAssertTrue(exists(source))
    XCTAssertTrue(model.wroteThis(source))
  }

  /// With no backup there is nothing to put back, and the only copy left is
  /// not thrown away.
  func test_withoutABackupItIsNotOffered() async throws {
    let source = try Fixture.image(at: path("a.png"))
    let entry = try await convert(source, .overwrite, backups: false)
    XCTAssertFalse(Undo.isPossible(for: entry))
    XCTAssertThrowsError(try undo(entry))
    XCTAssertTrue(exists(try XCTUnwrap(entry.outputURL)))
  }

  func test_aMovedOriginalIsNotLost() async throws {
    let source = try Fixture.image(at: path("a.png"))
    let entry = try await convert(source, .moveTo, to: try folder("out"))
    XCTAssertFalse(exists(source))
    XCTAssertFalse(Undo.isPossible(for: entry), "the copy that was made is the only one there is")
    XCTAssertThrowsError(try undo(entry))
    XCTAssertTrue(exists(try XCTUnwrap(entry.outputURL)))
  }

  /// Somebody has put another file where the original was: both are kept.
  func test_aFileNowInTheOriginalsPlaceIsNotOverwritten() async throws {
    let source = try Fixture.image(at: path("a.png")), before = try Data(contentsOf: source)
    let entry = try await convert(source, .overwrite)
    try Data("mine".utf8).write(to: source)
    let restored = try undo(entry)
    XCTAssertEqual(try Data(contentsOf: source), Data("mine".utf8))
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored)), before)
  }

  func test_whatIsAlreadyGoneIsNotOffered() async throws {
    let source = try Fixture.image(at: path("a.png"))
    let entry = try await convert(source, .copyTo, to: try folder("out"))
    try undo(entry)
    XCTAssertFalse(Undo.isPossible(for: entry))
  }

  func test_historyWrittenBeforeBackupsWereRecordedStillLoads() throws {
    let json = #"{"id":"7144E204-662E-4E7A-A990-3DCEF7916560","fileURL":"file:///tmp/a.png","timestamp":0,"status":"completed","duration":1}"#
    XCTAssertNil(try JSONDecoder().decode(ProcessingHistory.self, from: Data(json.utf8)).backupURL)
  }

  func test_anUndoneRunSaysSoInHistory() async throws {
    let source = try Fixture.image(at: path("a.png"))
    let entry = try await convert(source, .copyTo, to: try folder("out"))
    try await store.markUndone(entry.id)
    let kept = try await store.loadHistory().first { $0.id == entry.id }
    XCTAssertEqual(kept?.isUndone, true)
    XCTAssertEqual(kept?.status, .completed)
  }
}

/// Making a file lighter without being told how - and never heavier.
final class LighterTests: BaseTestCase {
  private let scratch = "lighter"

  private func result(_ bytes: Int64) -> ProcessingResult {
    ProcessingResult(outputURL: path("x"), outputSize: bytes, outputDimensions: nil, duration: 0)
  }

  func test_onlyAWorthwhileSavingIsTaken() {
    XCTAssertTrue(Lighter.isWorthIt(from: 1000, to: 800))
    XCTAssertFalse(Lighter.isWorthIt(from: 1000, to: 1000))
    XCTAssertFalse(Lighter.isWorthIt(from: 1000, to: 2000))
    XCTAssertFalse(Lighter.isWorthIt(from: 1000, to: 970), "three per cent is not worth losing quality for")
    XCTAssertFalse(Lighter.isWorthIt(from: 1000, to: 0))
  }

  /// A picture that is already as light as it gets is left exactly as it is.
  func test_nothingIsWrittenWhenItWouldBeHeavier() async throws {
    let tiny = try Fixture.image(at: path("tiny.png"), width: 2, height: 2), before = try Data(contentsOf: tiny)
    let made = try await Lighter.run(try ProcessableFile(url: tiny), coordinator: coordinator(), into: try folder(scratch))
    XCTAssertNil(made)
    XCTAssertEqual(try Data(contentsOf: tiny), before)
    XCTAssertEqual(contents(of: try folder(scratch)), [])
  }

  func test_aHeavyPictureComesOutLighter() async throws {
    let photo = try ProcessableFile(url: Fixture.noise(at: path("photo.png"), width: 800, height: 600))
    let made = try await Lighter.run(photo, coordinator: coordinator(), into: try folder(scratch))
    let size = try XCTUnwrap(made)
    XCTAssertLessThan(size.outputSize, photo.fileSize)
    XCTAssertEqual(contents(of: try folder(scratch)).count, 1)
  }

  /// Written as a photograph, an animation would be its first frame and a
  /// cut-out would have a box around it.
  func test_animationsAndCutOutsAreLeftAlone() throws {
    let cutOut = path("cut.png"), space = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let image = try XCTUnwrap(context.makeImage())
    for (url, type, frames) in [(cutOut, UTType.png, 1), (path("moves.gif"), UTType.gif, 3)] {
      let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
      for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      XCTAssertNil(Lighter.preset(for: try ProcessableFile(url: url)), url.lastPathComponent)
    }
  }

  /// What nothing can make lighter is left alone, not failed.
  func test_aFileWithNothingToTakeOffIsLeftAlone() async throws {
    let csv = path("a.csv")
    try "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)
    let made = try await Lighter.run(try ProcessableFile(url: csv), coordinator: coordinator(), into: try folder(scratch))
    XCTAssertNil(made)
  }
}
