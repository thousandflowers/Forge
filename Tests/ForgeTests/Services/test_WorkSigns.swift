import XCTest
@testable import Forge

@MainActor
final class WorkSignsTests: BaseTestCase {
  private let file = URL(fileURLWithPath: "/tmp/photo_gray.jpg")

  private func signs(_ place: AppSettings.WorkSign = .both, notch: Bool = true, still: Bool = false) -> WorkSigns {
    let signs = WorkSigns(times: .init(least: 0.2, between: 0.6, done: 1.5, failed: 1.5), hasNotch: { notch }, isStill: { still })
    signs.place = place
    return signs
  }

  private func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

  /// Until it is so, however slow the Mac is today.
  private func until(_ what: String, _ isSo: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let start = Date()
    while !isSo() {
      guard Date().timeIntervalSince(start) < 15 else { return XCTFail(what, file: file, line: line) }
      try await wait(0.01)
    }
  }

  private func said(_ signs: WorkSigns) -> WorkSigns.Word? { if case .said(let word) = signs.state { return word } else { return nil } }

  func test_fromBeginningToEnd() async throws {
    let signs = signs(), id = UUID()
    XCTAssertEqual(signs.state, .resting)
    signs.hear(.began(id, file))
    XCTAssertEqual(signs.state, .working(0))
    signs.hear(.reached(id, 0.5))
    signs.hear(.reached(id, 0.2))
    XCTAssertEqual(signs.state, .working(0.5), "never backwards")
    signs.hear(.ended(id, .done("Black and white")))
    try await until("a word") { said(signs) != nil }
    XCTAssertEqual(said(signs), .init(kind: .done, title: "Black and white", detail: "photo_gray.jpg"))
    XCTAssertEqual(signs.hammer, .said(.done))
    try await until("rest") { signs.state == .resting }
    XCTAssertEqual(signs.hammer, .still)
  }

  func test_oneAfterAnotherIsOneThing() async throws {
    let signs = signs()
    for _ in 0..<3 {
      let id = UUID()
      signs.hear(.began(id, file))
      signs.hear(.ended(id, .done("Mono")))
      XCTAssertNil(said(signs))
    }
    try await until("a word") { said(signs) != nil }
    XCTAssertEqual(said(signs)?.detail, "3 files")
    XCTAssertEqual(said(signs)?.title, "Mono")
  }

  func test_aNewOneTakesThePlaceOfWhatWasSaid() async throws {
    let signs = signs(), one = UUID(), two = UUID()
    signs.hear(.began(one, file))
    signs.hear(.ended(one, .failed("No.")))
    try await until("a word") { said(signs) != nil }
    XCTAssertEqual(said(signs)?.kind, .failed)
    signs.hear(.began(two, file))
    try await wait(2)
    XCTAssertEqual(signs.state, .working(0), "the old word does not put the new work to rest")
    signs.hear(.ended(two, .done("Mono")))
    try await until("a word") { said(signs) != nil }
    XCTAssertEqual(said(signs)?.kind, .done, "and is not counted with it")
  }

  func test_whatIsSaid() {
    func word(_ outcomes: [Running.Outcome]) -> WorkSigns.Word? { WorkSigns.word(for: outcomes.map { (file, $0) }) }
    XCTAssertNil(word([.quiet]))
    XCTAssertEqual(word([.done("A"), .done("B")])?.title, "Converted")
    XCTAssertEqual(word([.done("A"), .failed("why")]), .init(kind: .failed, title: "1 of 2 not converted", detail: "why"))
    XCTAssertEqual(word([.leftAlone("It has no password.")]), .init(kind: .leftAlone, title: "Left as it is", detail: "It has no password."))
    XCTAssertEqual(word([.quiet, .done("A")])?.title, "A")
  }

