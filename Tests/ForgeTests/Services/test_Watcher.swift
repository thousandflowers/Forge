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
