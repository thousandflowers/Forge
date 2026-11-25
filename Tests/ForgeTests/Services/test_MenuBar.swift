import XCTest
@testable import Forge

@MainActor
final class RunningTests: BaseTestCase {
  func test_whatIsBeingMade_fromBeginningToEnd() async throws {
    let running = Running(), id = UUID(), file = path("a.png")
    var told = 0
    running.ended = { told += 1 }
    running.hear(.began(id, file))
    running.hear(.began(id, file))
    XCTAssertEqual(running.jobs.map(\.file), [file])
    running.hear(.reached(id, 0.5))
    running.hear(.reached(id, 0.505))
    running.hear(.reached(id, 0.2))
    XCTAssertEqual(running.jobs.first?.fraction, 0.5, "it neither goes back nor fidgets")
    running.hear(.reached(UUID(), 0.9))
    running.hear(.ended(id))
    XCTAssertTrue(running.jobs.isEmpty)
    running.hear(.began(id, file))
    running.hear(.ended(id))
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(told, 1, "once for all that ended together")
  }

  func test_aRealConversionIsSeen_andOneThatFailsLeaves() async throws {
    let coordinator = ProcessingCoordinator(settings: AppSettings(), persistence: PersistenceManager(root: try folder("store")))
    let running = Running()
    let listening = Task { await running.listen(to: coordinator) }
    defer { listening.cancel() }
    try await Task.sleep(nanoseconds: 100_000_000)
    var seen: Set<URL> = []
    let watching = running.$jobs.sink { seen.formUnion($0.map(\.file)) }
    defer { watching.cancel() }
    let good = try ProcessableFile(url: try Fixture.image(at: path("a.png")))
    let preset = RulePreset(name: "J", description: "", category: .custom, actions: [.convertFormat(to: .jpeg)])
    _ = try await coordinator.processFile(good, with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
    let broken = path("b.png")
    try Data("no".utf8).write(to: broken)
    if let bad = try? ProcessableFile(url: broken) {
      _ = try? await coordinator.processFile(bad, with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertTrue(seen.contains(good.url))
    XCTAssertTrue(running.jobs.isEmpty)
  }
}

final class RecentTests: BaseTestCase {
  private func write(_ name: String, _ bytes: Int) throws -> URL {
    let url = path(name)
    try Data(count: bytes).write(to: url)
    return url
  }

  private func entry(_ file: URL, to output: URL?, backup: URL? = nil, status: ProcessingStatus = .completed) -> ProcessingHistory {
    ProcessingHistory(
      fileURL: file, status: status, duration: 1, outputURL: output,
      destinationFolder: backup == nil ? file.deletingLastPathComponent() : nil, backupURL: backup
    )
  }

  func test_whatItWasAndWhatItCameTo() throws {
    var made = entry(try write("a.png", 1000), to: try write("a.jpg", 300))
    made.additionalOutputs = [try write("a.webp", 200)]
    let recent = Recent(made)
    XCTAssertEqual(recent.before, 1000)
    XCTAssertEqual(recent.after, 500)
    XCTAssertEqual(recent.outputs.count, 2)
    XCTAssertTrue(recent.canUndo)
  }

  func test_replacedInPlace_itIsWeighedAgainstItsBackup() throws {
    let file = try write("a.jpg", 300)
    XCTAssertEqual(Recent(entry(file, to: file, backup: try write("backup.jpg", 1000))).before, 1000)
    XCTAssertNil(Recent(entry(file, to: file)).before, "not against itself")
  }

  func test_whatIsGoneIsNotOffered() throws {
    let file = try write("a.png", 1000)
    let recent = Recent(entry(file, to: path("gone.jpg")))
    XCTAssertTrue(recent.outputs.isEmpty)
    XCTAssertNil(recent.after)
    XCTAssertFalse(recent.canUndo)
    var undone = entry(file, to: try write("a.jpg", 10))
    undone.undoneAt = Date()
    XCTAssertTrue(Recent(undone).outputs.isEmpty)
  }

  func test_theLastSix_withoutWhatWasLeftAlone() throws {
    let file = path("a.png")
    let history = [ProcessingStatus.skipped, .completed, .cancelled, .failed].map { entry(file, to: nil, status: $0) }
      + (0..<9).map { _ in entry(file, to: nil) }
    let shown = Recent.entries(of: history)
    XCTAssertEqual(shown.count, Recent.most)
    XCTAssertEqual(shown.prefix(2).map(\.status), [.completed, .failed])
  }
}
