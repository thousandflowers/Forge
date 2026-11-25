import Foundation

/// Presets other people have made, fetched from a published list.
///
/// A preset is data, not code: a name and a list of actions drawn from a
/// closed set the app already knows how to run. Installing one cannot make
/// Forge do anything it could not already do, which is what makes a gallery
/// reasonable where a downloadable binary would not be.
extension RulePreset {
  /// The same, naming no file on the Mac it was made on.
  var withoutFilesOfItsOwn: RulePreset {
    func clean(_ operation: Operation) -> Operation {
      switch operation {
      case .film(var film):
        film.lut = nil
        film.filters = nil
        return .film(film)
      case .when(let condition, let then, let otherwise): return .when(condition, then: then.map(clean), otherwise: otherwise.map(clean))
      case .split(let branches): return .split(branches.map { Branch(name: $0.name, actions: $0.actions.map(clean)) })
      default: return operation
      }
    }
    var copy = self
    copy.actions = actions.map(clean)
    return copy
  }
}

private extension RulePreset {
  /// Written by a tool that is here.
  var isCarriedByATool: Bool { withoutFilesOfItsOwn == self && (targetFormat.map(ExternalBridge.canWrite) ?? false) }
}

actor PresetGallery {

  /// Where the published list lives. Contributions are pull requests against
  /// that file, so the history of who added what is public.
  static let indexURL = URL(
    string: "https://raw.githubusercontent.com/thousandflowers/Forge/main/Gallery/presets.json"
  )!

  /// One entry in the list.
  struct Entry: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(author)/\(preset.name)" }
    /// Who contributed it, as a GitHub handle.
    let author: String
    /// A sentence on what it is for.
    let summary: String
    let preset: RulePreset
    /// What it is about, in a word or two: the shelf somebody browsing would
    /// look on. Optional, because the published list predates it and every
    /// entry already out there has to keep decoding.
    let tags: [String]?
  }

  private let source: URL
  private let load: @Sendable (URL) async throws -> Data

  /// - Parameter load: how the bytes arrive. Tests hand it a local file so the
  ///   suite never touches the network.
  init(
    source: URL = PresetGallery.indexURL,
    load: @escaping @Sendable (URL) async throws -> Data = { url in
      try await URLSession.shared.data(from: url).0
    }
  ) {
    self.source = source
    self.load = load
  }

  /// The published presets, minus any this machine could not run anyway, and
  /// minus any that a newer Forge would understand: one step this one has never
  /// heard of used to take the whole list with it.
  func entries() async throws -> [Entry] {
    let data = try await load(source)
    let entries = try JSONDecoder().decode([Readable].self, from: data).compactMap(\.entry)
    return entries.filter { Self.isRunnable($0.preset) || $0.preset.isCarriedByATool || Self.toolNeeded(by: $0.preset) != nil }
  }

  private struct Readable: Decodable {
    let entry: Entry?
    init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
  }

  /// What a preset needs that is not on this Mac, if having it is enough.
  static func toolNeeded(by preset: RulePreset) -> ExternalTool? {
    guard preset.withoutFilesOfItsOwn == preset else { return nil }
    let binary: String
    if preset.actions.contains(where: { if case .film = $0 { return true } else { return false } }) {
      binary = "ffmpeg"
    } else {
      guard let format = preset.targetFormat, !isRunnable(preset), !ExternalBridge.canWrite(format),
            let needed = ExternalBridge.writer(of: format) else { return nil }
      binary = needed
    }
    return ToolOffers.all.first { $0.binary == binary && !$0.isInstalled }
  }

  /// Whether every action in a preset means something on this machine. A
  /// gallery entry that targets a format this Mac cannot write is not worth
  /// offering; it would only fail later.
  static func isRunnable(_ preset: RulePreset) -> Bool {
    // Somebody else's preset has no business naming a file on this Mac.
    guard preset.withoutFilesOfItsOwn == preset else { return false }
    guard let format = preset.targetFormat else { return true }
    return FormatCatalog.isWritableImage(format)
      || FormatCatalog.audioFormatID(for: format) != nil
      || FormatCatalog.isWritableVideo(format)
      || FormatCatalog.isWritableModel(format)
      || DocumentText.canWrite(format)
      || Subtitles.writes(Conversions.fileExtension(of: format))
  }
}
