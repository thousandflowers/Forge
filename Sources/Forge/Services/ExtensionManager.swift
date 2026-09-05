import CryptoKit
import Foundation

/// Fetches the tools Forge does not ship, from builds Forge hosts itself.
///
/// The core converts with Apple's frameworks and needs none of this. An
/// extension only adds what no framework on the Mac can do — writing an EPUB,
/// encoding VP9 — and it arrives on the user's say-so, from a URL the manifest
/// named, hashing to what that manifest said. Nothing is bundled inside the
/// app: a copy of somebody else's binary in Forge's own bundle is their
/// licence in Forge's repository.
///
/// An extension is a folder, not a file. A binary that travels with its
/// dylibs, its language data or its fonts is the ordinary case, so the whole
/// unpacked tree is what gets moved into place.
actor ExtensionManager {
  static let shared = ExtensionManager()

  /// Where the list of tools is published.
  ///
  /// Forge's own releases, so the bytes and the app come from one place. The
  /// environment variable is for testing a manifest before it is published,
  /// and for anyone who would rather host their own.
  static var defaultManifestURL: URL {
    if let override = ProcessInfo.processInfo.environment["FORGE_EXTENSIONS_MANIFEST"],
       let url = URL(string: override) {
      return url
    }
    return URL(string: "https://github.com/thousandflowers/Forge/releases/latest/download/extensions.json")!
  }

  private let manifestURL: URL
  private let persistence: PersistenceManager
  private let session: URLSession
  /// Asked once per launch. The list changes when Forge publishes a release,
  /// which is not something that happens while the app is open.
  private var cachedManifest: ExtensionManifest?

  /// Where a Developer ID check would go.
  ///
  /// The hosted builds are ad-hoc signed and vouched for by their hash, which
  /// is what the manifest promises. Should Forge ever sign them with a
  /// certificate, the check belongs here — handed the unpacked folder before
  /// anything is moved into place, and throwing to refuse it.
  private let verifySignature: (@Sendable (URL, ExtensionInfo) throws -> Void)?

  init(
    manifestURL: URL = ExtensionManager.defaultManifestURL,
    persistence: PersistenceManager = .shared,
    session: URLSession = .shared,
    verifySignature: (@Sendable (URL, ExtensionInfo) throws -> Void)? = nil
  ) {
    self.manifestURL = manifestURL
    self.persistence = persistence
    self.session = session
    self.verifySignature = verifySignature
  }

  // MARK: - What there is, and what is here

  /// Everything the manifest offers, whether or not this Mac can run it.
  func availableExtensions() async throws -> [ExtensionInfo] {
    try await manifest().extensions
  }

  /// Only what has a build for this processor.
  func installableExtensions() async throws -> [ExtensionInfo] {
    try await availableExtensions().filter { $0.build(for: .current) != nil }
  }

  /// What Forge has already fetched. Read straight off disk, so it answers
  /// without waiting on anything.
  nonisolated func installedExtensions() -> [InstalledExtension] {
    persistence.installedExtensionsSnapshot()
  }

  /// The runnable binary for a tool, if it is installed and still there.
  nonisolated func executableURL(for id: String) -> URL? {
    guard let record = installedExtensions().first(where: { $0.id == id }) else { return nil }
    let url = record.executableURL
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  // MARK: - Install

  /// Fetch a tool and put it where Forge will find it.
  ///
  /// Resolve the build for this processor, stream it to a scratch folder,
  /// check its hash against the manifest, unpack it, take macOS's quarantine
  /// flag off it, and move the finished folder into place in one step. A
  /// failure at any point leaves a scratch folder to be deleted and nothing
  /// else: what the user already has is untouched until that last move.
  @discardableResult
  func install(
    _ id: String,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> InstalledExtension {
    let info = try await description(of: id)
    guard let build = info.build(for: .current) else {
      throw ExtensionError.noBuildForThisMac(tool: info.displayName)
    }

    let fileManager = FileManager.default
    let root = persistence.extensionsDirectory
    // Scratch inside the managed folder rather than in /tmp: the finished
    // install is a rename, and a rename is only atomic within one volume.
    let staging = root
      .appendingPathComponent(".staging", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: staging) }

    let archive = staging.appendingPathComponent(
      build.url.lastPathComponent.isEmpty ? "download" : build.url.lastPathComponent
    )
    try await download(build, to: archive, progress: progress)

    let digest = try Self.sha256(of: archive)
    guard digest.caseInsensitiveCompare(build.sha256) == .orderedSame else {
      // Deleted at once. What arrived is not what was asked for, and it is not
      // going to sit on somebody's disk while they read the message.
      try? fileManager.removeItem(at: archive)
      throw ExtensionError.checksumMismatch(
        tool: info.displayName, expected: build.sha256, actual: digest
      )
    }

    let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
    try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
    try Self.unpack(archive, into: unpacked)

    let executable = unpacked.appendingPathComponent(build.executablePath)
    guard fileManager.fileExists(atPath: executable.path) else {
      throw ExtensionError.archiveIncomplete(tool: info.displayName, missing: build.executablePath)
    }
    // An archive that lost the executable bit in transit is otherwise a tool
    // that installs cleanly and cannot be run.
    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    Self.stripQuarantine(unpacked)
    try verifySignature?(unpacked, info)

    let home = root.appendingPathComponent(info.id, isDirectory: true)
    try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    let destination = home.appendingPathComponent(info.version, isDirectory: true)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: unpacked, to: destination)

    // One version of a tool at a time. Keeping the old one would mean keeping
    // hundreds of megabytes nothing is going to run again.
    for stale in (try? fileManager.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
    where stale.lastPathComponent != info.version {
      try? fileManager.removeItem(at: stale)
    }

    let installed = InstalledExtension(
      id: info.id,
      version: info.version,
      path: destination,
      executablePath: build.executablePath,
      sha256: build.sha256,
      installedAt: Date()
    )
    try await record(installed)
    return installed
  }

  /// Fetch whatever the manifest offers now, replacing what is here.
  @discardableResult
  func update(
    _ id: String,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> InstalledExtension {
    try await install(id, progress: progress)
  }

  /// The manifest's version of a tool, when it differs from the installed one.
  func updateAvailable(for id: String) async -> ExtensionInfo? {
    guard let installed = installedExtensions().first(where: { $0.id == id }),
          let offered = try? await description(of: id),
          offered.version != installed.version else { return nil }
    return offered
  }

  /// Take a tool off the Mac, files and record together.
  func remove(_ id: String) async throws {
    var records = try await persistence.loadInstalledExtensions()
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw ExtensionError.notInstalled(tool: id)
    }
    // The whole tool folder, not just the version in the record: the folder is
    // Forge's own, and nothing else keeps anything in it.
    try? FileManager.default.removeItem(
      at: persistence.extensionsDirectory.appendingPathComponent(id)
    )
    records.remove(at: index)
    try await persistence.saveInstalledExtensions(records)
    ExternalTools.forgetWhatWasFound()
  }

  // MARK: - Private

  private func description(of id: String) async throws -> ExtensionInfo {
    guard let info = try await manifest().extensions.first(where: { $0.id == id }) else {
      throw ExtensionError.unknownTool(id)
    }
    return info
  }

  private func manifest() async throws -> ExtensionManifest {
    if let cachedManifest { return cachedManifest }
    let (data, response) = try await session.data(from: manifestURL)
    try Self.check(response, describing: manifestURL)
    let decoded = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    guard decoded.schemaVersion <= ExtensionManifest.supportedSchemaVersion else {
      throw ExtensionError.manifestTooNew(decoded.schemaVersion)
    }
    cachedManifest = decoded
    return decoded
  }

  private func record(_ installed: InstalledExtension) async throws {
    var records = try await persistence.loadInstalledExtensions()
    records.removeAll { $0.id == installed.id }
    records.append(installed)
    try await persistence.saveInstalledExtensions(records)
    // A tool that just arrived has to be findable without a relaunch.
    ExternalTools.forgetWhatWasFound()
  }

  /// Stream an archive to disk. `URLSession` writes it out as it arrives, so a
  /// hundred-megabyte tool costs a hundred megabytes of disk and none of
  /// memory; the delegate exists only to report how far along it is.
  private func download(
    _ build: ExtensionBuild,
    to file: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let reporter = DownloadProgress(expected: build.sizeBytes, report: progress)
    let (temporary, response) = try await session.download(from: build.url, delegate: reporter)
    try Self.check(response, describing: build.url)
    // The temporary file is deleted the moment this returns, so it moves now.
    try FileManager.default.moveItem(at: temporary, to: file)
    progress(1.0)
  }

  private static func check(_ response: URLResponse, describing url: URL) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      throw ExtensionError.downloadFailed(
        reason: "\(url.lastPathComponent) answered \(http.statusCode)"
      )
    }
  }

  /// The archive's hash, read a megabyte at a time. A tool can be hundreds of
  /// megabytes, and none of it belongs in memory at once.
  static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }

    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Unpack with what macOS ships. bsdtar and unzip are the system's own, and
  /// they write into a folder belonging to this install alone.
  static func unpack(_ archive: URL, into folder: URL) throws {
    let isZip = archive.pathExtension.lowercased() == "zip"
    let tool = URL(fileURLWithPath: isZip ? "/usr/bin/unzip" : "/usr/bin/tar")
    let arguments = isZip
      ? ["-q", "-o", archive.path, "-d", folder.path]
      : ["-xzf", archive.path, "-C", folder.path]
    try ExternalTools.run(tool, arguments)
  }

  /// Take off the flag macOS puts on anything downloaded, which otherwise
  /// stops the binary with a dialog about an unidentified developer — for a
  /// file the user asked Forge to fetch and Forge checked the hash of.
  static func stripQuarantine(_ folder: URL) {
    // `xattr -d` exits non-zero when the attribute was not there, which is the
    // ordinary case for files unpacked from an archive rather than downloaded
    // one by one. Nothing to report.
    try? ExternalTools.run(
      URL(fileURLWithPath: "/usr/bin/xattr"),
      ["-r", "-d", "com.apple.quarantine", folder.path]
    )
  }
}

