import AppKit
import XCTest
@testable import Forge

final class NotchShapeTests: XCTestCase {
  private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
  private let left = NSRect(x: 0, y: 950, width: 663.5, height: 32)
  private let right = NSRect(x: 848.5, y: 950, width: 663.5, height: 32)

  func test_theNotchIsWhatTheTwoSidesLeaveOut() {
    XCTAssertEqual(
      NotchShape.cutout(in: screen, inset: 32, left: left, right: right), NSRect(x: 663.5, y: 950, width: 185, height: 32)
    )
  }

  func test_noNotch_noZone() {
    XCTAssertNil(NotchShape.cutout(in: screen, inset: 0, left: nil, right: nil))
    XCTAssertNil(NotchShape.cutout(in: screen, inset: 32, left: nil, right: right))
    XCTAssertNil(NotchShape.cutout(in: screen, inset: 32, left: .zero, right: right))
    XCTAssertNil(NotchShape.cutout(in: screen, inset: 32, left: right, right: left))
  }

  func test_aScreenThatIsNotTheFirstOne() {
    let moved = { (rect: NSRect) in rect.offsetBy(dx: -1512, dy: 300) }
    let notch = NotchShape.cutout(in: moved(screen), inset: 32, left: moved(left), right: moved(right))
    XCTAssertEqual(notch, NSRect(x: -848.5, y: 1250, width: 185, height: 32))
  }

  func test_itHangsFromTheTop_underTheMiddleOfTheNotch() throws {
    let notch = try XCTUnwrap(NotchShape.cutout(in: screen, inset: 32, left: left, right: right))
    let lip = NotchShape.lip(around: notch)
    XCTAssertEqual(lip.maxY, screen.maxY)
    XCTAssertEqual(lip.midX, notch.midX)
    XCTAssertTrue(lip.contains(notch))
    XCTAssertEqual(NotchShape.origin(of: NSSize(width: 520, height: 300), under: notch), NSPoint(x: 496, y: 682))
  }

  /// It goes back further away than it comes out, or it would flicker.
  func test_itIsKeptFurtherThanItTakesToBringItOut() throws {
    let notch = try XCTUnwrap(NotchShape.cutout(in: screen, inset: 32, left: left, right: right))
    let menu = NSRect(x: 496, y: 682, width: 520, height: 300)
    let inMenu = NSPoint(x: 520, y: 700), beside = NSPoint(x: 470, y: 700), away = NSPoint(x: 300, y: 300)
    XCTAssertTrue(NotchShape.isNear(NSPoint(x: notch.midX, y: screen.maxY), to: notch))
    XCTAssertFalse(NotchShape.isNear(inMenu, to: notch))
    XCTAssertTrue(NotchShape.keeps(inMenu, near: notch, menu: menu))
    XCTAssertTrue(NotchShape.keeps(beside, near: notch, menu: menu))
    XCTAssertFalse(NotchShape.keeps(away, near: notch, menu: menu))
    XCTAssertFalse(NotchShape.keeps(inMenu, near: notch, menu: nil))
  }
}

@MainActor
final class NotchZoneTests: BaseTestCase {
  /// Off every screen: nothing is seen while the tests run.
  private static let notch = NSRect(x: -9000, y: 9000, width: 185, height: 32)
  private let away = NSPoint(x: -9000, y: 8000)
  private let on = NSPoint(x: -8907, y: 9010)

  private final class FakeHand {
    var count = 1, holdsFiles = true, isDown = false, app: String?
    var flags: NSEvent.ModifierFlags = []
    var mouse = NSPoint.zero
    var files: [URL] = []
  }

  private let fake = FakeHand()

  private func menu(with zone: NotchZone?) -> DragMenu {
    let fake = fake
    let menu = DragMenu(hand: .init(
      changeCount: { fake.count }, files: { fake.files }, holdsFiles: { fake.holdsFiles }, mouse: { fake.mouse },
      flags: { fake.flags }, app: { fake.app }, isDown: { fake.isDown }
    ), shows: false)
    menu.notch = zone
    menu.answersKeys = false
    return menu
  }

  private func pickUp(with menu: DragMenu) {
    menu.pressed()
    fake.isDown = true
    fake.count += 1
    menu.dragged()
    menu.look()
  }

  private func settle(_ seconds: Double = 0.4) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

