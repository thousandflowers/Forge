import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// Downloading a tool, checking it, and putting it where Forge will find it.
///
/// Everything here is built in this test's own scratch directory and served
/// from a `file:` URL: the pipeline does not care where the bytes came from,
/// and a suite that needs the network is a suite that fails on a train.
final class ExtensionManagerTests: BaseTestCase {

  override func setUpWithError() throws {
    try super.setUpWithError()
    // Records are read through here by `ExternalTools.locate`. Pointed at this
    // test's own store, so a run cannot see - or write - what the person using
    // Forge has installed.
    ManagedExtensions.store = store
    ExternalTools.forgetWhatWasFound()
  }

  override func tearDownWithError() throws {
    ManagedExtensions.store = .shared
    ExternalTools.forgetWhatWasFound()
    try super.tearDownWithError()
  }

  // MARK: - Which build

  func test_architecture_takesTheBuildForThisProcessor() throws {
    let info = try Self.info(builds: ["arm64": Self.build(named: "a"), "x86_64": Self.build(named: "b")])
    XCTAssertEqual(info.build(for: .arm64)?.url.lastPathComponent, "a")
    XCTAssertEqual(info.build(for: .x86_64)?.url.lastPathComponent, "b")
  }

  /// An Apple silicon Mac runs an Intel build through Rosetta, so an Intel-only
  /// tool is still worth offering it.
  func test_architecture_fallsBackToIntelOnAppleSilicon() throws {
    let info = try Self.info(builds: ["x86_64": Self.build(named: "b")])
    XCTAssertEqual(info.build(for: .arm64)?.url.lastPathComponent, "b")
  }

  /// The other direction is not a fallback, it is a download that ends in
  /// "Bad CPU type in executable".
  func test_architecture_neverOffersAppleSiliconToAnIntelMac() throws {
    let info = try Self.info(builds: ["arm64": Self.build(named: "a")])
    XCTAssertNil(info.build(for: .x86_64))
  }

  // MARK: - The manifest

  func test_manifest_readsWhatItSays() async throws {
    let manager = try makeManager(offering: ["pandoc": Self.build(named: "pandoc.tar.gz")])
    let offered = try await manager.availableExtensions()

    let pandoc = try XCTUnwrap(offered.first)
    XCTAssertEqual(pandoc.id, "pandoc", "the key a tool is filed under is the name it is looked up by")
    XCTAssertEqual(pandoc.displayName, "Pandoc")
    XCTAssertEqual(pandoc.license, "GPL-2.0-or-later")
    XCTAssertEqual(pandoc.sourceURL, "https://github.com/jgm/pandoc")
    XCTAssertEqual(pandoc.builds["arm64"]?.executablePath, "bin/pandoc")
  }

  /// A manifest describing builds this version cannot describe is refused
  /// rather than half-read.
  func test_manifest_refusesASchemaFromTheFuture() async throws {
    let file = path("manifest.json")
    try #"{"schemaVersion": 99, "tools": {}}"#.write(to: file, atomically: true, encoding: .utf8)
    let manager = ExtensionManager(manifestURL: file, persistence: store)

    await assertThrows(ExtensionError.manifestTooNew(99)) {
      _ = try await manager.availableExtensions()
    }
  }

  func test_manifest_refusesAToolItDoesNotList() async throws {
    let manager = try makeManager(offering: ["pandoc": Self.build(named: "pandoc.tar.gz")])

    await assertThrows(ExtensionError.unknownTool("ffmpeg")) {
      _ = try await manager.install("ffmpeg")
    }
  }

  // MARK: - Checking what arrived

