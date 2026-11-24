import AppKit
import XCTest
@testable import Forge

final class HoldKeysTests: XCTestCase {
  func test_exactlyTheKeysChosen() {
    XCTAssertTrue(HoldKeys.shift.areHeld(.shift))
    XCTAssertTrue(HoldKeys.shift.areHeld([.shift, .capsLock]), "Caps Lock is not being held")
    XCTAssertFalse(HoldKeys.shift.areHeld([.shift, .command]), "somebody else's shortcut")
    XCTAssertFalse(HoldKeys.shift.areHeld([]))
    XCTAssertTrue(HoldKeys([.control, .option]).areHeld([.control, .option]))
    XCTAssertFalse(HoldKeys([]).areHeld([]), "no key is not every drag")
  }

  func test_theLastKeyStays() {
    XCTAssertEqual(HoldKeys.shift.toggling(.shift), .shift)
    XCTAssertEqual(HoldKeys.shift.toggling(.option), [.shift, .option])
    XCTAssertEqual(HoldKeys([.shift, .option]).toggling(.shift), .option)
  }

  func test_settingsKeepTheKeys_andOldOnesAreReadWithShift() throws {
    var settings = AppSettings()
    XCTAssertFalse(settings.dragMenu, "off until somebody turns it on")
    settings.dragMenu = true
    settings.dragMenuKeys = [.control, .option]
    let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(back, settings)
    let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(old.dragMenuKeys, .shift)
    XCTAssertFalse(old.dragMenu)
    let strange = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"dragMenuKeys":0}"#.utf8))
    XCTAssertEqual(strange.dragMenuKeys, .shift)
  }
}

@MainActor
final class DragMenuTests: BaseTestCase {
  private final class FakeHand {
    var count = 1
    var files: [URL] = []
    var flags: NSEvent.ModifierFlags = []
    var isDown = false
  }

  private let fake = FakeHand()

  private func menu() -> DragMenu {
    let fake = fake
    return DragMenu(hand: .init(
      changeCount: { fake.count }, files: { fake.files }, flags: { fake.flags }, isDown: { fake.isDown }
    ), shows: false)
  }

  /// Pick something up, as the Finder does it.
  private func pickUp(_ files: [URL], with menu: DragMenu) {
    menu.pressed()
    fake.isDown = true
    fake.count += 1
    fake.files = files
    menu.dragged()
  }

  private func settle(_ seconds: Double = 0.4) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

  func test_theKeyBringsTheMenuUp_andOnlyTheKey() async throws {
    let menu = menu(), file = try Fixture.image(at: path("a.png"))
    pickUp([file], with: menu)
    try await settle()
    XCTAssertNil(menu.session, "dragging alone is nobody's business")
    fake.flags = .shift
    try await settle()
    XCTAssertEqual(menu.session?.files.map(\.url.lastPathComponent), ["a.png"])
    fake.flags = []
    try await settle()
    XCTAssertNotNil(menu.session, "the key can be let go once it is up")
  }

  /// The pasteboard still holds the last drag when text is selected with ⇧.
  func test_anOldDragIsNotANewOne() async throws {
    let menu = menu()
    fake.files = [try Fixture.image(at: path("old.png"))]
    fake.count += 5
    fake.flags = .shift
    fake.isDown = true
    menu.pressed()
    menu.dragged()
    try await settle()
    XCTAssertNil(menu.session)
  }

  func test_whatForgeCannotReadBringsNothingUp() async throws {
    let menu = menu(), odd = path("notes.zzz")
    try Data("x".utf8).write(to: odd)
    fake.flags = .shift
    pickUp([odd], with: menu)
    try await settle()
    XCTAssertNil(menu.session)
    XCTAssertTrue(menu.isWatching)
    fake.isDown = false
    try await settle()
    XCTAssertFalse(menu.isWatching, "nothing is looked at between drags")
  }

  func test_letGoElsewhere_itGoes() async throws {
    let menu = menu()
    fake.flags = .shift
    pickUp([try Fixture.image(at: path("a.png"))], with: menu)
    try await settle()
    XCTAssertNotNil(menu.session)
    fake.isDown = false
    try await settle(1.2)
    XCTAssertNil(menu.session)
  }

  func test_droppedOnAChoice_convertsToIt() async throws {
    let menu = menu()
    var asked: [RulePreset] = []
    menu.convert = { file, preset in asked.append(preset); return [file.url] }
    fake.flags = .shift
    pickUp([try Fixture.image(at: path("a.png")), try Fixture.image(at: path("b.png"))], with: menu)
    try await settle()
    let session = try XCTUnwrap(menu.session)
    fake.isDown = false // up before the drop is delivered
    try await settle(0.2)
    XCTAssertTrue(menu.dropped(on: .init(question: .format, answer: .format(.jpeg)), of: session))
    try await settle()
    XCTAssertEqual(asked.map(\.actions), [[.convertFormat(to: .jpeg)], [.convertFormat(to: .jpeg)]])
    guard case .done(let outputs) = session.state else { return XCTFail("\(session.state)") }
    XCTAssertEqual(outputs.count, 2)
  }

  func test_droppedOnTheMenu_waitsForAClick() async throws {
    let menu = menu()
    fake.flags = .shift
    pickUp([try Fixture.image(at: path("a.png"))], with: menu)
    try await settle()
    let session = try XCTUnwrap(menu.session)
    XCTAssertTrue(menu.dropped(on: nil, of: session))
    fake.isDown = false
    try await settle(1)
    guard case .asking = session.state else { return XCTFail("\(session.state)") }
    XCTAssertFalse(menu.dropped(on: nil, of: session), "a later drag is not about these files")
  }

