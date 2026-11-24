import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// What a tool is called is what it does: the same word in a file's name, in a
/// saved preset and on the command line.
final class ToolWordTests: XCTestCase {
  func test_everyWordSaysWhatItDoes() {
    let words: [(String, Tool)] = [
      ("mute", .mute),
      ("normalize", .normalize),
      ("reverse", .reverse),
      ("lighter", .lighter),
      ("nobg", .removeBackground),
      ("speed2x", .speed(2)),
      ("speed0.5x", .speed(0.5)),
      ("loop3", .loop(3)),
      ("rotate90", .turn(.right)),
      ("rotate180", .turn(.half)),
      ("rotate270", .turn(.left)),
      ("mirror", .turn(.mirror)),
      ("flip", .turn(.flip)),
      ("trim10-45", .trim(Span(from: 10, to: 45))),
      ("trim10-", .trim(Span(from: 10, to: nil))),
      ("trim-45", .trim(Span(from: nil, to: 45))),
      ("trim1.5-3", .trim(Span(from: 1.5, to: 3))),
      ("trim10-45fast", .trim(Span(from: 10, to: 45), fast: true)),
      ("split30s", .divide(.every(30))),
      ("split4", .divide(.parts(4))),
      ("splitchapters", .divide(.chapters)),
      ("splitpages", .divide(.pages(1))),
      ("split10pages", .divide(.pages(10))),
      ("crop1x1", .crop(.shape(1, 1))),
      ("crop16x9", .crop(.shape(16, 9))),
      ("crop120,40,800x600", .crop(.box(x: 120, y: 40, width: 800, height: 600))),
      ("pages2-5", .pages(PageList("2-5")!)),
      ("pages3,1,7-", .pages(PageList("3,1,7-")!)),
      ("nopages2-5", .dropPages(PageList("2-5")!)),
      ("frames5s", .frames(every: 5)),
    ]
    for (word, tool) in words {
      XCTAssertEqual(Tool(word: word), tool, word)
      XCTAssertEqual(tool.word, word)
    }
  }

  /// Written another way, the same thing.
  func test_otherSpellings() {
    XCTAssertEqual(Tool(word: "SPEED1,5X"), .speed(1.5))
    XCTAssertEqual(Tool(word: "trim1m20-2m05"), .trim(Span(from: 80, to: 125)))
    XCTAssertEqual(Tool(word: "trim1h2m3s-"), .trim(Span(from: 3723, to: nil)))
    XCTAssertEqual(Tool(word: "trim1:20-2:05"), .trim(Span(from: 80, to: 125)))
    XCTAssertEqual(Tool(word: "split2m"), .divide(.every(120)))
    XCTAssertEqual(Tool(word: "page2-5"), .pages(PageList("2-5")!))
    XCTAssertEqual(Tool(word: "rotateright"), .turn(.right))
    XCTAssertEqual(Tool(word: "rotateleft"), .turn(.left))
  }

  func test_whatIsNotAnInstruction() {
    for word in ["", "speed", "speed0x", "speed99x", "trim", "trim-", "trim45-10", "trim10", "split1", "split0s", "loop1", "loop999",
                 "crop", "crop0x1", "rotate45", "pages", "page2", "pages0", "pages5-2x", "mutes", "reverse2", "frames0s"] {
      XCTAssertNil(Tool(word: word), word)
    }
  }

  func test_aToolSurvivesBeingSaved() throws {
    for word in ["speed1.5x", "trim10-45fast", "crop120,40,800x600", "pages3,1,7-"] {
      let operation = Forge.Operation.tool(try XCTUnwrap(Tool(word: word)))
      let back = try JSONDecoder().decode(Forge.Operation.self, from: JSONEncoder().encode(operation))
      XCTAssertEqual(back, operation)
    }
  }

  /// Two tools of different kinds are two steps; of one kind, the later one.
  func test_replacingIsByKind() {
    let preset = RulePreset(name: "a", description: "", category: .video, actions: [.tool(.mute), .tool(.speed(2))])
    XCTAssertEqual(preset.replacing(.tool(.speed(3))).actions, [.tool(.mute), .tool(.speed(3))])
  }
}

