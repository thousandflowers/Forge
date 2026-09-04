import Foundation

/// Decides whether this launch is the app or the command line.
///
/// Forge ships one binary. Double-clicked, it opens a window; run with
/// arguments, or through the `forge` symlink, it behaves as a command-line
/// tool. Keeping the decision in one pure function makes it testable, which
/// matters because getting it wrong means the app silently refuses to open.
enum LaunchMode {
  /// The name the command-line tool is installed under.
  static let toolName = "forge"

  /// Arguments macOS itself adds when launching a bundled app. They are not
  /// ours and must never be mistaken for a command.
  private static let systemPrefixes = ["-psn_", "-NS", "-Apple", "-XCTest", "-com.apple."]

  static func isCommandLine(arguments: [String] = CommandLine.arguments) -> Bool {
    guard let executable = arguments.first else { return false }

    // Invoked through the `forge` symlink: always the tool, even bare, so that
    // `forge` on its own prints help instead of opening a window.
    if URL(fileURLWithPath: executable).lastPathComponent == toolName { return true }

    return !userArguments(from: arguments).isEmpty
  }

  /// The arguments meant for us, with the launcher's own stripped out.
  static func userArguments(from arguments: [String] = CommandLine.arguments) -> [String] {
    arguments.dropFirst().filter { argument in
      !systemPrefixes.contains { argument.hasPrefix($0) }
    }
  }
}
