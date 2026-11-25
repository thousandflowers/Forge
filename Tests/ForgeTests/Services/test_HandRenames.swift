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
    XCTAssertEqual(try heard(to: "x,jpg"), ["x.pdf>x,jpg"], "a comma for the dot")
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

  /// Opening the places waits for macOS to be answered: it is not done here.
  func test_startingDoesNotWaitForThePlaces_andStoppingMeanwhileHolds() async throws {
    let home = try folder("home")
    let watcher = HandRenames(hand: .init(isInFinder: { true }, idle: { 0 }))
    watcher.start(in: [home]) { _, _ in }
    XCTAssertFalse(watcher.isWatching)
    watcher.stop()
    try await Task.sleep(nanoseconds: 800_000_000)
    XCTAssertFalse(watcher.isWatching, "turned off while it was being opened")

    watcher.start(in: [home]) { _, _ in }
    for _ in 0..<40 where !watcher.isWatching { try await Task.sleep(nanoseconds: 100_000_000) }
    XCTAssertTrue(watcher.isWatching)
    watcher.stop()
    XCTAssertFalse(watcher.isWatching)
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

  // MARK: - Slips of the finger

  private func meaning(_ name: String, was before: String = "foto.pdf", _ make: (URL) throws -> URL = { try Fixture.pdf(at: $0, pages: 1) }) throws -> String {
    let home = try folder("slips-\(UUID().uuidString)"), first = try make(home.appendingPathComponent(before)), after = home.appendingPathComponent(name)
    try FileManager.default.moveItem(at: first, to: after)
    switch Retype.meant(by: after, before: before) {
    case .become(let job): return "\(job.stem).\(job.to)"
    case .stay(let job): return "= \(job.stem).\(job.from)"
    case nil: return "left"
    }
  }

  func test_aSlipIsSeenThrough() throws {
    for typed in ["jpgg", "jgp", "jpag", "jpe", "jpg ", "JPGG", "jpeeg"] {
      let meant = try meaning("foto.\(typed)").lowercased()
      XCTAssertTrue(["foto.jpg", "foto.jpeg", "foto.jpe"].contains(meant), "\(typed): \(meant)")
    }
    for (typed, meant) in [("foto.pgn", "foto.png"), ("foto.pnng", "foto.png"), ("foto.gfi", "foto.gif"), ("foto.heoc", "foto.heic"), ("foto,png", "foto.png"), ("foto.png.", "foto.png"), ("foto..png", "foto.png"), ("le mie foto.2024.pnng", "le mie foto.2024.png")] {
      XCTAssertEqual(try meaning(typed), meant, typed)
    }
  }

  func test_whatCannotBeToldIsUndone() throws {
    for typed in ["foto.xyzq", "foto.p", "foto.qqq", "foto.jpgpng"] { XCTAssertEqual(try meaning(typed), "= foto.pdf", typed) }
    // Two things a letter away: neither.
    let sound = { (url: URL) in try Fixture.audio(at: url, seconds: 1) }
    XCTAssertEqual(try meaning("a.xif", was: "a.png") { try Fixture.image(at: $0) }, "= a.png", "GIF or TIF")
    // Its own extension, badly spelt, is only a slip.
    XCTAssertEqual(try meaning("foto.pdff"), "= foto.pdf")
    // Known, and nothing it could be made into.
    XCTAssertEqual(try meaning("a.jpg", was: "a.wav", sound), "= a.wav")
  }

  func test_whatIsMeantIsLeftAlone() throws {
    XCTAssertEqual(try meaning("foto.pdf.bak"), "left")
    XCTAssertEqual(try meaning("foto"), "left")
    XCTAssertEqual(try meaning("altra.pdf"), "left")
    XCTAssertEqual(try meaning("foto.png"), "foto.png", "spelt right")
    // Words can be written under any name: that is not making them into it.
    let words = { (url: URL) -> URL in try Data("print(1)".utf8).write(to: url); return url }
    for name in ["notes.py", "notes.swift", "notes.log", "notes.js"] { XCTAssertEqual(try meaning(name, was: "notes.txt", words), "left", name) }
    XCTAssertEqual(try meaning("foto.swift"), "= foto.pdf", "a PDF is not one, whatever it is called")
  }

  func test_oneSlip() {
    for (a, b) in [("jpg", "jpgg"), ("jpg", "jp"), ("jpg", "jgp"), ("jpg", "jpf"), ("jpg", "kpg"), ("jpg", "pjg"), ("webp", "wepb")] { XCTAssertTrue(Retype.isOneSlip(a, b), "\(a) \(b)") }
    for (a, b) in [("jpg", "jpg"), ("jpg", "png"), ("jpg", "gpj"), ("jpg", "jpggg"), ("", "ab"), ("abcd", "badc")] { XCTAssertFalse(Retype.isOneSlip(a, b), "\(a) \(b)") }
  }

  /// Put back once; done again, it was meant.
  func test_whoeverInsistsIsLeftToIt() async throws {
    let model = AppModel(persistence: store)
    let home = try folder("home"), pdf = try Fixture.pdf(at: home.appendingPathComponent("foto.pdf"), pages: 1), odd = home.appendingPathComponent("foto.xyzq")
    let whole = try Data(contentsOf: pdf)
    try FileManager.default.moveItem(at: pdf, to: odd)
    await model.renamedByHand(odd, before: "foto.pdf")
    XCTAssertEqual(try Data(contentsOf: pdf), whole)
    XCTAssertFalse(exists(odd))
    try FileManager.default.moveItem(at: pdf, to: odd)
    await model.renamedByHand(odd, before: "foto.pdf")
    XCTAssertEqual(try Data(contentsOf: odd), whole)
  }

  func test_aSlipBecomesTheRealThing() async throws {
    let model = AppModel(persistence: store)
    let home = try folder("home"), pdf = try Fixture.pdf(at: home.appendingPathComponent("foto.pdf"), pages: 1), slip = home.appendingPathComponent("foto_.pnng")
    try FileManager.default.moveItem(at: pdf, to: slip)
    await model.renamedByHand(slip, before: "foto.pdf")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["foto_.png"])
    XCTAssertEqual(Signature.fits(home.appendingPathComponent("foto_.png"), "png"), true)
  }

  func test_itSaysWhyNot() throws {
    let home = try folder("home"), pdf = try Fixture.pdf(at: home.appendingPathComponent("a.pdf"), pages: 1)
    func why(_ name: String) throws -> String? {
      let after = home.appendingPathComponent(name)
      try FileManager.default.moveItem(at: pdf, to: after)
      defer { try? FileManager.default.moveItem(at: after, to: pdf) }
      guard case .stay(let job)? = Retype.meant(by: after, before: "a.pdf") else { return nil }
      return job.whyNot
    }
    XCTAssertEqual(try why("a.xyzq"), "“.xyzq” is not a format Forge knows.")
    XCTAssertEqual(try why("a.mkv"), "It cannot become MKV.")
  }
}
