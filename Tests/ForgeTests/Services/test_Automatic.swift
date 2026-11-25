import AppKit
import AVFoundation
import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// What Forge does without being asked, once it is allowed to.
final class AutomaticTests: BaseTestCase {
  private var on = AppSettings()

  override func setUpWithError() throws {
    try super.setUpWithError()
    on.lighterRecordings = true
    on.friendlyDownloads = true
  }

  /// The same film, carrying what macOS puts inside its recordings.
  private func recording(at url: URL) async throws -> URL {
    let film = try await Fixture.video(at: path("film-\(UUID().uuidString).mov"), seconds: 1)
    let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: film), presetName: AVAssetExportPresetPassthrough))
    let author = AVMutableMetadataItem()
    author.identifier = .quickTimeMetadataAuthor
    author.dataType = kCMMetadataBaseDataType_UTF8 as String
    author.value = ScreenCapture.author as NSString
    session.metadata = [author]
    session.outputURL = url
    session.outputFileType = .mov
    await session.export()
    XCTAssertEqual(session.status, .completed)
    return url
  }

  private func preset(_ url: URL, _ place: Automatic.Place, _ settings: AppSettings? = nil) async throws -> RulePreset? {
    await Automatic.preset(for: try ProcessableFile(url: url), in: place, settings: settings ?? on)
  }

  func test_everythingIsOffUntilItIsTurnedOn() async throws {
    let film = try await preset(recording(at: path("a.mov")), .captures, AppSettings())
    let download = try await preset(Fixture.heic(at: path("a.heic")), .downloads, AppSettings())
    XCTAssertNil(film)
    XCTAssertNil(download)
    XCTAssertFalse(AppSettings().lighterClipboard)
  }

  func test_aScreenRecordingIsMadeLighterAndAnOrdinaryFilmIsNot() async throws {
    let film = try await preset(Fixture.video(at: path("a.mov"), seconds: 1), .captures)
    XCTAssertNil(film, "a film somebody put on the Desktop is theirs")
    let recorded = try await preset(recording(at: path("b.mov")), .captures)
    XCTAssertEqual(recorded?.onlyIfLighter, true)
  }

  func test_aPhoneFormatDownloadedBecomesAJPEG() async throws {
    let heic = try await preset(Fixture.heic(at: path("a.heic")), .downloads)
    let png = try await preset(Fixture.image(at: path("a.png")), .downloads)
    let elsewhere = try await preset(Fixture.heic(at: path("b.heic")), .captures)
    XCTAssertEqual(heic?.targetFormat, .jpeg)
    XCTAssertNil(png)
    XCTAssertNil(elsewhere)
  }

  /// The rule is kept where the file is written, before the original goes.
  func test_aHeavierResultLeavesTheOriginalWhereItIs() async throws {
    let source = try Fixture.image(at: path("tiny.png"), width: 2, height: 2), before = try Data(contentsOf: source)
    var heavier = RulePreset(name: "t", description: "", category: .image, actions: [.convertFormat(to: .tiff)])
    heavier.onlyIfLighter = true
    do {
      _ = try await coordinator().processFile(try ProcessableFile(url: source), with: heavier, destinationMode: .overwrite) { _ in }
      XCTFail("it was replaced by something heavier")
    } catch ProcessingError.leftAlone {}
    XCTAssertEqual(try Data(contentsOf: source), before)
    XCTAssertEqual(contents(of: workspace).filter { $0 != "store" }, ["tiny.png"])
    let kept = try await store.loadHistory()
    XCTAssertEqual(kept.last?.status, .skipped)
  }

  /// The ceiling a film is aimed at is not a promise: coming out over it, and
  /// not lighter, is being left alone and not a failure.
  func test_missingTheAimIsNotAFailure() async throws {
    let source = try Fixture.image(at: path("tiny.png"), width: 2, height: 2)
    var aimed = RulePreset(name: "t", description: "", category: .image, actions: [.convertFormat(to: .pdf), .limitSize(bytes: 1)])
    aimed.onlyIfLighter = true
    do {
      _ = try await coordinator().processFile(try ProcessableFile(url: source), with: aimed, destinationMode: .overwrite) { _ in }
      XCTFail()
    } catch ProcessingError.leftAlone {}
  }

  /// Every screenshot macOS takes has an alpha channel with nothing in it.
  func test_aScreenshotIsNotACutOut() throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let shot = path("shot.png")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(shot as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(shot as CFURL, nil))
    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true, "or this proves nothing")
    XCTAssertNotNil(Lighter.preset(for: try ProcessableFile(url: shot)))
  }

  /// Belongs to the run, not to the preset.
  func test_onlyIfLighterIsNotSaved() throws {
    var preset = RulePreset(name: "t", description: "", category: .image)
    preset.onlyIfLighter = true
    XCTAssertFalse(try JSONDecoder().decode(RulePreset.self, from: JSONEncoder().encode(preset)).onlyIfLighter)
  }

  func test_settingsSavedBeforeThisStillLoad() throws {
    let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"maxConcurrentNative":3}"#.utf8))
    XCTAssertEqual(old.maxConcurrentNative, 3)
    XCTAssertFalse(old.lighterRecordings || old.friendlyDownloads || old.lighterClipboard)
  }

  /// With no backup kept, an automatic run writes beside instead of replacing.
  func test_nothingIsReplacedWithoutABackup() {
    XCTAssertEqual(Automatic.mode(for: on), .overwrite)
    on.createBackupBeforeOverwrite = false
    XCTAssertEqual(Automatic.mode(for: on), .copyTo)
  }
}

