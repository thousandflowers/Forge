import Foundation

/// A converter Forge does not ship, and where to get it.
///
/// Forge does not download or bundle these. A pack downloaded by the app would
/// be code Forge did not build, which needs a pinned source, a checksum and a
/// signature to be honest about — and in FFmpeg's case would pull its licence
/// onto Forge. Asking the Mac what it already has costs none of that, and the
/// install is the one command the user would have typed anyway.
struct ExternalTool: Hashable, Identifiable, Sendable {
  /// The executable's name, as it is called.
  let binary: String
  /// The Homebrew formula that provides it.
  let formula: String
  /// What having it adds, in the user's words.
  let adds: String

  var id: String { binary }

  /// Where this tool is on this Mac, or nil if it is not here.
  var location: URL? { ExternalTools.locate(binary) }

  var isInstalled: Bool { location != nil }

  /// The command that installs it. Shown and copied, never run behind the
  /// user's back: it writes to their machine, so they run it.
  var installCommand: String { "brew install \(formula)" }
}

/// Where to look for tools, and what is there.
enum ExternalTools {

  /// The directories a command-line tool lands in on macOS, in the order a
  /// shell would search them. Homebrew first, because a Homebrew build is
  /// newer than whatever the system shipped.
  static var searchPaths: [String] {
    var paths = [
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
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      }
      return nil
    }
  }

  /// Forget what was found, so a tool installed while the app was open is
  /// noticed without a restart.
  static func forgetWhatWasFound() { cache.clear() }

  /// Whether Homebrew itself is here, which decides whether offering the
  /// install command makes any sense.
  static var hasHomebrew: Bool { locate("brew") != nil }

  /// Install a tool with Homebrew, from inside the app.
  ///
  /// The formula is one of Forge's own — never something typed in — and it is
  /// passed as an argument rather than a shell string, so there is nothing for
  /// a shell to reinterpret. Output is handed back line by line, because an
  /// install that takes two minutes with no sign of life reads as a hang.
  static func install(_ tool: ExternalTool, onOutput: @escaping @Sendable (String) -> Void) async throws {
    guard let brew = locate("brew") else {
      throw ProcessingError.conversionFailed(
        reason: "Homebrew is not installed. brew.sh has the one line that installs it."
      )
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let process = Process()
      process.executableURL = brew
      process.arguments = ["install", tool.formula]

      // Homebrew asks questions when it thinks a person is watching. Nobody is.
      var environment = ProcessInfo.processInfo.environment
      environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      environment["HOMEBREW_NO_ENV_HINTS"] = "1"
      environment["NONINTERACTIVE"] = "1"
      process.environment = environment

      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe

      pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") where !line.isEmpty {
          onOutput(String(line))
        }
      }

      process.terminationHandler = { finished in
        pipe.fileHandleForReading.readabilityHandler = nil
        forgetWhatWasFound()
        if finished.terminationStatus == 0 {
          continuation.resume()
        } else {
          continuation.resume(throwing: ProcessingError.conversionFailed(
            reason: "brew install \(tool.formula) stopped with status \(finished.terminationStatus)"
          ))
        }
      }

      do {
        try process.run()
      } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(throwing: error)
      }
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
    // just "it did not work".
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = Pipe()

    try process.run()
    let said = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

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
