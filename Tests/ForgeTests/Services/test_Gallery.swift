import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// The published preset list.
///
/// The suite never touches the network: the gallery takes how the bytes arrive,
/// and the tests hand it a local file.
final class PresetGalleryTests: BaseTestCase {

  private func gallery(_ json: String) -> PresetGallery {
    PresetGallery(source: URL(fileURLWithPath: "/dev/null")) { _ in Data(json.utf8) }
  }

  func test_readsThePublishedList() async throws {
    let entries = try await gallery("""
    [{
      "author": "someone",
      "summary": "Small JPEGs.",
      "preset": {
        "name": "Web",
        "description": "",
        "category": "image",
        "actions": [
          { "kind": "convertFormat", "format": { "identifier": "public.jpeg" } },
          { "kind": "quality", "level": 70 }
        ]
      }
    }]
    """).entries()

    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].author, "someone")
    XCTAssertEqual(entries[0].preset.name, "Web")
    XCTAssertEqual(entries[0].preset.quality, 70)
  }

  /// A published preset targeting something this Mac cannot write is not worth
  /// offering; it would only fail later.
  func test_hidesWhatThisMacCannotRun() async throws {
    let entries = try await gallery("""
    [{
      "author": "someone",
      "summary": "WebP, which macOS cannot write.",
      "preset": {
        "name": "WebP",
        "description": "",
        "category": "image",
        "actions": [
          { "kind": "convertFormat", "format": { "identifier": "org.webmproject.webp" } }
        ]
      }
    }]
    """).entries()

    XCTAssertTrue(entries.isEmpty)
  }

  /// Installing gives a new identity, so adding the same one twice does not
  /// quietly replace a preset of yours.
  @MainActor
  func test_installingDoesNotReplaceYourOwn() {
    let model = AppModel(persistence: store)
    let published = RulePreset(name: "Web", description: "", category: .image)

    model.install(published)
    model.install(published)

    XCTAssertEqual(model.presets.count, 2)
    XCTAssertNotEqual(model.presets[0].id, model.presets[1].id)
  }

  /// The file that ships with the repository has to parse, or the gallery is
  /// broken for everyone the moment it is published.
  func test_theShippedListParses() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Services
      .deletingLastPathComponent()  // ForgeTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // the package root
      .appendingPathComponent("Gallery/presets.json")

    let data = try Data(contentsOf: url)
    let entries = try JSONDecoder().decode([PresetGallery.Entry].self, from: data)

    XCTAssertFalse(entries.isEmpty)
    for entry in entries {
      XCTAssertFalse(entry.author.isEmpty, "\(entry.preset.name) has no author")
      XCTAssertFalse(entry.summary.isEmpty, "\(entry.preset.name) has no summary")
      XCTAssertFalse(entry.preset.actions.isEmpty, "\(entry.preset.name) does nothing")
    }
  }
}