  func test_aDraggedFileBringsItUp_andLettingGoSendsItAway() {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    fake.mouse = away
    pickUp(with: menu)
    XCTAssertTrue(zone.isShown)
    XCTAssertNil(menu.session, "it only stands out until the file is near")
    fake.isDown = false
    menu.look()
    XCTAssertFalse(zone.isShown)
  }

  func test_theMenuComesOutNearTheNotch_andGoesBackAwayFromIt() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    fake.files = [try Fixture.image(at: path("a.png"))]
    fake.mouse = away
    pickUp(with: menu)
    try await settle()
    XCTAssertNil(menu.session)

    fake.mouse = on
    menu.look()
    try await settle()
    XCTAssertEqual(menu.session?.files.map(\.url.lastPathComponent), ["a.png"])
    XCTAssertTrue(menu.isOutOfNotch)
    XCTAssertFalse(zone.isShown, "the menu has its place")

    fake.mouse = away
    menu.look()
    XCTAssertNil(menu.session)
    XCTAssertTrue(zone.isShown)

    fake.mouse = on
    menu.look()
    try await settle()
    XCTAssertNotNil(menu.session, "and comes out again")
    fake.isDown = false
    menu.look()
    try await settle(0.9)
    XCTAssertTrue(menu.open.isEmpty)
  }

  func test_droppedOnAChoice_itIsMade() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    var made: [RulePreset] = []
    menu.convert = { file, preset in made.append(preset); return [file.url] }
    fake.files = [try Fixture.image(at: path("a.png"))]
    fake.mouse = on
    pickUp(with: menu)
    try await settle()
    let session = try XCTUnwrap(menu.session)
    let choice = try XCTUnwrap(session.choices(for: .format).first)
    fake.isDown = false
    menu.look()
    XCTAssertTrue(menu.dropped(on: .init(question: .format, answer: choice.value), of: session))
    try await settle(0.9)
    XCTAssertEqual(made.count, 1)
    XCTAssertEqual(menu.open.count, 1, "what came of it is said where it was let go")
    session.onClose()
  }

  func test_droppedBesideTheChoices_itWaitsForAClick() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    fake.files = [try Fixture.image(at: path("a.png"))]
    fake.mouse = on
    pickUp(with: menu)
    try await settle()
    let session = try XCTUnwrap(menu.session)
    fake.isDown = false
    menu.look()
    XCTAssertTrue(menu.dropped(on: nil, of: session))
    try await settle(0.9)
    XCTAssertEqual(menu.open.count, 1)
    menu.pressed()
    XCTAssertTrue(menu.open.isEmpty, "until the click is somewhere else")
  }

  func test_whatForgeCannotReadBringsNoMenuOut() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone), odd = path("notes.zzz")
    try Data("x".utf8).write(to: odd)
    fake.files = [odd]
    fake.mouse = on
    pickUp(with: menu)
    try await settle()
    XCTAssertNil(menu.session)
    fake.isDown = false
    fake.mouse = away
    menu.look()
  }

  /// One menu at a time, whichever came first.
  func test_theKeysDoNotBringASecondOne() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    menu.answersKeys = true
    fake.files = [try Fixture.image(at: path("a.png"))]
    fake.flags = .shift
    fake.mouse = away
    pickUp(with: menu)
    try await settle()
    let first = try XCTUnwrap(menu.session)
    XCTAssertFalse(menu.isOutOfNotch)
    fake.mouse = on
    menu.look()
    try await settle()
    XCTAssertTrue(menu.session === first)
    fake.mouse = away
    menu.look()
    XCTAssertTrue(menu.session === first, "the notch takes back only its own")
    fake.isDown = false
    menu.look()
    try await settle(0.9)
  }

  func test_thePanelHangsFromTheTop_andDropsLandOnItsChoices() async throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("a.png")))
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: file, convert: { _, _ in [] })
    let tiles = DropTiles(), panel = AskPanel(session: session, tiles: tiles, notch: Self.notch) {}
    defer { panel.close() }
    tiles.isLive = true
    var landed: [DropTiles.Tile?] = []
    tiles.drop = { landed.append($0); return true }
    panel.appear(takingKeys: false)
    try await settle(1)
    XCTAssertEqual(panel.frame.width, AskView.notchWidth + Hanging.shoulder * 2)
    XCTAssertEqual(panel.frame.midX, Self.notch.midX, accuracy: 0.5, "a whole point, where there are no halves")
    XCTAssertEqual(panel.frame.maxY, Self.notch.maxY)
    let (tile, place) = try XCTUnwrap(tiles.frames.first { $0.key.question == .format })
    XCTAssertGreaterThan(place.minY, Self.notch.height, "nothing to choose is behind the notch")
    for frame in tiles.frames.values { XCTAssertTrue(CGRect(origin: .zero, size: panel.frame.size).contains(frame)) }
    let held = HeldFile(at: NSPoint(x: place.midX, y: panel.frame.height - place.midY))
    XCTAssertEqual(panel.target.draggingUpdated?(held), .copy)
    XCTAssertEqual(panel.target.performDragOperation?(held), true)
    XCTAssertEqual(landed, [tile])

    let top = panel.frame.maxY, before = panel.frame.height
    session.showsMore = true
    try await settle(1.2)
    XCTAssertGreaterThan(panel.frame.height, before)
    XCTAssertEqual(panel.frame.maxY, top, "it grows downwards")
  }

  func test_moreToARowInTheNotch() {
    let notch = { AskView.columns(for: $0, shapes: [6, 3], in: AskView.notchWidth) }
    XCTAssertEqual(notch(["JPEG", "HEIC", "WEBP"]), 6)
    XCTAssertEqual(notch(["Make lighter", "Instagram Square"]), 3)
  }

  func test_whatIsNotAFileDoesNot() {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    fake.holdsFiles = false
    pickUp(with: menu)
    XCTAssertFalse(zone.isShown)
    fake.isDown = false
    menu.look()
  }

  func test_noNotch_nothingComesUp() {
    let zone = NotchZone(find: { nil }), menu = menu(with: zone)
    pickUp(with: menu)
    XCTAssertFalse(zone.isShown)
    fake.isDown = false
    menu.look()
  }

  /// The button is up before macOS delivers the drop.
  func test_letGoOnIt_itWaitsForTheDrop() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    fake.mouse = on
    pickUp(with: menu)
    fake.isDown = false
    menu.look()
    XCTAssertTrue(zone.isShown)
    try await Task.sleep(nanoseconds: 900_000_000)
    XCTAssertFalse(zone.isShown, "nothing was dropped after all")
  }

  func test_filesLetGoOnItAreTaken_onceAndOnlyFiles() throws {
    let zone = NotchZone(find: { Self.notch }), file = try Fixture.image(at: path("a.png"))
    var taken: [URL] = []
    zone.take = { taken += $0 }
    zone.began()
    let target = try XCTUnwrap(zone.target)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.writeObjects(["words" as NSString])
    XCTAssertEqual(target.performDragOperation?(HeldFile(at: .zero, on: pasteboard)), false)

    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])
    let held = HeldFile(at: .zero, on: pasteboard)
    XCTAssertEqual(target.draggingEntered?(held), .copy, "never a move")
    XCTAssertEqual(target.performDragOperation?(held), true)
    XCTAssertEqual(taken.map(\.lastPathComponent), ["a.png"])
    XCTAssertFalse(zone.isShown)
    XCTAssertEqual(target.performDragOperation?(held), false, "it is over")
    XCTAssertEqual(taken.count, 1)
  }

  func test_theNextDragKeepsIt() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    fake.mouse = on
    pickUp(with: menu)
    fake.isDown = false
    menu.look()
    pickUp(with: menu)
    try await Task.sleep(nanoseconds: 900_000_000)
    XCTAssertTrue(zone.isShown)
    fake.mouse = away
    fake.isDown = false
    menu.look()
  }

  func test_theKeysDoNothingWhereOnlyTheNotchIsOn() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    fake.files = [try Fixture.image(at: path("a.png"))]
    fake.flags = .shift
    pickUp(with: menu)
    try await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertNil(menu.session)
    fake.isDown = false
    menu.look()
  }

  /// They are kept out of because of the keys, and the notch needs none.
  func test_anAppTheKeysKeepOutOfStillHasTheNotch() async throws {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    menu.answersKeys = true
    menu.ignored = ["com.apple.finder"]
    fake.app = "com.apple.finder"
    fake.files = [try Fixture.image(at: path("a.png"))]
    fake.flags = .shift
    pickUp(with: menu)
    try await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertTrue(zone.isShown)
    XCTAssertNil(menu.session)
    fake.isDown = false
    menu.look()
  }

  func test_offUntilSomebodyTurnsItOn_andKept() throws {
    var settings = AppSettings()
    XCTAssertFalse(settings.notchZone)
    settings.notchZone = true
    XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).notchZone)
    XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).notchZone)
  }
}