/// A picture that is copied, made lighter before it is pasted.
@MainActor
final class ClipboardTests: BaseTestCase {
  /// A clipboard of the test's own: the real one is somebody's.
  private let board = NSPasteboard(name: .init("forge.tests.\(UUID().uuidString)"))
  private lazy var clipboard = ClipboardLighter(board: board, coordinator: coordinator(), folder: workspace.appendingPathComponent("clip"))

  override func tearDown() async throws { board.releaseGlobally() }

  private func picture() throws -> Data { try Data(contentsOf: Fixture.noise(at: path("shot-\(UUID().uuidString).png"), width: 600, height: 400)) }

  private func copy(_ data: Data, _ type: NSPasteboard.PasteboardType = .png, also: [NSPasteboard.PasteboardType: String] = [:]) {
    let item = NSPasteboardItem()
    item.setData(data, forType: type)
    also.forEach { item.setString($0.value, forType: $0.key) }
    board.clearContents()
    board.writeObjects([item])
  }

  func test_aCopiedPictureIsReplacedByALighterOne() async throws {
    let big = try picture()
    copy(big)
    let made = try await clipboard.check()
    XCTAssertLessThan(try XCTUnwrap(made).after, Int64(big.count))
    XCTAssertNotNil(board.data(forType: .init(UTType.jpeg.identifier)))
    XCTAssertNotNil(NSImage(pasteboard: board), "and it still pastes as a picture")
  }

  func test_itsOwnResultIsNotTakenAgain() async throws {
    copy(try picture())
    _ = try await clipboard.check()
    let count = board.changeCount
    let again = try await clipboard.check()
    XCTAssertNil(again)
    XCTAssertEqual(board.changeCount, count)
  }

  /// Words with a picture beside them are words.
  func test_textIsNeverTouched() async throws {
    copy(try picture(), also: [.string: "a table cell"])
    let count = board.changeCount
    let made = try await clipboard.check()
    XCTAssertNil(made)
    XCTAssertEqual(board.changeCount, count)
  }

