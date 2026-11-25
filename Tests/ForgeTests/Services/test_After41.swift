import XCTest
import UniformTypeIdentifiers
@testable import Forge

final class After41Tests: BaseTestCase {
  /// The word that asks is spent once it has been answered: it came out as
  /// `photo_ask.jpg`, to be asked about again.
  func test_theWordThatAskedIsNotInWhatComesOut() async throws {
    XCTAssertEqual(NameTokens.answered("photo_ask", ext: "png"), "photo")
    XCTAssertEqual(NameTokens.answered("photo_asksize_2MB", ext: "png"), "photo_2MB")
    XCTAssertEqual(NameTokens.answered("how_to_ask_for_it", ext: "pdf"), "how_to_ask_for_it")
    XCTAssertEqual(NameTokens.answered("ask", ext: "png"), "ask")

    let file = path("photo_ask.png")
    try Fixture.image(at: file, width: 20, height: 20)
    var preset = RulePreset(name: "x", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])
    func made() async throws -> String {
      let entry = try await coordinator().processFile(try ProcessableFile(url: file), with: preset, destinationMode: .copyTo, destinationURL: try folder("out\(preset.isAnswered)")) { _ in }
      return try XCTUnwrap(entry.outputURL).deletingPathExtension().lastPathComponent
    }
    let kept = try await made()
    XCTAssertEqual(kept, "photo_ask", "a name is a name, where nobody asked")
    preset.isAnswered = true
    let spent = try await made()
    XCTAssertEqual(spent, "photo")
  }

  /// A talk written down is not 99% smaller.
  func test_wordsAreNotLessOfWhatWasHeard() throws {
    func isElse(_ to: String, _ from: UTType) -> Bool { ProcessingHistory.isSomethingElse(path("a.\(to)"), than: from) }
    XCTAssertTrue(isElse("txt", .wav))
    XCTAssertTrue(isElse("srt", .quickTimeMovie))
    XCTAssertTrue(isElse("txt", .png))
    XCTAssertFalse(isElse("mp3", .wav))
    XCTAssertFalse(isElse("gif", .quickTimeMovie))
    XCTAssertFalse(isElse("svg", .png))
    XCTAssertFalse(isElse("pdf", .png))
    XCTAssertFalse(isElse("txt", .rtf))
    XCTAssertFalse(ProcessingHistory.isSomethingElse(nil, than: .wav))
  }

  /// A film shows a frame of itself, and not the icon of a film.
  func test_aFilmIsSeen() async throws {
    let film = try await Fixture.video(at: path("a.mov"), seconds: 1, size: CGSize(width: 320, height: 180))
    let seen = await PreviewImage.seen(film, maxPixels: 200)
    XCTAssertEqual(seen.size.width / seen.size.height, 16.0 / 9, accuracy: 0.1)
    let nothing = path("a.zzz")
    try Data([1]).write(to: nothing)
    let stand = await PreviewImage.seen(nothing, maxPixels: 64)
    XCTAssertGreaterThan(stand.size.width, 0)
  }

  func test_whatIsHeardIsDrawn() async throws {
    let sound = try Fixture.audio(at: path("a.wav"), seconds: 2)
    let wave = await CutPlayer.wave(of: sound, length: 2, bars: 40)
    XCTAssertEqual(wave.count, 40)
    XCTAssertEqual(wave.max() ?? 0, 1, accuracy: 0.001)
    XCTAssertGreaterThan(wave.filter { $0 > 0.5 }.count, 30)
    let silent = await CutPlayer.wave(of: path("none.wav"), length: 2, bars: 40)
    XCTAssertEqual(silent, [])
  }
}

/// What is offered is what can be made.
final class OfferedIsMadeTests: BaseTestCase {
  private func file(_ name: String, _ size: Dimensions? = nil) throws -> ProcessableFile {
    ProcessableFile(url: path(name), fileType: try XCTUnwrap(UTType(filenameExtension: (name as NSString).pathExtension)), fileName: name, fileSize: 1, dimensions: size)
  }

  func test_aTextureOnlyOfASquare() throws {
    let pvr = try XCTUnwrap(UTType(filenameExtension: "pvr"))
    XCTAssertFalse(ImageProcessor().takes(try file("a.png", .init(width: 640, height: 480)), to: pvr))
    XCTAssertFalse(ImageProcessor().takes(try file("a.png", .init(width: 300, height: 300)), to: pvr))
    XCTAssertTrue(ImageProcessor().takes(try file("a.png", .init(width: 256, height: 256)), to: pvr))
  }

