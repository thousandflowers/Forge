import XCTest
@testable import Forge

@MainActor
final class HandRenamesTests: BaseTestCase {
  private typealias Event = RenamePairs.Event

  func test_theTwoHalvesAreOneRename() {
    var pairs = RenamePairs()
    XCTAssertNil(pairs.take(Event(path: "/a/x.pdf", file: 7)))
    XCTAssertNil(pairs.take(Event(path: "/a/y.pdf", file: 8)))
    let first = pairs.take(Event(path: "/a/x.jpg", file: 7)), second = pairs.take(Event(path: "/a/y.jpg", file: 8))
    XCTAssertEqual([first?.before, first?.after, second?.before, second?.after], ["/a/x.pdf", "/a/x.jpg", "/a/y.pdf", "/a/y.jpg"])
    XCTAssertNil(pairs.take(Event(path: "/a/x.jpg", file: 7)), "a half on its own")
  }

  private func heard(inFinder: Bool = true, idle: TimeInterval = 0.5, from: String = "x.pdf", to: String = "x.jpg", in folder: String? = nil) throws -> [String] {
    let home = try self.folder("home"), place = folder.map { home.appendingPathComponent($0) } ?? home
    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
    let watcher = HandRenames(hand: .init(isInFinder: { inFinder }, idle: { idle }))
    var got: [String] = []
    watcher.start(in: [home]) { url, before in got.append("\(before)>\(url.lastPathComponent)") }
    defer { watcher.stop() }
    let root = HandRenames.real(place).path
    watcher.heard([Event(path: "\(root)/\(from)", file: 1), Event(path: "\(root)/\(to)", file: 1)])
    return got
  }

  func test_byHandIsInTheFinder_withAKeyJustPressed() throws {
    XCTAssertEqual(try heard(), ["x.pdf>x.jpg"])
    XCTAssertEqual(try heard(inFinder: false), [], "a program's")
    XCTAssertEqual(try heard(idle: 30), [], "nobody is there")
  }

  func test_onlyAnotherKind_andOnlyWhereItIs() throws {
    XCTAssertEqual(try heard(to: "y.pdf"), [])
    XCTAssertEqual(try heard(to: "x.PDF"), [])
    XCTAssertEqual(try heard(to: "x"), [])
    XCTAssertEqual(try heard(from: "x"), [])
    XCTAssertEqual(try heard(to: "sub/x.jpg"), [], "put away")
    XCTAssertEqual(try heard(from: "x.part", to: "x.jpg"), ["x.part>x.jpg"], "what is in it is for others to say")
  }

  func test_whatIsPartOfSomethingIsLeftAlone() throws {
    XCTAssertEqual(try heard(in: "trip"), ["x.pdf>x.jpg"])
    XCTAssertEqual(try heard(in: ".hidden"), [])
    XCTAssertEqual(try heard(from: ".x.pdf", to: ".x.jpg"), [])
    XCTAssertEqual(try heard(in: "site/node_modules/a"), [])
    XCTAssertEqual(try heard(in: "Photos Library.photoslibrary/originals"), [])
    XCTAssertEqual(try heard(in: "Some.app/Contents"), [])
    let project = try folder("home").appendingPathComponent("code/.git")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    XCTAssertEqual(try heard(in: "code/src"), [])
  }

  /// The system's own word for it, from a real rename by another program.
  func test_aRealRenameIsHeard() async throws {
    let home = try folder("home"), file = home.appendingPathComponent("a.pdf")
    try Data("x".utf8).write(to: file)
    try await Task.sleep(nanoseconds: 500_000_000)
    let watcher = HandRenames(hand: .init(isInFinder: { true }, idle: { 0 }))
    var got: [String] = []
    watcher.start(in: [home]) { url, before in got.append("\(before)>\(url.lastPathComponent)") }
    defer { watcher.stop() }
    try await Task.sleep(nanoseconds: 500_000_000)
    // By this process it is Forge's own, and not listened to.
    try FileManager.default.moveItem(at: file, to: home.appendingPathComponent("b.jpg"))
    try await Task.sleep(nanoseconds: 800_000_000)
    XCTAssertEqual(got, [])
    let mover = Process()
    mover.executableURL = URL(fileURLWithPath: "/bin/mv")
    mover.arguments = [home.appendingPathComponent("b.jpg").path, home.appendingPathComponent("c.png").path]
    try mover.run()
    for _ in 0..<40 where got.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
    XCTAssertEqual(got, ["b.jpg>c.png"])
  }

  func test_itIsOffUntilItIsTurnedOn() throws {
    XCTAssertFalse(AppSettings().convertsRenames)
    var on = AppSettings()
    on.convertsRenames = true
    let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(on))
    XCTAssertTrue(back.convertsRenames)
    XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).convertsRenames)
  }

  func test_renamedByHand_itBecomesWhatItIsCalled_once() async throws {
    let model = AppModel(persistence: store)
    let home = try folder("home"), pdf = try Fixture.pdf(at: home.appendingPathComponent("foto.pdf"), pages: 1), jpg = home.appendingPathComponent("foto.jpg")
    try FileManager.default.moveItem(at: pdf, to: jpg)
    await model.renamedByHand(jpg, before: "foto.pdf")
    XCTAssertEqual(Signature.fits(jpg, "jpg"), true)
    XCTAssertFalse(exists(pdf), "it is kept in Backups")
    await model.renamedByHand(jpg, before: "foto.pdf")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["foto.jpg"])
    XCTAssertNil(model.lastError)
  }
}
