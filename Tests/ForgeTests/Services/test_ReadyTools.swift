import XCTest
import UniformTypeIdentifiers
@testable import Forge

final class ReadyToolTests: ToolTestCase {
  func test_everyKindIsAPresetThatIsReady() throws {
    XCTAssertEqual(ReadyTools.entries.count, Tool.Kind.allCases.count)
    let all = ReadyWords.entries + ReadyTools.entries
    XCTAssertEqual(Set(all.map(\.id)).count, all.count, "each by a name of its own")
    for (entry, kind) in zip(ReadyTools.entries, Tool.Kind.allCases) {
      XCTAssertTrue(entry.preset.actions.contains(.tool(kind.blank)), entry.preset.name)
      XCTAssertEqual(try JSONDecoder().decode(RulePreset.self, from: JSONEncoder().encode(entry.preset)), entry.preset)
    }
  }

  func test_theyTakeTheFilesTheyAreFor() throws {
    func takes(_ kind: Tool.Kind, _ name: String) throws -> Bool {
      try XCTUnwrap(ReadyTools.entries.first { $0.preset.actions.contains(.tool(kind.blank)) }).preset.accepts(URL(fileURLWithPath: "/\(name)"))
    }
    XCTAssertTrue(try takes(.numbers, "a.pdf"))
    XCTAssertFalse(try takes(.numbers, "a.docx"))
    XCTAssertTrue(try takes(.layers, "a.psd"))
    XCTAssertFalse(try takes(.layers, "a.jpg"))
    XCTAssertTrue(try takes(.tidy, "a.css"))
    XCTAssertFalse(try takes(.slowMotion, "a.mp3"))
    XCTAssertTrue(try takes(.gray, "a.mov"))
    XCTAssertTrue(try takes(.gray, "a.jpg"))
  }

  /// Run as presets, whatever the file is called.
  func test_theyWorkAsPresets() async throws {
    let picture = try Fixture.image(at: path("p.png")), document = try Fixture.pdf(at: path("d.pdf"), pages: 3)
    let sound = try Fixture.audio(at: path("s.wav"), seconds: 2, channels: 2), film = try await Fixture.video(at: path("f.mov"), seconds: 2)
    let code = path("c.css")
    try "a { b : c }".write(to: code, atomically: true, encoding: .utf8)
    let jobs: [(Tool.Kind, URL)] = [
      (.enhance, picture), (.upscale, picture), (.gray, picture), (.round, picture), (.tile, picture), (.gray, film), (.rate, film), (.mono, sound),
      (.fade, sound), (.pitch, sound), (.numbers, document), (.sheet, document), (.dpi, document), (.tidy, code),
    ]
    for (kind, source) in jobs {
      let preset = try XCTUnwrap(ReadyTools.entries.first { $0.preset.actions.contains(.tool(kind.blank)) }).preset
      let entry = try await coordinator().processFile(
        try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: try folder("o-\(UUID().uuidString)")
      ) { _ in }
      XCTAssertGreaterThan(size(of: try XCTUnwrap(entry.outputURL)), 0, kind.rawValue)
    }
  }

  func test_theWindowOffersWhatSuitsTheFiles() throws {
    func words(_ names: String...) throws -> [String] {
      try Tool.all(for: names.map { name in
        let url = path(name)
        if !exists(url) { try Data([1]).write(to: url) }
        return try ProcessableFile(url: url)
      }).map(\.word)
    }
    let picture = try words("a.jpg")
    XCTAssertEqual(picture.first, "nobg", "what is reached for comes first")
    for word in ["enhance", "upscale2x", "scan", "gray", "blurbg", "round40", "grid3x3", "tables"] { XCTAssertTrue(picture.contains(word), word) }
    XCTAssertFalse(picture.contains("layers"))
    XCTAssertTrue(try words("a.psd").contains("layers"))
    for word in ["slowmo2x", "at10s", "fps30", "1080p", "nobg", "voice", "mono", "fade2s", "pitch+2", "nosilence"] { XCTAssertTrue(try words("a.mp4").contains(word), word) }
    for word in ["askpassword", "unlock", "numbers", "2up", "dpi300", "images", "tables"] { XCTAssertTrue(try words("a.pdf").contains(word), word) }
    for name in ["a.css", "a.json", "a.xml", "a.js"] { XCTAssertTrue(try words(name).contains("pretty"), name) }
    XCTAssertEqual(try words("a.jpg", "a.mp4"), [], "two kinds have no tools in common")
    XCTAssertFalse(try words("a.jpg", "a.psd").contains("layers"), "not all of them have any")
    XCTAssertEqual(Set(picture).count, picture.count)
  }

  func test_choosingAndUnchoosing() {
    let start = ConvertChoice().choosing(.png)
    let gray = start.toggling(.gray)
    XCTAssertEqual(gray.draft.actions, [.convertFormat(to: .png), .tool(.gray)])
    XCTAssertEqual(gray.choosing(.jpeg).draft.actions, [.convertFormat(to: .jpeg), .tool(.gray)], "another format keeps it")
    XCTAssertEqual(gray.toggling(.gray).draft.actions, start.draft.actions)
    XCTAssertEqual(ConvertChoice().toggling(.upscale(2)).toggling(.upscale(3)).draft.actions, [.tool(.upscale(3))], "one of a kind")
    XCTAssertNotNil(ConvertChoice().toggling(.gray).resolved(against: []), "enough by itself")
    let preset = RulePreset(name: "Mine", description: "", category: .image, actions: [.quality(level: 70)])
    let changed = ConvertChoice().adopting(preset).toggling(.gray)
    XCTAssertNil(changed.presetID)
    XCTAssertEqual(changed.draft.actions, [.quality(level: 70), .tool(.gray)])
  }
}
