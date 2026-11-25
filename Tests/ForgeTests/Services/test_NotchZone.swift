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
    let open = NotchShape.open(around: notch)
    XCTAssertEqual(open.maxY, screen.maxY)
    XCTAssertEqual(open.midX, notch.midX)
    XCTAssertTrue(open.contains(notch))
  }

  /// The panel is there, unseen, at its full size: it must be open by the time
  /// a file is over it.
  func test_aFileIsNeverOverItWhileItIsClosed() throws {
    let notch = try XCTUnwrap(NotchShape.cutout(in: screen, inset: 32, left: left, right: right))
    let open = NotchShape.open(around: notch)
    for corner in [NSPoint(x: open.minX, y: open.minY), NSPoint(x: open.maxX, y: open.minY), NSPoint(x: notch.midX, y: screen.maxY)] {
      XCTAssertTrue(NotchShape.isNear(corner, to: notch))
    }
    XCTAssertFalse(NotchShape.isNear(NSPoint(x: 756, y: 400), to: notch))
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

  func test_aDraggedFileBringsItUp_andLettingGoSendsItAway() {
    let zone = NotchZone(find: { Self.notch }), menu = menu(with: zone)
    fake.mouse = away
    pickUp(with: menu)
    XCTAssertTrue(zone.isShown)
    XCTAssertFalse(zone.isOpen)
    fake.mouse = on
    menu.look()
    XCTAssertTrue(zone.isOpen)
    fake.mouse = away
    menu.look()
    XCTAssertFalse(zone.isOpen)
    fake.isDown = false
    menu.look()
    XCTAssertFalse(zone.isShown)
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
    zone.began(at: on)
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
