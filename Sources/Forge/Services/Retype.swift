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
  let stem: String
  let preset: RulePreset

  /// What somebody meant by a name they typed.
  enum Meaning {
    case become(Retype)
    /// Nothing that can be told, or nothing that can be made: what it was called.
    case stay(Retype)
  }

  /// - Parameter before: what the file was called.
  static func wanted(of url: URL, before: String) -> Retype? {
    wanted(of: url, before: before, as: url.pathExtension, stem: url.deletingPathExtension().lastPathComponent)
  }

  private static func wanted(of url: URL, before: String, as to: String, stem: String) -> Retype? {
    let claimed = (before as NSString).pathExtension
    guard !to.isEmpty, claimed.lowercased() != to.lowercased(), let target = FormatCatalog.type(named: to) else { return nil }
    let from = trueExtension(of: url, claimed: claimed)
    // Nothing but another spelling, or a wrong name put right.
    guard !from.isEmpty, let own = FormatCatalog.type(named: from), own != target else { return nil }
    guard let file = standIn(for: url, called: from), file.fileType != target, isMade(of: file, called: to, target, from: url) || Self.tool(in: "\(stem).\(from)", makes: target) else { return nil }
    var preset = RulePreset(name: "From its name", description: "", category: .custom, actions: [.convertFormat(to: target)])
    // Where there are none, the name is only a name, underscores and all.
    preset.readsTools = [to, from].contains { !NameTokens.read("\(stem).\($0)").tools.isEmpty }
    preset.outputExtension = to.lowercased()
    preset.nameTemplate = "{name}"
    return Retype(from: from, to: to, stem: stem, preset: preset)
  }

  /// The same, of a name typed by hand: a slip of the finger is seen through
  /// where there is one thing it can be, and undone where there is not.
  static func meant(by url: URL, before: String) -> Meaning? {
    let name = url.lastPathComponent
    // Something put after the whole of the old name - `.bak`, `.old` - is meant.
    guard !name.lowercased().hasPrefix(before.lowercased() + ".") else { return nil }
    let (stem, typed) = split(name)
    guard !typed.isEmpty, !stem.isEmpty else { return nil }
    let from = trueExtension(of: url, claimed: (before as NSString).pathExtension)
    guard let own = FormatCatalog.type(named: from), let file = standIn(for: url, called: from) else { return nil }
    let stay = Meaning.stay(Retype(from: from, to: typed, stem: stem, preset: RulePreset(name: "From its name", description: "", category: .custom)))
    if let job = wanted(of: url, before: before, as: typed, stem: stem) { return .become(job) }
    // Known, and not to be made of this: left alone unless it is plainly untrue.
    if FormatCatalog.type(named: typed) != nil, Signature.fits(url, typed) != false { return nil }
    guard let meant = nearest(to: typed, for: file, own: own), FormatCatalog.type(named: meant) != own,
          let job = wanted(of: url, before: before, as: meant, stem: stem) else { return stay }
    return .become(job)
  }

  /// What Forge offers to make of it, or what it plainly is not and can be made.
  /// Not everything that can be written: words can be written under any name, and
  /// `notes.txt` called `notes.py` is still the same words.
  private static func isMade(of file: ProcessableFile, called to: String, _ target: UTType, from url: URL) -> Bool {
    if offered(for: file).contains(where: { names(of: $0).contains(to.lowercased()) }) { return true }
    return Signature.knows(to) && Signature.fits(url, to) == false && Conversions.can(file, become: target)
  }

  /// A word that makes another kind of thing, and this is that kind: the tables
  /// of a PDF in a CSV, which is nothing a PDF becomes otherwise.
  private static func tool(in name: String, makes target: UTType) -> Bool {
    let chain = NameTokens.applying(to: [], from: name)
    guard chain.contains(where: \.isFormat) else { return false }
    return NameTokens.applying(to: [.convertFormat(to: target)], from: name).contains(.convertFormat(to: target))
  }

  private static func offered(for file: ProcessableFile) -> [UTType] {
    ConvertKind(fileType: file.fileType)?.outputGroups(for: [file]).flatMap(\.formats).compactMap(\.type) ?? []
  }

  private static func names(of type: UTType) -> [String] {
    ([Conversions.fileExtension(of: type)] + (type.tags[.filenameExtension] ?? [])).map { $0.lowercased() }
  }

  private static func trueExtension(of url: URL, claimed: String) -> String {
    Signature.fits(url, claimed) == false ? Signature.telling(url) ?? claimed : claimed
  }

  /// The name and the extension, with a comma for the dot or a space after it.
  private static func split(_ name: String) -> (stem: String, ext: String) {
    let tidy = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;")))
    guard let dot = tidy.lastIndex(where: { ".,;".contains($0) }) else { return (tidy, "") }
    let stem = tidy[..<dot].trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
    return (stem, tidy[tidy.index(after: dot)...].trimmingCharacters(in: .whitespaces))
  }

  /// The one extension a letter away, of those this file can be given.
  private static func nearest(to typed: String, for file: ProcessableFile, own: UTType) -> String? {
    let typed = typed.lowercased()
    guard typed.count > 1 else { return nil }
    func close(_ types: [UTType]) -> [String] {
      var found: [UTType: String] = [:]
      for type in types where found[type] == nil { found[type] = names(of: type).first { isOneSlip($0, typed) } }
      return Array(found.values)
    }
    // What people have files of, before what few have heard of.
    let common = ConvertKind(fileType: file.fileType).map { kind in
      kind.leading(of: kind.outputGroups(for: [file]).flatMap(\.formats)).compactMap(\.type)
    } ?? []
    let first = close([own] + common)
    guard first.isEmpty else { return first.count == 1 ? first[0] : nil }
    let rest = close(offered(for: file))
    return rest.count == 1 ? rest[0] : nil
  }

  /// One letter more, fewer or other, or two that changed places.
  static func isOneSlip(_ first: String, _ second: String) -> Bool {
    let a = Array(first), b = Array(second)
    guard a != b, !a.isEmpty, !b.isEmpty, abs(a.count - b.count) <= 1 else { return false }
    let same = zip(a, b).prefix { $0 == $1 }.count
    let x = Array(a.dropFirst(same)), y = Array(b.dropFirst(same))
    if a.count > b.count { return Array(x.dropFirst()) == y }
    if a.count < b.count { return x == Array(y.dropFirst()) }
    if Array(x.dropFirst()) == Array(y.dropFirst()) { return true }
    return x.count > 1 && x[0] == y[1] && x[1] == y[0] && Array(x.dropFirst(2)) == Array(y.dropFirst(2))
  }

  /// Why it is what it was.
  var whyNot: String {
    // A format a tool would add is known, whether or not the tool is here.
    let isKnown = FormatCatalog.type(named: to) != nil || Capabilities.all.contains { $0.evidence.contains(to.lowercased()) }
    return !isKnown ? "“.\(to)” is not a format Forge knows." : "It cannot become \(to.uppercased())."
  }

  /// Give it back the extension of what it is.
  func putBack(_ url: URL) throws -> URL {
    let folder = url.deletingLastPathComponent()
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
