import Foundation

/// Presets other people have made, fetched from a published list.
///
/// A preset is data, not code: a name and a list of actions drawn from a
/// closed set the app already knows how to run. Installing one cannot make
/// Forge do anything it could not already do, which is what makes a gallery
/// reasonable where a downloadable binary would not be.
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

  /// The published presets, minus any this machine could not run anyway.
  func entries() async throws -> [Entry] {
    let data = try await load(source)
    let entries = try JSONDecoder().decode([Entry].self, from: data)
    return entries.filter { Self.isRunnable($0.preset) }
  }

  /// Whether every action in a preset means something on this machine. A
  /// gallery entry that targets a format this Mac cannot write is not worth
  /// offering; it would only fail later.
  static func isRunnable(_ preset: RulePreset) -> Bool {
    guard let format = preset.targetFormat else { return true }
    return FormatCatalog.isWritableImage(format)
      || FormatCatalog.audioFormatID(for: format) != nil
      || FormatCatalog.isWritableVideo(format)
      || FormatCatalog.isWritableModel(format)
      || DocumentText.canWrite(format)
  }
}
