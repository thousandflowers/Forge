import CryptoKit
import Foundation

/// The tools Forge fetches itself, from whoever makes them, into a folder of
/// its own: no package manager, no password, nothing anywhere else on the Mac.
///
/// Which build, and what it must hash to, is written down here rather than
/// looked up: what arrives is what was chosen, or it is not used.
struct Toolbox: Sendable {
  static let shared = Toolbox(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Forge/Tools", isDirectory: true))

  let root: URL

  /// One build of a tool, for one kind of Mac.
  struct Build: Hashable, Sendable {
    let url: URL
    let sha256: String
    let bytes: Int64

    init(_ url: String, _ sha256: String, _ bytes: Int64) {
      self.url = URL(string: url)!
      self.sha256 = sha256
      self.bytes = bytes
    }
  }

  struct Release: Hashable, Sendable {
    let version: String
    let licence: String
    let arm: Build
    let intel: Build
    /// The commands in it, the first being the one it is known by.
    let commands: [String]
    /// What to ask it to see that it runs here.
    var check = "--version"

    var build: Build {
      #if arch(arm64)
      return arm
      #else
      return intel
      #endif
    }
  }

  // MARK: - What there is to fetch

  private static let github = "https://github.com/"
  static let releases: [String: Release] = [
    "ffmpeg": Release(
      version: "8.1.3-2", licence: "GPL 3",
      arm: Build(github + "jellyfin/jellyfin-ffmpeg/releases/download/v8.1.3-2/jellyfin-ffmpeg_8.1.3-2_portable_macarm64-gpl.tar.xz",
                 "d898cc819e7c4e9219d6410ddbdaada0838f14bec6ff89e283639915394cb43f", 32_904_768),
      intel: Build(github + "jellyfin/jellyfin-ffmpeg/releases/download/v8.1.3-2/jellyfin-ffmpeg_8.1.3-2_portable_mac64-gpl.tar.xz",
                   "d394180f1155f84857544a48a99869f5741ccc50c5a1f73d2797429a2b326448", 38_099_916),
      commands: ["ffmpeg", "ffprobe"], check: "-version"
    ),
    "pandoc": Release(
      version: "3.14", licence: "GPL 2",
      arm: Build(github + "jgm/pandoc/releases/download/3.14/pandoc-3.14-arm64-macOS.zip",
                 "58d6593884fec9d4424b641b92503c316d9c36decb2891ff8d73ae74dd3b6304", 43_712_865),
      intel: Build(github + "jgm/pandoc/releases/download/3.14/pandoc-3.14-x86_64-macOS.zip",
                   "891708579061e7b1c1a6ce0df30ebb3cb2b6d0ca045ed3c8554ab830c1e0c270", 27_490_795),
      commands: ["pandoc"]
    ),
    "webp": Release(
      version: "1.6.0", licence: "BSD",
      arm: Build("https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-mac-arm64.tar.gz",
                 "bc6bf84cc70f3f8574fba797d1e4a7dea4feebe9fa4be919f202413ea2b3b8f2", 5_283_875),
      intel: Build("https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-mac-x86-64.tar.gz",
                   "f112dd83b420ab2a4b27d46610d9827ddf4200216023281de378647ecca31c2a", 6_325_608),
      commands: ["cwebp"], check: "-version"
    ),
    "LibreOffice": Release(
      version: "26.8.3", licence: "MPL 2",
      arm: Build("https://download.documentfoundation.org/libreoffice/stable/26.8.3/mac/aarch64/LibreOffice_26.8.3_MacOS_aarch64.dmg",
                 "de943203795e5057785f65515063e2db5eb60b0bb6d8e2534fec59e5cc5fb988", 299_927_705),
      intel: Build("https://download.documentfoundation.org/libreoffice/stable/26.8.3/mac/x86_64/LibreOffice_26.8.3_MacOS_x86-64.dmg",
                   "bb3c35d628780510915ad9e759d7ed898094d7985d01b2181bd1d4ecd94fd159", 309_939_485),
      commands: ["soffice"]
    ),
    "calibre": Release(
      version: "9.19.0", licence: "GPL 3",
      arm: Build(github + "kovidgoyal/calibre/releases/download/v9.19.0/calibre-9.19.0.dmg",
                 "207c80d80ace59cb21a4c52fa1c40843a8e860de100304e590da664db3abfb3f", 408_549_188),
      intel: Build(github + "kovidgoyal/calibre/releases/download/v9.19.0/calibre-9.19.0.dmg",
                   "207c80d80ace59cb21a4c52fa1c40843a8e860de100304e590da664db3abfb3f", 408_549_188),
      commands: ["ebook-convert"]
    ),
    "DuckDB": Release(
      version: "2.0.1", licence: "MIT",
      arm: Build(github + "duckdb/duckdb/releases/download/v2.0.1/duckdb-cli-osx-arm64.tar.gz",
                 "7809dc1ea9215db53f76bdd539e38186c2310b6a3b5800581bf65876048556aa", 19_349_951),
      intel: Build(github + "duckdb/duckdb/releases/download/v2.0.1/duckdb-cli-osx-amd64.tar.gz",
                   "f63131b6e1e69ded1a55e0b96f2f1d77658e4cf5b666346487c927820a4d53c5", 21_684_907),
      commands: ["duckdb"]
    ),
    "Blender": Release(
      // Its makers stopped at the fourth for an Intel Mac.
      version: "5.3.0", licence: "GPL 3",
      arm: Build("https://download.blender.org/release/Blender5.3/blender-5.3.0-macos-arm64.dmg",
                 "2d802b54766741e612cead50b03ebbc8eb64dadc71eda932573d256b8a784720", 359_893_873),
      intel: Build("https://download.blender.org/release/Blender4.5/blender-4.5.9-macos-x64.dmg",
                   "00c8a433504291374bfa045c0c2d708a779f8abc8400b4718fdd11c117486fa4", 335_828_094),
      commands: ["Blender"]
    ),
    "Typst": Release(
      version: "0.15.1", licence: "Apache 2",
      arm: Build(github + "typst/typst/releases/download/v0.15.1/typst-aarch64-apple-darwin.tar.xz",
                 "48f62ed034aa3a7978309579ac6ca00045e2ef0da73114e8af27cfd8e74dc05a", 14_438_168),
      intel: Build(github + "typst/typst/releases/download/v0.15.1/typst-x86_64-apple-darwin.tar.xz",
                   "7f9fdd9584866245de9a79e0add8f9236fae6f40a8a45e2c4771ccc14db4e0fa", 15_635_600),
      commands: ["typst"]
    ),
  ]

  // MARK: - What is here

  /// Where the commands are linked, for the search to look in.
  var commands: URL { root.appendingPathComponent("bin", isDirectory: true) }

  private func home(of name: String, _ release: Release) -> URL {
    root.appendingPathComponent("\(name)-\(release.version)", isDirectory: true)
  }

  func has(_ name: String) -> Bool {
    Self.releases[name].map { FileManager.default.fileExists(atPath: home(of: name, $0).path) } ?? false
  }

  func remove(_ name: String, _ release: Release? = nil) throws {
    guard let release = release ?? Self.releases[name] else { return }
    for command in release.commands {
      try? FileManager.default.removeItem(at: commands.appendingPathComponent(command))
    }
    let place = home(of: name, release)
    if FileManager.default.fileExists(atPath: place.path) { try FileManager.default.removeItem(at: place) }
    ExternalTools.forgetWhatWasFound()
  }

  // MARK: - Fetching

  /// - Parameter progress: how much of the download is in, to one, and then nil
  ///   while it is unpacked.
  func fetch(_ name: String, _ release: Release, progress: @escaping @Sendable (Double?) -> Void) async throws {
    let files = FileManager.default
    let build = release.build
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    try refuseIfTooFull(for: build)

    let staging = root.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: staging) }

