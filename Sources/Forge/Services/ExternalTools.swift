import Foundation

/// A converter Forge does not ship.
///
/// Nothing is bundled inside the app: a copy of somebody else's binary in
/// Forge's own bundle is their licence in Forge's repository. The Mac is asked
/// what it already has, however it got there; what it has not, `Toolbox`
/// fetches from whoever makes it. Both end up somewhere `locate` can find
/// them, and nothing else in the app needs to know which of the two happened.
struct ExternalTool: Hashable, Identifiable, Sendable {
  /// The executable's name, as it is called.
  let binary: String
  /// What it is known as, to people and to `Toolbox`.
  let name: String
  /// What having it adds, in the user's words.
  let adds: String
  /// Where it lives when it is an application, inside Applications.
  var insideApplications: String? = nil
  /// The kinds of file it gives more formats to. The Convert sheet offers to
  /// install it for these, and for nothing else.
  var serves: Set<ConvertKind> = []

  var id: String { binary }

  /// Where this tool is on this Mac, or nil if it is not here.
  var location: URL? {
    if let found = ExternalTools.locate(binary) { return found }
    guard let insideApplications else { return nil }
    let folders = [URL(fileURLWithPath: "/Applications"),
                   FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    return folders.map { $0.appendingPathComponent(insideApplications) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  var isInstalled: Bool { location != nil }

  static let blender = ExternalTool(
    binary: "Blender", name: "Blender", adds: "BLEND, and FBX to write",
    insideApplications: "Blender.app/Contents/MacOS/Blender", serves: [.model]
  )

  static let calibre = ExternalTool(
    binary: "ebook-convert", name: "calibre", adds: "MOBI, AZW3, FB2, LIT, PDB and more",
    insideApplications: "calibre.app/Contents/MacOS/ebook-convert", serves: [.document]
  )

  var release: Toolbox.Release? { Toolbox.releases[name] }

  /// How much there is to download.
  var weight: String {
    release.map { ByteCountFormatter.string(fromByteCount: $0.build.bytes, countStyle: .file) } ?? ""
  }
}

/// Where to look for tools, and what is there.
enum ExternalTools {

  /// The directories a command-line tool lands in on macOS, in the order a
  /// shell would search them. What Forge fetched itself first: it was asked
  /// for here, and is the version Forge was tried with.
  static var searchPaths: [String] {
    var paths = [
      Toolbox.shared.commands.path,
      "/opt/homebrew/bin",   // Apple silicon Homebrew
      "/usr/local/bin",      // Intel Homebrew, and most installers
      "/opt/local/bin",      // MacPorts
      "/usr/bin",
      "/bin",
    ]
    // Whatever else the user's shell would search. A GUI app inherits a bare
    // PATH, but when there is one it knows about places these five do not —
    // pipx, a Python user install, a hand-built tool in ~/bin.
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      paths.append(contentsOf: path.split(separator: ":").map(String.init))
    }
    paths.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path)
    // A pip install --user puts its commands in a versioned directory that no
    // shell profile mentions and no GUI app inherits, which is why Forge
    // reported fonttools missing on a Mac that had it.
    paths.append(contentsOf: pythonUserPaths)
    return paths
  }

  /// `~/Library/Python/<version>/bin`, for whichever versions are installed.
  /// Read rather than guessed: the version in that path is Python's, not ours.
  private static var pythonUserPaths: [String] {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Python")
    let versions = (try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )) ?? []
    return versions.map { $0.appendingPathComponent("bin").path }
  }

  /// Answers are remembered for the life of the app: a tool does not appear
  /// halfway through a conversion, and asking the filesystem for every card on
  /// every redraw makes the Capabilities screen stutter.
  private static let cache = Cache()

  static func locate(_ binary: String) -> URL? {
    cache.location(of: binary) { name in
      for path in searchPaths {
        let candidate = URL(fileURLWithPath: path).appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
        // An application started through a link does not find the rest of itself.
        return path == Toolbox.shared.commands.path ? candidate.resolvingSymlinksInPath() : candidate
      }
      return nil
    }
  }

  /// Forget what was found, so a tool installed while the app was open is
  /// noticed without a restart.
  static func forgetWhatWasFound() {
    cache.clear()
    // What pandoc reads and writes is pandoc's answer, and a pandoc that was
    // not here when it was asked answered nothing. Downloading one has to
    // count as a change of answer, or the formats it adds stay hidden until
    // the next launch.
    ExternalBridge.forgetToolFormats()
  }

  /// How much of a failing tool's complaint is kept. Enough for a stack of
  /// lines a person can read; not enough to matter.
  private static let keptErrorBytes = 64 * 1024

  /// The tail of what a tool said, gathered off another thread.
  private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
      lock.lock()
      buffer.append(chunk)
      if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
      lock.unlock()
    }

    var data: Data {
      lock.lock()
      defer { lock.unlock() }
      return buffer
    }
  }

  /// Run a tool and wait for it.
  ///
  /// Arguments are passed as a list, never as a string for a shell to parse:
  /// a file called `holiday photo; rm -rf.png` is an ordinary filename, and it
  /// must stay one.
  static func run(_ tool: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments

    // Whatever it has to say is kept, so a failure can say why rather than
    // just "it did not work" - but only the last of it, and drained on a queue
    // of its own. An unread pipe stops the tool dead once it fills, and this
    // thread has to stay free to notice a cancellation.
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice

    let collected = Collected(limit: keptErrorBytes)
    let reading = errors.fileHandleForReading
    DispatchQueue.global(qos: .utility).async {
      while true {
        let chunk = reading.availableData
        if chunk.isEmpty { break }
        collected.append(chunk)
      }
    }

    try process.run()

    // A cancelled conversion has to reach the tool itself. Dropping the task
    // and leaving ffmpeg to finish a film nobody is waiting for is not a
    // cancellation, it is a fan.
    while process.isRunning {
      if Task.isCancelled {
        process.terminate()
        process.waitUntilExit()
        throw CancellationError()
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    process.waitUntilExit()
    let said = collected.data

    guard process.terminationStatus == 0 else {
      let message = String(data: said, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw ProcessingError.conversionFailed(
        reason: message.isEmpty
          ? "\(tool.lastPathComponent) failed with status \(process.terminationStatus)"
          : "\(tool.lastPathComponent): \(message)"
      )
    }
  }

  /// What a tool says, where what it says is the answer. Its complaints go
  /// nowhere: kept in a pipe nobody reads, a damaged film fills it and the tool
  /// stops for ever. And stopped when whoever asked is.
  static func answer(of tool: URL, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let collected = Collected(limit: .max)
    let reading = DispatchGroup()
    guard (try? process.run()) != nil else { return "" }
    DispatchQueue.global(qos: .utility).async(group: reading) { collected.append(pipe.fileHandleForReading.readDataToEndOfFile()) }
    while process.isRunning {
      if Task.isCancelled { process.terminate() }
      Thread.sleep(forTimeInterval: 0.01)
    }
    reading.wait()
    return String(decoding: collected.data, as: UTF8.self)
  }

  private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String: URL?] = [:]

    func location(of binary: String, or search: (String) -> URL?) -> URL? {
      lock.lock()
      if let known = found[binary] {
        lock.unlock()
        return known
      }
      lock.unlock()

      let result = search(binary)

      lock.lock()
      found[binary] = result
      lock.unlock()
      return result
    }

    func clear() {
      lock.lock()
      found.removeAll()
      lock.unlock()
    }
  }
}