/// Reports how much of a download has arrived.
///
/// A class rather than a closure because `URLSession` wants a delegate, and
/// `@unchecked Sendable` because it is called on the session's own queue and
/// holds nothing that changes.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let expected: Int64
  private let report: @Sendable (Double) -> Void

  init(expected: Int64, report: @escaping @Sendable (Double) -> Void) {
    self.expected = expected
    self.report = report
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    // The server's own answer when it gives one; the manifest's figure when it
    // does not, which is why the manifest carries a size at all.
    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
    guard total > 0 else { return }
    report(min(1.0, Double(totalBytesWritten) / Double(total)))
  }

  /// Required by the protocol. The async `download(from:delegate:)` hands back
  /// the finished file itself, so there is nothing to do here.
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}

/// What can go wrong fetching a tool, said in the user's terms.
enum ExtensionError: LocalizedError, Equatable {
  case unknownTool(String)
  case notInstalled(tool: String)
  case noBuildForThisMac(tool: String)
  case checksumMismatch(tool: String, expected: String, actual: String)
  case downloadFailed(reason: String)
  case archiveIncomplete(tool: String, missing: String)
  case manifestTooNew(Int)

  var errorDescription: String? {
    switch self {
    case .unknownTool(let id):
      return "Forge does not offer a tool called \(id)."
    case .notInstalled(let tool):
      return "\(tool) is not installed."
    case .noBuildForThisMac(let tool):
      return "There is no \(tool) build for this Mac's processor."
    case .checksumMismatch(let tool, let expected, let actual):
      return "The \(tool) download does not match what Forge expected "
        + "(\(expected.prefix(12))… against \(actual.prefix(12))…), so it was thrown away."
    case .downloadFailed(let reason):
      return "The download failed: \(reason)"
    case .archiveIncomplete(let tool, let missing):
      return "The \(tool) download has no \(missing) in it."
    case .manifestTooNew(let version):
      return "The extension list is version \(version), which this version of Forge cannot read. "
        + "Updating Forge will fix it."
    }
  }
}

/// Where `ExternalTools.locate` looks for a tool Forge fetched.
///
/// Synchronous on purpose: deciding whether to offer a conversion happens all
/// over the app, on the main thread, and cannot wait on an actor.
enum ManagedExtensions {
  private static let state = State()

  /// The store the records are kept in. The app's own, except under test,
  /// where a run must not see — or write — what the user has installed.
  static var store: PersistenceManager {
    get { state.store }
    set { state.store = newValue }
  }

  /// The binary a fetched tool provides, if this Mac has it.
  static func executable(named binary: String) -> URL? {
    for record in store.installedExtensionsSnapshot() where record.id == binary {
      let url = record.executableURL
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    return nil
  }

  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PersistenceManager = .shared

    var store: PersistenceManager {
      get { lock.lock(); defer { lock.unlock() }; return current }
      set { lock.lock(); current = newValue; lock.unlock() }
    }
  }
}