    let packed = staging.appendingPathComponent("packed-" + build.url.lastPathComponent)
    try await Self.download(build.url, to: packed, expecting: build.bytes, progress: progress)
    try Task.checkCancellation()
    guard try Self.sha256(of: packed) == build.sha256 else {
      throw ProcessingError.conversionFailed(reason: "What came from \(build.url.host ?? "there") is not the \(name) Forge expects, so it was thrown away.")
    }

    progress(nil)
    let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
    try files.createDirectory(at: unpacked, withIntermediateDirectories: true)
    if build.url.pathExtension == "dmg" {
      try Self.copyApp(from: packed, to: unpacked, mountedAt: staging.appendingPathComponent("disk", isDirectory: true))
    } else {
      // tar takes a zip as well, and nothing in it leaves the folder it is told.
      try ExternalTools.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-x", "-f", packed.path, "-C", unpacked.path])
    }

    let found = try release.commands.map { command -> URL in
      guard let tool = Self.command(command, in: unpacked) else {
        throw ProcessingError.conversionFailed(reason: "\(command) is not in what was downloaded.")
      }
      return tool
    }
    // One built for a later macOS, or another kind of Mac, says so now and not
    // in the middle of a batch.
    do { try ExternalTools.run(found[0], [release.check]) } catch is CancellationError { throw CancellationError() } catch {
      throw ProcessingError.conversionFailed(reason: "\(name) \(release.version) does not run on this Mac.")
    }

