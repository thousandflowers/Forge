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
    try await watcher.startWatching(
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
    try await watcher.startWatching(
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
    try await watcher.startWatching(
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
    try await watcher.startWatching(
      folder: MonitoredFolder(url: watched, ruleId: UUID(), destinationMode: .copyTo)
    ) { url in await seen.add(url) }
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    try Fixture.image(at: nested.appendingPathComponent("deep.png"), width: 32, height: 32)
    try Fixture.image(at: watched.appendingPathComponent("shallow.png"), width: 32, height: 32)

    let names = try await seen.wait(for: 1, timeout: 10)
    XCTAssertEqual(names.map(\.lastPathComponent), ["shallow.png"])
  }

  private func watch(_ watched: URL, subfolders: Bool = false, gone: (@Sendable () -> Void)? = nil) async throws -> (MonitoredFolderWatcher, Collector) {
    let seen = Collector()
    let watcher = MonitoredFolderWatcher()
    try await watcher.startWatching(
      folder: MonitoredFolder(url: watched, ruleId: UUID(), destinationMode: .copyTo, includeSubfolders: subfolders),
      onGone: gone
    ) { url in await seen.add(url) }
    return (watcher, seen)
  }

  /// A folder dragged in arrives as one event, for the folder. The files in
  /// it were never looked at.
  func test_aFolderMovedInIsLookedInside() async throws {
    let watched = try folder("watched")
    let outside = try folder("album")
    try Fixture.image(at: outside.appendingPathComponent("one.png"), width: 32, height: 32)
    try Fixture.image(at: outside.appendingPathComponent("two.png"), width: 32, height: 32)
    let (watcher, seen) = try await watch(watched, subfolders: true)
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    try FileManager.default.moveItem(at: outside, to: watched.appendingPathComponent("album"))

    let names = try await seen.wait(for: 2, timeout: 10)
    XCTAssertEqual(Set(names.map(\.lastPathComponent)), ["one.png", "two.png"])
  }

  /// A browser writes `photo.png.part` and renames it when it is done. The
  /// half-file was converted - it is a PNG inside, whatever it is called - and
  /// then the whole one was. A name that does not yet say what the file is
  /// means it is not ready.
  func test_aFileStillCalledSomethingProvisionalIsLeftAlone() async throws {
    let watched = try folder("watched")
    let (watcher, seen) = try await watch(watched)
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    let partial = watched.appendingPathComponent("photo.png.part")
    try Fixture.image(at: watched.appendingPathComponent("photo.png"), width: 32, height: 32)
    try FileManager.default.moveItem(at: watched.appendingPathComponent("photo.png"), to: partial)
    try await Task.sleep(nanoseconds: 2_500_000_000)
    let early = await seen.all()
    XCTAssertEqual(early.map(\.lastPathComponent).filter { $0.hasSuffix(".part") }, [])

    try FileManager.default.moveItem(at: partial, to: watched.appendingPathComponent("done.png"))
    let names = try await seen.wait(for: 1, timeout: 10)
    XCTAssertTrue(names.map(\.lastPathComponent).contains("done.png"), "\(names)")
  }

  /// A file written in bursts - closed in between - was handed over after the
  /// first burst and never looked at again: only a new name counted as an
  /// arrival, not more of the same file.
  func test_aFileThatGrowsAgainIsHandedOverAgain() async throws {
    let watched = try folder("watched")
    let (watcher, seen) = try await watch(watched)
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    let file = watched.appendingPathComponent("notes.txt")
    try Data("first half".utf8).write(to: file)
    _ = try await seen.wait(for: 1, timeout: 10)

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(", second half".utf8))
    try handle.close()

    let names = try await seen.wait(for: 2, timeout: 10)
    XCTAssertEqual(names.map(\.lastPathComponent), ["notes.txt", "notes.txt"])
  }

  /// A watched folder that was moved or deleted went on being "watched", and
  /// nothing said that nothing would ever arrive again.
  func test_saysWhenTheFolderItWatchesIsGone() async throws {
    let watched = try folder("watched")
    let gone = Flag()
    let (watcher, _) = try await watch(watched) { gone.raise() }
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 700_000_000)
    try FileManager.default.moveItem(at: watched, to: path("moved-away"))

    let deadline = Date().addingTimeInterval(10)
    while !gone.isRaised, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
    XCTAssertTrue(gone.isRaised)
  }

  /// Opening a folder waits while macOS asks whether it can be seen. Forge
  /// waited with it, from the window down, and looked as if it had died.
  func test_nobodyWaitsWhileTheFolderIsBeingOpened() async throws {
    let watched = try folder("watched")
    let seen = Collector()
    let answer = DispatchSemaphore(value: 0)
    let watcher = MonitoredFolderWatcher()
    let one = MonitoredFolder(url: watched, ruleId: UUID(), destinationMode: .copyTo)

    let start = Date()
    watcher.start(folder: one, begun: { _ in _ = answer.wait(timeout: .now() + 20) }) { url in await seen.add(url) }
    watcher.stop()
    watcher.start(folder: one, begun: { _ in }) { url in await seen.add(url) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)

    // And once it is answered, the last thing asked is what holds.
    answer.signal()
    try await Task.sleep(nanoseconds: 700_000_000)
    try Fixture.image(at: watched.appendingPathComponent("arrived.png"), width: 32, height: 32)
    let names = try await seen.wait(for: 1, timeout: 10)
    XCTAssertEqual(names.map(\.lastPathComponent), ["arrived.png"])

    watcher.stop()
    try await Task.sleep(nanoseconds: 300_000_000)
    try Fixture.image(at: watched.appendingPathComponent("late.png"), width: 32, height: 32)
    try await Task.sleep(nanoseconds: 2_500_000_000)
    let after = await seen.all()
    XCTAssertEqual(after.map(\.lastPathComponent), ["arrived.png"])
  }
}

/// Collects what the watcher reports, from whichever thread it reports on.
private actor Collector {
  private var urls: [URL] = []

  func add(_ url: URL) { urls.append(url) }

  func all() -> [URL] { urls }

  func wait(for count: Int, timeout: TimeInterval) async throws -> [URL] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if urls.count >= count { return urls }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    return urls
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false
  func raise() { lock.lock(); raised = true; lock.unlock() }
  var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