final class PageListTests: XCTestCase {
  func test_pagesInTheOrderTheyAreSaid() {
    XCTAssertEqual(PageList("3,1")?.indices(of: 5), [2, 0])
    XCTAssertEqual(PageList("2-4")?.indices(of: 5), [1, 2, 3])
    XCTAssertEqual(PageList("4-")?.indices(of: 5), [3, 4])
    XCTAssertEqual(PageList("-2")?.indices(of: 5), [0, 1])
    XCTAssertEqual(PageList("5-3")?.indices(of: 5), [4, 3, 2], "backwards is an order too")
  }

  func test_pagesThatAreNotThereAreLeftOut() {
    XCTAssertEqual(PageList("4-9")?.indices(of: 5), [3, 4])
    XCTAssertEqual(PageList("9")?.indices(of: 5), [])
  }
}

final class ToolNameTests: XCTestCase {
  private func tools(_ name: String) -> [Tool] { NameTokens.read(name).tools }

  func test_namesCarryTools() {
    XCTAssertEqual(tools("video_mute_speed2x.mp4"), [.mute, .speed(2)])
    XCTAssertEqual(tools("photo_crop1x1_rotate90.jpg"), [.crop(.shape(1, 1)), .turn(.right)])
    XCTAssertEqual(tools("thesis_pages2-5.pdf"), [.pages(PageList("2-5")!)])
    XCTAssertEqual(tools("clip_trim10-45_2MB.mov"), [.trim(Span(from: 10, to: 45))])
  }

  /// A word that means nothing for that kind of file is part of its name.
  func test_aWordThatDoesNotSuitTheFileIsAName() {
    XCTAssertEqual(tools("study_reverse.pdf"), [])
    XCTAssertEqual(tools("song_nobg.mp3"), [])
    XCTAssertEqual(tools("song_mute.mp3"), [])
    XCTAssertEqual(tools("scan_page2.pdf"), [], "what a scanner calls the second page")
    XCTAssertEqual(tools("odd_mirror.csv"), [])
  }

  func test_noMeta() {
    XCTAssertEqual(NameTokens.read("a_nometa.jpg").privacy, .stripAll)
  }

  /// Done twice a rotation is another picture, so the word goes once it is done.
  func test_theWordIsSpent() {
    XCTAssertEqual(NameTokens.spent("video_mute_speed2x.mp4"), "video")
    XCTAssertEqual(NameTokens.spent("video_mute_2MB.mp4"), "video_2MB")
    XCTAssertEqual(NameTokens.spent("holiday_2MB.jpg"), "holiday_2MB")
    XCTAssertEqual(NameTokens.spent("my_reverse_notes.mp4"), "my_reverse_notes")
    XCTAssertEqual(NameTokens.spent("mute.mp4"), "mute")
  }

  func test_aNameBeatsThePreset() {
    let chain = NameTokens.applying(to: [.tool(.speed(4)), .quality(level: 80)], from: "video_speed2x.mp4")
    XCTAssertEqual(chain, [.quality(level: 80), .tool(.speed(2))])
    XCTAssertEqual(NameTokens.applying(to: chain, from: "video_speed2x.mp4"), chain, "said again it changes nothing")
  }

  /// A cut-out has nothing to be put on in a JPEG.
  func test_aCutOutIsNotAJPEG() {
    let chain = NameTokens.applying(to: [.convertFormat(to: .jpeg)], from: "photo_nobg.heic")
    XCTAssertEqual(chain, [.convertFormat(to: .png), .tool(.removeBackground)])
    let png = NameTokens.applying(to: [.convertFormat(to: .tiff)], from: "photo_nobg.heic")
    XCTAssertEqual(png.first, .convertFormat(to: .tiff))
    XCTAssertEqual(NameTokens.applying(to: [], from: "photo_nobg.jpg"), [.convertFormat(to: .png), .tool(.removeBackground)])
  }

  func test_aRenamedFileIsTaken() {
    let web = RulePreset(name: "Web", description: "", category: .custom, actions: [.quality(level: 80)])
    XCTAssertEqual(
      Arrival.of(URL(fileURLWithPath: "/tmp/video_mute.mp4"), folderPreset: web, presets: [web], onlyWhenRenamed: true), .run(web)
    )
    XCTAssertEqual(
      Arrival.of(URL(fileURLWithPath: "/tmp/study_mute.pdf"), folderPreset: web, presets: [web], onlyWhenRenamed: true), .leave
    )
  }
}