    // Where in it each one is, worked out while it is still there.
    let start = unpacked.resolvingSymlinksInPath().path.count
    let inside = found.map { $0.resolvingSymlinksInPath().path.dropFirst(start) }
    let place = home(of: name, release)
    if files.fileExists(atPath: place.path) { try files.removeItem(at: place) }
    try files.moveItem(at: unpacked, to: place)
    try files.createDirectory(at: commands, withIntermediateDirectories: true)
    for (command, path) in zip(release.commands, inside) {
      let link = commands.appendingPathComponent(command)
      if (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil { try files.removeItem(at: link) }
      try files.createSymbolicLink(atPath: link.path, withDestinationPath: place.path + path)
    }
    ExternalTools.forgetWhatWasFound()
  }

  /// A download takes itself and what comes out of it: three times over is
  /// more than any of these needs.
  private func refuseIfTooFull(for build: Build) throws {
    let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    guard let free, free < build.bytes * 4 else { return }
    let wanted = ByteCountFormatter.string(fromByteCount: build.bytes * 4, countStyle: .file)
    throw ProcessingError.conversionFailed(reason: "There is not enough room on this Mac: it needs \(wanted) free.")
  }

  private static func download(
    _ url: URL, to place: URL, expecting bytes: Int64, progress: @escaping @Sendable (Double?) -> Void
  ) async throws {
    let courier = Courier(place: place, bytes: bytes, progress: progress)
    let session = URLSession(configuration: .ephemeral, delegate: courier, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let task = session.downloadTask(with: url)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, Error>) in
        courier.waiting = waiting
        task.resume()
      }
    } onCancel: { task.cancel() }
  }

  private final class Courier: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let place: URL
    let bytes: Int64
    let progress: @Sendable (Double?) -> Void
    var waiting: CheckedContinuation<Void, Error>?
    private var problem: Error?

    init(place: URL, bytes: Int64, progress: @escaping @Sendable (Double?) -> Void) {
      self.place = place
      self.bytes = bytes
      self.progress = progress
    }

    func urlSession(
      _ session: URLSession, downloadTask: URLSessionDownloadTask,
      didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
      // Somebody else's idea of how much there is, and no end to it.
      if totalBytesWritten > bytes { downloadTask.cancel() }
      progress(min(1, Double(totalBytesWritten) / Double(max(bytes, 1))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
      if let answer = downloadTask.response as? HTTPURLResponse, answer.statusCode != 200 {
        problem = ProcessingError.conversionFailed(reason: "\(answer.url?.host ?? "The server") answered \(answer.statusCode): that version may not be there any more.")
        return
      }
      do { try FileManager.default.moveItem(at: location, to: place) } catch { problem = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      if let problem = problem ?? error {
        waiting?.resume(throwing: problem)
      } else {
        waiting?.resume()
      }
      waiting = nil
    }
  }

  static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func copyApp(from disk: URL, to folder: URL, mountedAt mount: URL) throws {
    let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try ExternalTools.run(hdiutil, ["attach", "-quiet", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, disk.path])
    defer { try? ExternalTools.run(hdiutil, ["detach", "-quiet", "-force", mount.path]) }
    guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
      throw ProcessingError.conversionFailed(reason: "There is no app on \(disk.lastPathComponent).")
    }
    // ditto keeps the signature whole.
    try ExternalTools.run(URL(fileURLWithPath: "/usr/bin/ditto"), [app.path, folder.appendingPathComponent(app.lastPathComponent).path])
  }

  /// The command of that name, wherever in the folder it was packed.
  private static func command(_ name: String, in folder: URL) -> URL? {
    let inside = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey])
    while let item = inside?.nextObject() as? URL {
      guard item.lastPathComponent == name,
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
            values.isRegularFile == true, values.isExecutable == true else { continue }
      return item
    }
    return nil
  }
}