  func test_whereItIsShown() {
    XCTAssertTrue(AppSettings.WorkSign.notch.showsHammer(hasNotch: false), "a Mac without one still says so")
    XCTAssertFalse(AppSettings.WorkSign.notch.showsHammer(hasNotch: true))
    XCTAssertFalse(AppSettings.WorkSign.both.showsNotch(hasNotch: false))
    XCTAssertFalse(AppSettings.WorkSign.nowhere.showsHammer(hasNotch: false))
    XCTAssertEqual(AppSettings.WorkSign.notch.shown(hasNotch: false), .menuBar)
    XCTAssertEqual(AppSettings.WorkSign.nowhere.shown(hasNotch: false), .nowhere)
    XCTAssertEqual(AppSettings.WorkSign.both.shown(hasNotch: true), .both)
    for place in AppSettings.WorkSign.allCases {
      XCTAssertTrue(AppSettings.WorkSign.choices(hasNotch: false).contains(place.shown(hasNotch: false)), "\(place)")
    }
    let only = signs(.notch)
    only.hear(.began(UUID(), file))
    XCTAssertEqual(only.hammer, .still)
    let nowhere = signs(.nowhere)
    nowhere.hear(.began(UUID(), file))
    XCTAssertEqual(nowhere.state, .resting)
  }

  func test_turnedOffHalfWay() async throws {
    let signs = signs(), id = UUID()
    signs.hear(.began(id, file))
    signs.place = .nowhere
    XCTAssertEqual(signs.state, .resting)
    XCTAssertEqual(signs.hammer, .still)
    signs.place = .both
    signs.hear(.ended(id, .done("Mono")))
    XCTAssertEqual(signs.state, .resting)
  }

  func test_whoeverWantsNothingToMove() async throws {
    let signs = signs(still: true)
    signs.hear(.began(UUID(), file))
    try await wait(0.1)
    XCTAssertEqual(signs.hammer, .striking(0))
    let moving = self.signs()
    moving.hear(.began(UUID(), file))
    try await until("a blow") { if case .striking(let frame) = moving.hammer { return frame > 0 } else { return false } }
  }

  func test_theBlow() {
    XCTAssertEqual(Blow.angle(at: 0), 0)
    XCTAssertEqual(Blow.angle(at: Blow.seconds * 0.42), 30, accuracy: 0.5)
    XCTAssertEqual(Blow.angle(at: Blow.seconds * 0.5399), -16, accuracy: 0.5)
    XCTAssertEqual(Blow.angle(at: Blow.seconds), Blow.angle(at: 0), accuracy: 0.001)
    XCTAssertNil(Blow.sparks(at: 0))
    XCTAssertNotNil(Blow.sparks(at: Blow.seconds * 0.6))
  }

  func test_aRealConversionSaysWhatItDid() async throws {
    var outcomes: [Running.Outcome] = []
    let coordinator = coordinator(), running = Running()
    running.heard = { if case .ended(_, let outcome) = $0 { outcomes.append(outcome) } }
    let listening = Task { await running.listen(to: coordinator) }
    defer { listening.cancel() }
    // Once it is listening, and not before.
    try await wait(0.5)
    func run(_ url: URL, named: Bool = true, _ actions: [Forge.Operation] = []) async throws {
      var preset = RulePreset(name: "From its name", description: "", category: .custom, actions: actions)
      preset.readsTools = named
      _ = try? await coordinator.processFile(try ProcessableFile(url: url), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
    }
    try await run(try Fixture.image(at: path("a_gray.png")))
    try await run(try Fixture.image(at: path("b.png")), [.convertFormat(to: .jpeg)])
    try await run(try Fixture.image(at: path("c_scan.png")))
    try await run(try Fixture.pdf(at: path("d_unlock.pdf"), pages: 1))
    try await until("all four") { outcomes.count == 4 }
    guard outcomes.count == 4 else { return XCTFail("\(outcomes)") }
    XCTAssertEqual(outcomes[0], .done("Black and white"))
    XCTAssertEqual(outcomes[1], .done("JPEG"))
    if case .failed = outcomes[2] {} else { XCTFail("\(outcomes[2])") }
    XCTAssertEqual(outcomes[3], .leftAlone("It has no password."))
  }

  func test_theChoiceIsKept() throws {
    var settings = AppSettings()
    XCTAssertEqual(settings.workSign, .notch)
    XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).workSign, .notch, "settings from before there was a choice")
    settings.workSign = .both
    XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).workSign, .both)
  }
}