  func test_install_refusesAnArchiveThatIsNotWhatTheManifestPromised() async throws {
    let archive = try makeArchive(providing: "wrongtool")
    let manager = try makeManager(offering: [
      "wrongtool": ExtensionBuild(
        url: archive,
        // Not the hash of anything, which is the point.
        sha256: String(repeating: "0", count: 64),
        sizeBytes: 0,
        executablePath: "bin/wrongtool"
      ),
    ])

    do {
      _ = try await manager.install("wrongtool")
      XCTFail("an archive that does not hash to what was promised must not be installed")
    } catch let error as ExtensionError {
      guard case .checksumMismatch = error else {
        return XCTFail("expected a checksum mismatch, got \(error)")
      }
    }

    let installed = manager.installedExtensions()
    XCTAssertTrue(installed.isEmpty, "nothing is recorded for a download that was thrown away")
    XCTAssertNil(ExternalTools.locate("wrongtool"))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.extensionsDirectory.appendingPathComponent("wrongtool").path
      ),
      "a refused download leaves nothing behind"
    )
  }

  // MARK: - Install, record, remove

  func test_install_thenFound_thenRemoved() async throws {
    let archive = try makeArchive(providing: "forgetool")
    let manager = try makeManager(offering: [
      "forgetool": ExtensionBuild(
        url: archive,
        sha256: try ExtensionManager.sha256(of: archive),
        sizeBytes: Int64(size(of: archive)),
        executablePath: "bin/forgetool"
      ),
    ])

    let progress = Reported()
    let installed = try await manager.install("forgetool") { progress.append($0) }

    XCTAssertEqual(installed.id, "forgetool")
    XCTAssertEqual(installed.version, "1.0")
    XCTAssertEqual(installed.executablePath, "bin/forgetool")
    XCTAssertEqual(progress.last, 1.0, "a finished download reads as finished")
    XCTAssertEqual(
      installed.path,
      store.extensionsDirectory
        .appendingPathComponent("forgetool")
        .appendingPathComponent("1.0"),
      "one folder per tool, one per version"
    )

    // The record outlives the object that wrote it.
    let recorded = try await store.loadInstalledExtensions()
    XCTAssertEqual(recorded.map(\.id), ["forgetool"])
    XCTAssertEqual(recorded.first?.sha256, installed.sha256)

    // And the rest of the app finds it by name, which is what makes a
    // conversion get offered at all.
    let found = try XCTUnwrap(ExternalTools.locate("forgetool"))
    XCTAssertEqual(found, installed.executableURL)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: found.path))
    XCTAssertEqual(manager.executableURL(for: "forgetool"), found)

    try await manager.remove("forgetool")

    XCTAssertTrue(manager.installedExtensions().isEmpty)
    XCTAssertNil(ExternalTools.locate("forgetool"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path.path))
  }

  func test_remove_saysSoWhenThereIsNothingToRemove() async throws {
    let manager = try makeManager(offering: ["pandoc": Self.build(named: "pandoc.tar.gz")])
    await assertThrows(ExtensionError.notInstalled(tool: "pandoc")) {
      try await manager.remove("pandoc")
    }
  }

  /// Two installs of the same tool leave one copy, not two.
  func test_update_replacesTheVersionThatWasThere() async throws {
    let first = try makeArchive(providing: "forgetool", in: "one")
    let manager = try makeManager(offering: [
      "forgetool": ExtensionBuild(
        url: first,
        sha256: try ExtensionManager.sha256(of: first),
        sizeBytes: 0,
        executablePath: "bin/forgetool"
      ),
    ], version: "1.0")
    _ = try await manager.install("forgetool")

    let second = try makeArchive(providing: "forgetool", in: "two")
    let newer = try makeManager(offering: [
      "forgetool": ExtensionBuild(
        url: second,
        sha256: try ExtensionManager.sha256(of: second),
        sizeBytes: 0,
        executablePath: "bin/forgetool"
      ),
    ], version: "2.0", manifestNamed: "manifest-2.json")
    let updated = try await newer.update("forgetool")

    XCTAssertEqual(updated.version, "2.0")
    XCTAssertEqual(newer.installedExtensions().count, 1, "one record per tool")
    let versions = try FileManager.default.contentsOfDirectory(
      at: store.extensionsDirectory.appendingPathComponent("forgetool"),
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(versions.map(\.lastPathComponent), ["2.0"], "the old version is not left on disk")
  }

  // MARK: - The pilot: a real conversion through a fetched tool

  /// pandoc, end to end: fetched from a manifest, checked, unpacked, found by
  /// name, and used to write a DOCX.
  ///
  /// What is packed is a script that runs the pandoc on this machine, rather
  /// than a 265MB copy of it: the pipeline under test is the same either way,
  /// and a suite that gzips a quarter of a gigabyte is a suite nobody runs.
  func test_pandoc_isFetchedAndThenConvertsADocument() async throws {
    guard let real = ExternalTools.locate("pandoc") else {
      throw XCTSkip("pandoc is not installed here")
    }

    let archive = try makeArchive(providing: "pandoc", running: """
      #!/bin/sh
      exec "\(real.path)" "$@"
      """)
    let manager = try makeManager(offering: [
      "pandoc": ExtensionBuild(
        url: archive,
        sha256: try ExtensionManager.sha256(of: archive),
        sizeBytes: Int64(size(of: archive)),
        executablePath: "bin/pandoc"
      ),
    ])

    let installed = try await manager.install("pandoc")
    XCTAssertEqual(
      ExternalTools.locate("pandoc"), installed.executableURL,
      "a fetched tool is the one Forge uses, not whatever else is on PATH"
    )

    let source = path("note.md")
    try "# Titolo\n\nUn paragrafo.\n".write(to: source, atomically: true, encoding: .utf8)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "docx")), category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(output.pathExtension, "docx")
    XCTAssertGreaterThan(size(of: output), 0)

    try await manager.remove("pandoc")
    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path.path))
  }

  // MARK: - Fixtures

  /// A tool in a folder, packed the way a hosted build is: `bin/<name>` inside
  /// a gzipped tar.
  private func makeArchive(
    providing name: String,
    in directory: String = "payload",
    running script: String? = nil
  ) throws -> URL {
    let payload = try folder(directory)
    let bin = payload.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

    let executable = bin.appendingPathComponent(name)
    try (script ?? "#!/bin/sh\necho \(name)").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let archive = path("\(directory)-\(name).tar.gz")
    try ExternalTools.run(
      URL(fileURLWithPath: "/usr/bin/tar"),
      ["-czf", archive.path, "-C", payload.path, "."]
    )
    return archive
  }

  private func makeManager(
    offering builds: [String: ExtensionBuild],
    version: String = "1.0",
    manifestNamed name: String = "manifest.json"
  ) throws -> ExtensionManager {
    let tools = builds.map { id, build in
      """
      "\(id)": {
        "displayName": "\(id == "pandoc" ? "Pandoc" : id)",
        "version": "\(version)",
        "license": "GPL-2.0-or-later",
        "sourceURL": "https://github.com/jgm/pandoc",
        "description": "Convert between document formats",
        "builds": {
          "arm64": \(Self.json(build)),
          "x86_64": \(Self.json(build))
        }
      }
      """
    }
    let file = path(name)
    try """
    { "schemaVersion": 1, "tools": { \(tools.joined(separator: ",")) } }
    """.write(to: file, atomically: true, encoding: .utf8)

    return ExtensionManager(manifestURL: file, persistence: store)
  }

  private static func json(_ build: ExtensionBuild) -> String {
    """
    {
      "url": "\(build.url.absoluteString)",
      "sha256": "\(build.sha256)",
      "sizeBytes": \(build.sizeBytes),
      "executablePath": "\(build.executablePath)"
    }
    """
  }

  private static func build(named name: String) -> ExtensionBuild {
    ExtensionBuild(
      url: URL(string: "https://example.invalid/\(name)")!,
      sha256: String(repeating: "a", count: 64),
      sizeBytes: 1024,
      executablePath: "bin/pandoc"
    )
  }

  private static func info(builds: [String: ExtensionBuild]) throws -> ExtensionInfo {
    let entries = builds.map { "\"\($0.key)\": \(json($0.value))" }.joined(separator: ",")
    let data = Data("""
    {
      "displayName": "Pandoc",
      "version": "1.0",
      "license": "GPL-2.0-or-later",
      "sourceURL": "https://github.com/jgm/pandoc",
      "description": "Convert between document formats",
      "builds": { \(entries) }
    }
    """.utf8)
    return try JSONDecoder().decode(ExtensionInfo.self, from: data)
  }

  private func assertThrows(
    _ expected: ExtensionError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: () async throws -> Void
  ) async {
    do {
      try await work()
      XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as ExtensionError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
  }

  /// Progress arrives on whichever thread the session is using, so it is
  /// collected behind a lock rather than into a local array.
  private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }

    var last: Double? {
      lock.lock()
      defer { lock.unlock() }
      return values.last
    }
  }
}
