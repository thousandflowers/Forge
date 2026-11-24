import Foundation
import UniformTypeIdentifiers

/// A file given another extension, to be made into what it is now called.
///
/// The extension it had is given back first. What is converted is then a file
/// that says what it is, and if it cannot be converted after all it is still
/// the file it was.
struct Retype {
  let from: String
  let to: String
  let preset: RulePreset

  /// - Parameter before: what the file was called.
  static func wanted(of url: URL, before: String) -> Retype? {
    let to = url.pathExtension, claimed = (before as NSString).pathExtension
    guard !to.isEmpty, claimed.lowercased() != to.lowercased(), let target = FormatCatalog.type(named: to) else { return nil }
    let from = Signature.fits(url, claimed) == false ? Signature.telling(url) ?? claimed : claimed
    // Nothing but another spelling, or a wrong name put right.
    guard !from.isEmpty, let own = FormatCatalog.type(named: from), own != target else { return nil }
    guard let file = standIn(for: url, called: from), file.fileType != target, Conversions.can(file, become: target) else { return nil }
    var preset = RulePreset(name: "From its name", description: "", category: .custom, actions: [.convertFormat(to: target)])
    // Where there are none, the name is only a name, underscores and all.
    preset.readsTools = !NameTokens.read(url.lastPathComponent).tools.isEmpty
    preset.outputExtension = to.lowercased()
    preset.nameTemplate = "{name}"
    return Retype(from: from, to: to, preset: preset)
  }

  /// Give it back the extension of what it is.
  func putBack(_ url: URL) throws -> URL {
    let folder = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
    var place = folder.appendingPathComponent("\(stem).\(from)"), attempt = 2
    while FileManager.default.fileExists(atPath: place.path) {
      place = folder.appendingPathComponent("\(stem) \(attempt).\(from)")
      attempt += 1
    }
    try FileManager.default.moveItem(at: url, to: place)
    return place
  }

  /// The same file under the name it ought to have, to be asked about: what can
  /// be made of a file is told by its extension.
  private static func standIn(for url: URL, called ext: String) -> ProcessableFile? {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ForgeRetype-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let link = folder.appendingPathComponent("file.\(ext)")
    guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
          (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)) != nil else { return nil }
    return try? ProcessableFile(url: link)
  }
}
