import Foundation

/// The list of tools Forge can fetch, and where each build lives.
///
/// Forge's core converts with Apple's frameworks and nothing else. An
/// extension is the exception, and it is described rather than assumed: a
/// version, a licence, the project it came from, the exact bytes expected.
/// Nothing is downloaded that this file did not name, and nothing is used that
/// did not hash to what this file said it would.
struct ExtensionManifest: Codable, Sendable {
  /// Bumped when the shape below changes. A manifest from the future is
  /// refused rather than half-read: a build this version cannot describe is
  /// not a build it should run.
  static let supportedSchemaVersion = 1

  let schemaVersion: Int
  let tools: [String: ExtensionInfo]

  /// The tools, each carrying the key it was filed under as its id.
  var extensions: [ExtensionInfo] {
    tools
      .map { key, info in var copy = info; copy.id = key; return copy }
      .sorted { $0.displayName < $1.displayName }
  }
}

/// One tool, in the words the user gets to read before anything is downloaded.
struct ExtensionInfo: Codable, Sendable, Identifiable, Hashable {
  /// The key in the manifest, which is also the name the executable is called
  /// by — `pandoc` is looked up as `pandoc`. Not in the JSON: it is the key.
  var id: String = ""

  let displayName: String
  let version: String
  let license: String
  let sourceURL: String
  let description: String
  let builds: [String: ExtensionBuild]

  private enum CodingKeys: String, CodingKey {
    case displayName, version, license, sourceURL, description, builds
  }

  /// The build for a given processor, or the one that will run on it.
  ///
  /// An Apple silicon Mac runs an Intel build through Rosetta, so falling back
  /// that way is a real answer. The other direction is not: an Intel Mac
  /// cannot run an arm64 binary, and offering it would be a download that ends
  /// in "Bad CPU type in executable".
  func build(for architecture: Architecture) -> ExtensionBuild? {
    if let exact = builds[architecture.rawValue] { return exact }
    guard architecture == .arm64 else { return nil }
    return builds[Architecture.x86_64.rawValue]
  }
}

/// One downloadable archive.
struct ExtensionBuild: Codable, Sendable, Hashable {
  let url: URL
  /// Hex SHA-256 of the archive as downloaded. Checked before anything is
  /// unpacked, let alone run.
  let sha256: String
  /// What the manifest says it weighs, so the user is told before agreeing to
  /// it rather than after.
  let sizeBytes: Int64
  /// Where the runnable binary sits inside the unpacked folder. An extension
  /// is a folder: a binary may travel with the dylibs, data or fonts it needs.
  let executablePath: String
}

/// The processors Forge ships builds for.
enum Architecture: String, Sendable, CaseIterable {
  case arm64
  case x86_64

  /// This build of Forge's own architecture, decided at compile time. `uname`
  /// would answer for the machine, which under Rosetta is not the same
  /// question.
  static var current: Architecture {
    #if arch(arm64)
    return .arm64
    #else
    return .x86_64
    #endif
  }
}

/// A tool that is on this Mac because Forge fetched it, and the receipt.
struct InstalledExtension: Codable, Sendable, Identifiable, Hashable {
  /// The tool's manifest key, and the name it is looked up by.
  let id: String
  let version: String
  /// The folder holding this version, under Application Support.
  let path: URL
  /// Where the binary is inside `path`.
  let executablePath: String
  /// What the archive hashed to when it was accepted.
  let sha256: String
  let installedAt: Date

  var executableURL: URL { path.appendingPathComponent(executablePath) }
}
