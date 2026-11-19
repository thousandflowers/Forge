import XCTest
@testable import Forge

/// The watcher decides what counts as "a new file has arrived".
final class MonitoredFolderWatcherTests: BaseTestCase {

  /// A file copied into a watched folder must reach the handler once it has
  /// stopped growing.
  func test_reportsAFileCopiedIn() async throws {
    let watched = try folder("watched")
    let seen = Collector()

    let watcher = MonitoredFolderWatcher()
    try watcher.startWatching(
      folder: MonitoredFolder(url: watched, ruleId: UUID(), destinationMode: .copyTo)
    ) { url in await seen.add(url) }
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    try Fixture.image(at: watched.appendingPathComponent("arrived.png"), width: 64, height: 64)

    let names = try await seen.wait(for: 1, timeout: 10)
    XCTAssertEqual(names.map(\.lastPathComponent), ["arrived.png"])
  }

  /// Forge's own scratch files start with a dot and must never come back round.
  func test_ignoresDotFiles() async throws {
    let watched = try folder("watched")
    let seen = Collector()

    let watcher = MonitoredFolderWatcher()
    try watcher.startWatching(
      folder: MonitoredFolder(url: watched, ruleId: UUID(), destinationMode: .copyTo)
    ) { url in await seen.add(url) }
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    try Fixture.image(at: watched.appendingPathComponent(".forge-scratch.png"), width: 32, height: 32)
    try Fixture.image(at: watched.appendingPathComponent("real.png"), width: 32, height: 32)

    let names = try await seen.wait(for: 1, timeout: 10)
    XCTAssertEqual(names.map(\.lastPathComponent), ["real.png"])
  }

  /// A copy that stalls - a network share, a slow download - stops growing for
  /// longer than the settle interval while it is still being written. Size
  /// alone handed over half a picture; a writer still holding the file open
  /// is the other half of "finished".
  func test_waitsForAWriterThatHoldsTheFileOpen() async throws {
    let watched = try folder("watched")
    let seen = Collector()

    let watcher = MonitoredFolderWatcher()
    try watcher.startWatching(
      folder: MonitoredFolder(url: watched, ruleId: UUID(), destinationMode: .copyTo)
    ) { url in await seen.add(url) }
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    let target = watched.appendingPathComponent("stalled.png")
    let writer = Process()
    writer.executableURL = URL(fileURLWithPath: "/bin/sh")
    writer.arguments = ["-c", "exec 3>\"$0\"; printf x >&3; sleep 3", target.path]
    try writer.run()

    let early = try await seen.wait(for: 1, timeout: 2.5)
    XCTAssertTrue(early.isEmpty, "handed over while the writer still had it open")

    writer.waitUntilExit()
    let names = try await seen.wait(for: 1, timeout: 10)
    XCTAssertEqual(names.map(\.lastPathComponent), ["stalled.png"])
  }

  func test_fileActivity_seesAnotherProcessHoldingAFile() throws {
    let target = path("held.bin")
    let writer = Process()
    writer.executableURL = URL(fileURLWithPath: "/bin/sh")
    writer.arguments = ["-c", "exec 3>\"$0\"; sleep 2", target.path]
    try writer.run()
    Thread.sleep(forTimeInterval: 0.5)

    XCTAssertTrue(FileActivity.isOpenElsewhere(target))
    writer.waitUntilExit()
    XCTAssertFalse(FileActivity.isOpenElsewhere(target))
  }

  /// Without the subfolder option, only the top level counts.
  func test_ignoresSubfoldersUnlessAsked() async throws {
    let watched = try folder("watched")
    let nested = watched.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let seen = Collector()

    let watcher = MonitoredFolderWatcher()
    try watcher.startWatching(
      folder: MonitoredFolder(url: watched, ruleId: UUID(), destinationMode: .copyTo)
    ) { url in await seen.add(url) }
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    try Fixture.image(at: nested.appendingPathComponent("deep.png"), width: 32, height: 32)
    try Fixture.image(at: watched.appendingPathComponent("shallow.png"), width: 32, height: 32)

    let names = try await seen.wait(for: 1, timeout: 10)
    XCTAssertEqual(names.map(\.lastPathComponent), ["shallow.png"])
  }
}

/// Collects what the watcher reports, from whichever thread it reports on.
private actor Collector {
  private var urls: [URL] = []

  func add(_ url: URL) { urls.append(url) }

  func wait(for count: Int, timeout: TimeInterval) async throws -> [URL] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if urls.count >= count { return urls }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    return urls
  }
}
