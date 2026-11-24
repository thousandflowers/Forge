import XCTest
@testable import Forge

/// What Forge fetches: the file it expected or nothing, in its own folder, and
/// gone when it is removed.
final class ToolboxTests: XCTestCase {
  private var folder: URL!
  private var box: Toolbox { Toolbox(root: folder.appendingPathComponent("Tools")) }

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() { try? FileManager.default.removeItem(at: folder) }

  /// An archive with one command in it, some folders down.
  private func release(script: String = "#!/bin/sh\necho here\n", sha: String? = nil, bytes: Int64? = nil, named archive: String = "thing.tar.xz") throws -> Toolbox.Release {
    let inside = folder.appendingPathComponent("made/deep/bin")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    let command = inside.appendingPathComponent("forge-test-command")
    try script.write(to: command, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    let packed = folder.appendingPathComponent(archive)
    try ExternalTools.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-a", "-c", "-f", packed.path, "-C", folder.appendingPathComponent("made").path, "deep"])
    let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: packed.path)[.size] as? Int64)
    let build = Toolbox.Build(packed.absoluteString, try sha ?? Toolbox.sha256(of: packed), bytes ?? size)
    return Toolbox.Release(version: "1", licence: "none", arm: build, intel: build, commands: ["forge-test-command"])
  }

  private var link: URL { box.commands.appendingPathComponent("forge-test-command") }

  func test_aToolIsFetchedLinkedAndRemoved() async throws {
    for archive in ["thing.tar.xz", "thing.zip", "thing.tar.gz"] {
      let release = try release(named: archive)
      try await box.fetch("thing", release) { _ in }
      XCTAssertTrue(ExternalTools.answer(of: link, []).contains("here"), archive)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: box.root.path).sorted(), ["bin", "thing-1"], "nothing left over")
      // Twice is the same as once.
      try await box.fetch("thing", release) { _ in }
      try box.remove("thing", release)
      XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: box.root.path), ["bin"])
    }
  }

  /// Anything but the file that was chosen is thrown away, unopened.
  func test_aDifferentFileIsRefused() async throws {
    let wrong = try release(sha: String(repeating: "0", count: 64))
    await assertRefused(wrong, saying: "not the thing Forge expects")
  }

  /// More than there should be is not waited for.
  func test_oneThatDoesNotRunHereIsNotKept() async throws {
    await assertRefused(try release(script: "#!/bin/sh\nexit 3\n"), saying: "does not run on this Mac")
    XCTAssertFalse(FileManager.default.fileExists(atPath: box.root.appendingPathComponent("thing-1").path))
  }

  func test_whatIsNotThereSaysSo() async throws {
    let build = Toolbox.Build(folder.appendingPathComponent("gone.zip").absoluteString, "", 10)
    do {
      try await box.fetch("thing", Toolbox.Release(version: "1", licence: "", arm: build, intel: build, commands: ["x"])) { _ in }
      XCTFail("fetched nothing")
    } catch {}
  }

  private func assertRefused(_ release: Toolbox.Release, saying words: String, line: UInt = #line) async {
    do {
      try await box.fetch("thing", release) { _ in }
      XCTFail("kept it", line: line)
    } catch { XCTAssertTrue(error.localizedDescription.contains(words), error.localizedDescription, line: line) }
    XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), line: line)
  }

  /// Every tool offered can be had, for both kinds of Mac, over a safe line.
  func test_everyToolOfferedHasABuild() throws {
    for tool in ToolOffers.all {
      let release = try XCTUnwrap(tool.release, tool.name)
      XCTAssertTrue(release.commands.contains(tool.binary), tool.name)
      for build in [release.arm, release.intel] {
        XCTAssertEqual(build.url.scheme, "https", tool.name)
        XCTAssertEqual(build.sha256.count, 64, tool.name)
        XCTAssertGreaterThan(build.bytes, 1_000_000, tool.name)
      }
    }
    XCTAssertEqual(Set(ToolOffers.all.map(\.name)), Set(Toolbox.releases.keys))
  }
}
