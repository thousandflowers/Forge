import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import Forge

@MainActor
final class AroundTests: ToolTestCase {
  func test_theMenuKeepsOutOfAnApp() async throws {
    var app = "com.example.paint", count = 1
    let file = try Fixture.image(at: path("a.png"))
    let menu = DragMenu(hand: .init(changeCount: { count }, files: { [file] }, flags: { .shift }, app: { app }, isDown: { true }), shows: false)
    menu.ignored = ["com.example.paint"]
    menu.pressed()
    count += 1
    menu.dragged()
    XCTAssertFalse(menu.isWatching)
    app = "com.apple.finder"
    menu.pressed()
    count += 1
    menu.dragged()
    XCTAssertTrue(menu.isWatching)
    menu.stop()
  }

  func test_settingsAreRemembered() throws {
    var settings = AppSettings()
    settings.dragMenuIgnored = ["com.example.paint"]
    settings.spokenLanguage = "it-IT"
    XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).dragMenuIgnored, [])
  }

  func test_theLanguageIsForWhatIsSaid() {
    var settings = AppSettings()
    XCTAssertEqual(settings.addingLanguage(to: [], of: .wav), [])
    settings.spokenLanguage = "it-IT"
    XCTAssertEqual(settings.addingLanguage(to: [], of: .wav), [.recognizeText(languages: ["it-IT"])])
    XCTAssertEqual(settings.addingLanguage(to: [], of: .png), [], "a picture is read in whatever it is written in")
    let said: [Forge.Operation] = [.recognizeText(languages: ["fr-FR"])]
    XCTAssertEqual(settings.addingLanguage(to: said, of: .wav), said)
  }

  func test_theMenuAsksWhatIsSpoken_onceItMatters() throws {
    try XCTSkipIf(AskOptions.spoken.count < 2, "one language is nothing to choose")
    let wav = try Fixture.audio(at: path("a.wav"), seconds: 0.2)
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: try ProcessableFile(url: wav), convert: { _, _ in [] })
    XCTAssertFalse(session.questions.contains(.language))
    session.choose(.format(.flac), for: .format)
    XCTAssertFalse(session.questions.contains(.language))
    session.choose(.format(.plainText), for: .format)
    XCTAssertTrue(session.questions.contains(.language))
    XCTAssertEqual(
      session.request.answered(with: [.format: .format(.plainText), .language: .language("it-IT")]).actions,
      [.convertFormat(to: .plainText), .recognizeText(languages: ["it-IT"])]
    )
  }

  func test_whatTheFinderHandsOver() {
    let pasteboard = NSPasteboard(name: .init("forge-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.png") as NSURL, URL(fileURLWithPath: "/tmp/b.png") as NSURL])
    let service = FinderService()
    var got: [URL] = []
    service.convert = { got = $0 }
    var problem: NSString = ""
    service.convertFiles(pasteboard, userData: "", error: &problem)
    XCTAssertEqual(got.map(\.lastPathComponent), ["a.png", "b.png"])
    pasteboard.clearContents()
    service.cutFile(pasteboard, userData: "", error: &problem)
    XCTAssertEqual(problem, "There are no files to cut.")
  }
}

final class ReadyWordTests: ToolTestCase {
  func test_everyWordIsItsOwn() {
    let words = ReadyWords.entries.compactMap(\.preset.nameTrigger)
    XCTAssertEqual(words.count, ReadyWords.entries.count)
    XCTAssertEqual(Set(words).count, words.count)
    for word in words {
      XCTAssertNil(Tool(word: word), "\(word) is a tool's")
      XCTAssertNil(NameTokens.Ask(rawValue: word))
      XCTAssertTrue(NameTokens.read("a_\(word).jpg").isEmpty, word)
    }
  }

  func test_theySurviveBeingSaved() throws {
    for entry in ReadyWords.entries {
      XCTAssertEqual(try JSONDecoder().decode(RulePreset.self, from: JSONEncoder().encode(entry.preset)), entry.preset)
    }
  }

  /// Every one of them, on a file of its kind.
  func test_theyAllWork() async throws {
    let film = try await Fixture.video(at: path("film.mp4"), seconds: 2)
    let picture = path("picture.jpg")
    try Quarters.image(at: picture, width: 1600, height: 1200)
    let sound = try Fixture.audio(at: path("sound.wav"), seconds: 2)
    // What somebody says cannot be made here, nor a thing to cut out.
    let needsMore: Set<String> = ["subs", "text", "sticker"]
    for entry in ReadyWords.entries where !needsMore.contains(entry.preset.nameTrigger!) {
      if entry.preset.actions.film != nil, ExternalTools.locate("ffmpeg") == nil { continue }
      let source = entry.preset.category == .image ? picture : entry.preset.category == .video ? film : sound
      XCTAssertTrue(entry.preset.accepts(source), entry.preset.name)
      let made = try await run([], on: source, more: entry.preset.actions)
      XCTAssertGreaterThan(size(of: made[0]), 0, entry.preset.name)
    }
  }

  /// A step from a newer Forge is a preset this one cannot run, and the rest
  /// of the list is what it was.
  func test_aNewerPresetIsLeftOut() async throws {
    let list = #"""
    [{"author":"a","summary":"s","preset":{"name":"Old","category":"image","actions":[{"kind":"quality","level":70}]}},
     {"author":"a","summary":"s","preset":{"name":"New","category":"image","actions":[{"kind":"tool","word":"teleport"}]}}]
    """#
    let gallery = PresetGallery(load: { _ in Data(list.utf8) })
    let names = try await gallery.entries().map(\.preset.name)
    XCTAssertEqual(names, ["Old"])
  }
}