  func test_noIconsOutOfAFilm_andNoSlides() throws {
    let film = try file("a.mov")
    for name in ["icns", "ico", "pptx", "xlsx"] {
      XCTAssertFalse(Conversions.can(film, become: try XCTUnwrap(UTType(filenameExtension: name))), name)
    }
    XCTAssertTrue(Conversions.can(film, become: .png))
  }

  /// An old Word file is not plain text, and was offered as Markdown.
  func test_wordIsNotMarkdownAlready() throws {
    let markdown = try XCTUnwrap(DocumentText.markdown)
    XCTAssertFalse(SimpleDocProcessor().takes(try file("a.doc"), to: markdown))
    XCTAssertTrue(SimpleDocProcessor().takes(try file("a.txt"), to: markdown))
  }

  /// macOS lists AVI among what it opens, and opens few of them. With ffmpeg
  /// here, a frame of one, or what is said in it, is had all the same.
  func test_aFilmMacOSCannotOpenIsOpenedByAnother() async throws {
    guard let ffmpeg = ExternalTools.locate("ffmpeg") else { throw XCTSkip("needs ffmpeg") }
    let film = path("a.avi")
    try ExternalTools.run(ffmpeg, ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=1:s=320x240:r=12", "-c:v", "mpeg4", film.path])
    let preset = RulePreset(name: "x", description: "", category: .video, actions: [.convertFormat(to: .gif)])
    let entry = try await coordinator().processFile(try ProcessableFile(url: film), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
    XCTAssertEqual(entry.outputURL?.lastPathComponent, "a.gif")
    XCTAssertEqual(try ProcessableFile(url: try XCTUnwrap(entry.outputURL)).dimensions?.width, 320)
  }

  func test_aRingtoneOutOfWhatOnlyFfmpegReads() async throws {
    guard let ffmpeg = ExternalTools.locate("ffmpeg"), let ringtone = UTType(filenameExtension: "m4r") else { throw XCTSkip("needs ffmpeg") }
    let sound = path("a.ogg")
    try ExternalTools.run(ffmpeg, ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=d=1", "-c:a", "libopus", sound.path])
    let preset = RulePreset(name: "x", description: "", category: .audio, actions: [.convertFormat(to: ringtone)])
    let entry = try await coordinator().processFile(try ProcessableFile(url: sound), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
    XCTAssertEqual(entry.outputURL?.pathExtension, "m4r")
  }
}

/// What the tiles turn into is what Forge makes.
final class FileFanTests: BaseTestCase {
  func test_eachTileHasFormats_allOfThemOffered() throws {
    let offers = FileFan.offers()
    for category in FileFan.kinds {
      let kind = try XCTUnwrap(ConvertKind(rawValue: category.rawValue))
      let labels = Set(kind.outputGroups.flatMap(\.formats).map { $0.label.lowercased() })
      let named = try XCTUnwrap(offers[category])
      XCTAssertGreaterThan(named.count, 1, category.rawValue)
      XCTAssertTrue(named.allSatisfy(labels.contains), "\(named)")
      print("QQ", category.rawValue, named)
    }
  }
}

final class TexturesAndSlidesTests: BaseTestCase {
  private func can(_ name: String, _ target: String) throws -> Bool {
    let file = ProcessableFile(url: path(name), fileType: try XCTUnwrap(UTType(filenameExtension: (name as NSString).pathExtension)), fileName: name, fileSize: 1, dimensions: nil)
    return Conversions.can(file, become: try XCTUnwrap(UTType(filenameExtension: target)))
  }

  func test_notOfferedWhereItCannotBeMade() throws {
    for (file, target) in [("a.pdf", "pvr"), ("a.stl", "pvr"), ("a.usdz", "pvr"), ("a.pptx", "pvr"), ("a.svg", "pptx"), ("a.mov", "cbz")] {
      XCTAssertFalse(try can(file, target), "\(file) \(target)")
    }
    for (file, target) in [("a.pdf", "png"), ("a.stl", "png"), ("a.png", "pptx"), ("a.pdf", "cbz")] {
      XCTAssertTrue(try can(file, target), "\(file) \(target)")
    }
  }
}

/// A player's type for MPEG carries PostScript's extension too.
final class MpegIsAFilmTests: BaseTestCase {
  func test_everyCameraFileIsAFilm_andPostScriptADocument() throws {
    for name in ["m2p", "ts", "m2ts", "mts"] {
      guard let type = UTType(filenameExtension: name), type.conforms(to: .audiovisualContent) else { continue }
      XCTAssertEqual(ConvertKind(fileType: type), .video, name)
    }
    for name in ["ps", "eps", "ai"] {
      XCTAssertEqual(ConvertKind(fileType: try XCTUnwrap(UTType(filenameExtension: name))), .document, name)
    }
  }
}