  func test_leftWaiting_itGoesWithAClickElsewhere() async throws {
    let menu = menu()
    fake.flags = .shift
    pickUp([try Fixture.image(at: path("a.png"))], with: menu)
    try await settle()
    let session = try XCTUnwrap(menu.session)
    XCTAssertTrue(menu.dropped(on: nil, of: session))
    fake.isDown = false
    try await settle(1)
    XCTAssertEqual(menu.open.count, 1)
    menu.pressed()
    XCTAssertEqual(menu.open.count, 0)
  }

  /// Stopping a conversion is said with the ✕, not by clicking on something.
  func test_aClickElsewhereStopsNothingThatIsRunning() async throws {
    let menu = menu()
    var finished = false
    menu.convert = { file, _ in try await Task.sleep(nanoseconds: 600_000_000); finished = true; return [file.url] }
    fake.flags = .shift
    pickUp([try Fixture.image(at: path("a.png"))], with: menu)
    try await settle()
    let session = try XCTUnwrap(menu.session)
    XCTAssertTrue(menu.dropped(on: .init(question: .format, answer: .format(.jpeg)), of: session))
    fake.isDown = false
    try await settle(0.2)
    menu.pressed()
    XCTAssertEqual(menu.open.count, 1)
    try await settle(0.8)
    XCTAssertTrue(finished)
    menu.pressed()
    XCTAssertEqual(menu.open.count, 0)
  }

  func test_kindsThatDoNotMixSaySo() async throws {
    let menu = menu(), text = path("a.txt")
    try Data("x".utf8).write(to: text)
    fake.flags = .shift
    pickUp([try Fixture.image(at: path("a.png")), text], with: menu)
    try await settle()
    XCTAssertEqual(menu.session?.isMixed, true)
    XCTAssertEqual(menu.session?.questions, [])
  }

  func test_neverAMoveOrADelete() {
    XCTAssertEqual(DropTiles.operation(of: [.copy, .move, .delete]), .copy)
    XCTAssertEqual(DropTiles.operation(of: [.generic, .move]), .generic)
    XCTAssertEqual(DropTiles.operation(of: .link), .link)
    XCTAssertEqual(DropTiles.operation(of: [.move, .delete]), [])
  }

  func test_theChoiceUnderTheFile() {
    let tiles = DropTiles(), jpeg = DropTiles.Tile(question: .format, answer: .format(.jpeg))
    tiles.frames[jpeg] = CGRect(x: 10, y: 10, width: 50, height: 20)
    tiles.move(to: CGPoint(x: 20, y: 15))
    XCTAssertEqual(tiles.over, jpeg)
    tiles.move(to: CGPoint(x: 62, y: 15))
    XCTAssertEqual(tiles.over, jpeg, "in the gap beside it")
    tiles.move(to: CGPoint(x: 5, y: 5))
    XCTAssertNil(tiles.over)
    tiles.move(to: nil)
    XCTAssertNil(tiles.over)
  }
}

/// The menu itself, laid out as it is on screen.
@MainActor
final class DragMenuLayoutTests: BaseTestCase {
  func test_everyChoiceCanBeDroppedOn() async throws {
    let file = try ProcessableFile(url: Fixture.image(at: path("big.png"), width: 2400, height: 1600))
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: file, convert: { _, _ in [] })
    let tiles = DropTiles()
    tiles.isLive = true
    let panel = AskPanel(session: session, tiles: tiles) {}
    panel.appear(takingKeys: false)
    defer { panel.close() }
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let wanted = session.questions.flatMap { question in session.choices(for: question).map { DropTiles.Tile(question: question, answer: $0.value) } }
    XCTAssertEqual(Set(wanted), Set(tiles.frames.keys))
  }

  /// Anywhere on the screen, letting go at once is letting go outside it.
  func test_itNeverComesUpUnderThePointer() {
    let screen = NSRect(x: 0, y: 0, width: 1470, height: 890), size = NSSize(width: 400, height: 476)
    for x in stride(from: 0.0, through: 1470, by: 35) {
      for y in stride(from: 0.0, through: 890, by: 35) {
        let mouse = NSPoint(x: x, y: y)
        let frame = NSRect(origin: AskPanel.origin(for: size, at: mouse, in: screen), size: size)
        XCTAssertFalse(frame.contains(mouse), "\(mouse)")
        XCTAssertTrue(screen.contains(frame), "\(mouse)")
      }
    }
  }

  func test_aFileHeldOverAChoice_thenDropped() async throws {
    let file = try ProcessableFile(url: Fixture.image(at: path("big.png"), width: 2400, height: 1600))
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: file, convert: { _, _ in [] })
    let tiles = DropTiles(), jpeg = DropTiles.Tile(question: .format, answer: .format(.jpeg))
    tiles.isLive = true
    var landed: [DropTiles.Tile?] = []
    tiles.drop = { landed.append($0); return true }
    let panel = AskPanel(session: session, tiles: tiles) {}
    panel.appear(takingKeys: false)
    defer { panel.close() }
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let place = try XCTUnwrap(tiles.frames[jpeg])
    let held = HeldFile(at: NSPoint(x: place.midX, y: panel.frame.height - place.midY))
    XCTAssertEqual(panel.target.draggingUpdated?(held), .copy)
    XCTAssertEqual(tiles.over, jpeg)
    XCTAssertEqual(panel.target.performDragOperation?(held), true)
    XCTAssertEqual(landed, [jpeg])
    XCTAssertNil(tiles.over)
  }
}

private final class HeldFile: NSObject, NSDraggingInfo {
  let draggingLocation: NSPoint
  init(at point: NSPoint) { draggingLocation = point }
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .delete] }
  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingPasteboard: NSPasteboard { NSPasteboard(name: .drag) }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
  func resetSpringLoading() {}
}