  /// A password manager says what it put there is not for keeping.
  func test_whatIsMarkedPrivateIsNeverRead() async throws {
    for name in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
      copy(try picture(), also: [.init(name): ""])
      let made = try await clipboard.check()
      XCTAssertNil(made, name)
    }
  }

  func test_aPictureThatWouldBeHeavierIsLeftAsItWas() async throws {
    let tiny = try Data(contentsOf: Fixture.image(at: path("t.png"), width: 2, height: 2))
    copy(tiny)
    let made = try await clipboard.check()
    XCTAssertNil(made)
    XCTAssertEqual(board.data(forType: .png), tiny)
  }

  func test_undoPutsThePictureBack() async throws {
    let big = try picture()
    copy(big)
    let made = try await clipboard.check()
    XCTAssertTrue(clipboard.undo(try XCTUnwrap(made)))
    XCTAssertEqual(board.data(forType: .png), big)
    let again = try await clipboard.check()
    XCTAssertNil(again, "put back, it is not taken a second time")
  }

  func test_undoPutsBackEveryKindOfPictureThereWas() async throws {
    let big = try picture()
    let item = NSPasteboardItem()
    let tiff = try XCTUnwrap(NSBitmapImageRep(data: big)?.tiffRepresentation)
    item.setData(big, forType: .png)
    item.setData(tiff, forType: .tiff)
    board.clearContents()
    board.writeObjects([item])
    let made = try await clipboard.check()
    XCTAssertTrue(clipboard.undo(try XCTUnwrap(made)))
    XCTAssertEqual(board.data(forType: .png), big)
    XCTAssertEqual(board.data(forType: .tiff), tiff)
  }

  /// What was copied is not left for somebody to find.
  func test_stoppingLeavesNothingOnDisk() async throws {
    copy(try picture())
    let made = try await clipboard.check()
    XCTAssertTrue(exists(try XCTUnwrap(made).file))
    clipboard.stop()
    XCTAssertFalse(exists(try XCTUnwrap(made).file))
  }

  /// Turned off while it was working, it does not go on to finish.
  func test_turnedOffMeanwhileItChangesNothing() async throws {
    let big = try picture()
    copy(big)
    async let running = clipboard.check()
    await Task.yield()
    clipboard.stop()
    let made = try? await running
    XCTAssertNil(made ?? nil)
    XCTAssertEqual(board.data(forType: .png), big)
  }

  /// Something else has been copied since: that is what stays.
  func test_undoDoesNotTakeAwaySomethingNewer() async throws {
    copy(try picture())
    let made = try await clipboard.check()
    board.clearContents()
    board.setString("newer", forType: .string)
    XCTAssertFalse(clipboard.undo(try XCTUnwrap(made)))
    XCTAssertEqual(board.string(forType: .string), "newer")
  }

  /// A picture copied while the last one was being worked on is not lost.
  func test_aPictureCopiedMeanwhileIsNotOverwritten() async throws {
    copy(try picture())
    async let first = clipboard.check()
    try await Task.sleep(nanoseconds: 1_000_000)
    board.clearContents()
    board.setString("newer", forType: .string)
    _ = try await first
    XCTAssertEqual(board.string(forType: .string), "newer")
  }
}

/// The card in the corner.
@MainActor
final class ResultCardTests: XCTestCase {
  func test_aCardThatGoesSaysSoHoweverItGoes() {
    let center = ResultCenter(shows: false)
    var gone = 0
    let cards = (0..<4).map { _ in ResultCard(title: "t", file: URL(fileURLWithPath: "/tmp/x"), before: 2, after: 1, undo: { true }, gone: { gone += 1 }) }
    cards.forEach(center.show)
    XCTAssertEqual(center.cards.count, 3)
    XCTAssertEqual(gone, 1, "pushed out by a newer one")
    center.held.insert(cards[3].id)
    center.close(cards[3].id)
    XCTAssertEqual(gone, 2)
    XCTAssertFalse(center.held.contains(cards[3].id), "or it waits for ever for a pointer that has left")
  }

  func test_itSaysWhatWasSaved() {
    XCTAssertEqual(ResultCard.percent(from: 1000, to: 160), "−84%")
    XCTAssertEqual(ResultCard.percent(from: 3_400_000, to: 4_000), "−99%", "nothing is not what is left")
    XCTAssertNil(ResultCard.percent(from: 1000, to: 1000))
    XCTAssertNil(ResultCard.percent(from: 0, to: 10))
    XCTAssertNil(ResultCard.percent(from: 100, to: 200), "a JPEG of a HEIC can be heavier, and no saving is claimed")
  }
}
