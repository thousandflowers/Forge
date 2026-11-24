import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import Forge

/// What two people who had not written it found in it.
final class ToolAnswerTests: XCTestCase {
  /// A damaged film makes ffmpeg complain for longer than a pipe holds.
  func test_complaintsDoNotStopIt() {
    let said = ExternalTools.answer(of: URL(fileURLWithPath: "/bin/sh"), ["-c", "yes complaint | head -c 400000 >&2; echo done"])
    XCTAssertEqual(said, "done\n")
  }

  func test_aLongAnswerIsAllOfIt() {
    let said = ExternalTools.answer(of: URL(fileURLWithPath: "/bin/sh"), ["-c", "yes a | head -c 400000"])
    XCTAssertEqual(said.utf8.count, 400_000)
  }

  func test_itStopsWhenItsAskerDoes() async {
    let started = Date()
    let task = Task.detached { ExternalTools.answer(of: URL(fileURLWithPath: "/bin/sleep"), ["20"]) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    _ = await task.value
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }
}

final class FilmSettingsReviewTests: ToolTestCase {
  /// Read from a preset as they are, adding two of them up is a crash.
  func test_numbersNoFilmHas() {
    var film = FilmSettings()
    film.crop = .edges(top: .max, bottom: .max, left: .max, right: 5)
    film.from = -5
    film.to = .max
    XCTAssertFalse(film.outputArguments(for: "mp4", bars: nil).isEmpty)
    XCTAssertEqual(film.inputArguments, ["-ss", "0", "-t", "10000000"])
    film.from = .max
    XCTAssertFalse(film.inputArguments.isEmpty)
    XCTAssertGreaterThanOrEqual(film.kept(of: 10), 0)
  }

  private func requireTools() throws {
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil || ExternalTools.locate("ffprobe") == nil, "ffmpeg is not here")
  }

  private func probe(_ url: URL, _ what: [String]) throws -> String {
    ExternalTools.answer(of: try XCTUnwrap(ExternalTools.locate("ffprobe")), ["-v", "error"] + what + ["-of", "csv=p=0", url.path])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func test_aPartAfterTheEnd() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 2)
    var film = FilmSettings()
    film.from = 100
    let said = await reason { _ = try await self.run([], on: source, to: .mpeg4Movie, more: [.film(film)]) }
    XCTAssertTrue(said.contains("a.mp4 is 0:02"), said)
  }

  func test_aSoundtrackThereIsNot() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    var film = FilmSettings()
    film.track = 3
    let said = await reason { _ = try await self.run([], on: source, to: .mpeg4Movie, more: [.film(film)]) }
    XCTAssertEqual(said, "a.mp4 has one soundtrack, and track 3 was asked for.")
  }

  /// The part is of the film, and what is done to it is done to the part.
  func test_aPartSpedUp() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 5)
    var film = FilmSettings()
    film.from = 1
    film.to = 4
    let made = try await run(["speed2x"], on: source, to: .mpeg4Movie, more: [.film(film)])[0]
    let length = try await seconds(made)
    XCTAssertEqual(length, 1.5, accuracy: 0.15)
  }

  func test_aPartBegunInTheMiddleOfASentence() async throws {
    try requireTools()
    let film = try await Fixture.video(at: path("film.mp4"), seconds: 5)
    let words = path("w.srt"), source = path("in.mkv")
    try "1\n00:00:00,000 --> 00:00:02,000\nHonk\n\n2\n00:00:03,000 --> 00:00:03,500\nTwo\n".write(to: words, atomically: true, encoding: .utf8)
    try ExternalTools.run(try XCTUnwrap(ExternalTools.locate("ffmpeg")), [
      "-v", "error", "-y", "-i", film.path, "-i", words.path, "-map", "0", "-map", "1", "-c", "copy", "-c:s", "srt", source.path,
    ])
    let made = try await run(["trim1-4"], on: source)[0]
    XCTAssertEqual(try XCTUnwrap(Double(try probe(made, ["-select_streams", "v", "-show_entries", "stream=start_time"]))), 0, accuracy: 0.05)
    XCTAssertEqual(try probe(made, ["-select_streams", "s", "-show_entries", "stream=codec_name"]), "subrip")
  }

  func test_twoPassesOfHEVCInAFolderWithAColon() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    var film = FilmSettings()
    film.encoder = .hevc
    film.rate = .kilobits(300)
    film.isTwoPass = true
    let out = try folder("two: passes")
    let preset = RulePreset(name: "t", description: "", category: .video, actions: [.convertFormat(to: .mpeg4Movie), .film(film)])
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: out
    ) { _ in }
    XCTAssertEqual(contents(of: out), [try XCTUnwrap(entry.outputURL).lastPathComponent])
    let left = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("forge-pass-") }
    XCTAssertEqual(left, [])
  }

  func test_matroskaKeepsItsSound() async throws {
    try requireTools()
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    let mkv = try XCTUnwrap(UTType(filenameExtension: "mkv"))
    for more in [[Forge.Operation](), [.film(FilmSettings())]] {
      let made = try await run([], on: source, to: mkv, more: more)[0]
      XCTAssertEqual(try probe(made, ["-select_streams", "a", "-show_entries", "stream=codec_name"]), "aac")
    }
  }

  func test_hevcIsWhatQuickTimeTakes() async throws {
    try requireTools()
    let source = path("a.mkv")
    try ExternalTools.run(try XCTUnwrap(ExternalTools.locate("ffmpeg")), [
      "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=1:s=320x240", "-c:v", "libx264", "-pix_fmt", "yuv444p", source.path,
    ])
    var film = FilmSettings()
    film.encoder = .hevc
    let made = try await run([], on: source, to: .mpeg4Movie, more: [.film(film)])[0]
    XCTAssertEqual(try probe(made, ["-show_entries", "stream=pix_fmt"]), "yuv420p")
  }

  /// A film with few whole pictures in it, and black round all of them.
  func test_blackBarsOfAFilmWithTwoKeyframes() async throws {
    try requireTools()
    let source = path("a.mp4")
    try ExternalTools.run(try XCTUnwrap(ExternalTools.locate("ffmpeg")), [
      "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=2:s=320x160:r=25", "-vf", "pad=320:240:0:40", "-g", "25", "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path,
    ])
    let bars = ExternalBridge.blackBars(of: source, ffmpeg: try XCTUnwrap(ExternalTools.locate("ffmpeg")))
    XCTAssertEqual(bars, "crop=320:160:0:40")
  }
}

@MainActor
final class AskSessionReviewTests: ToolTestCase {
  private func session(_ convert: @escaping AskCenter.Convert) throws -> AskSession {
    let file = try Fixture.image(at: path("a.png"))
    let session = AskSession(request: AskRequest(word: .everything, over: nil), file: try ProcessableFile(url: file), convert: convert)
    session.choose(.format(.jpeg), for: .format)
    return session
  }

  func test_startedTwiceItRunsOnce() async throws {
    var runs = 0
    let session = try session { _, _ in runs += 1; return [] }
    session.start()
    session.start()
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(runs, 1)
  }

  func test_theBarFollows() async throws {
    var seen: [Double] = []
    var held: AskSession?
    let session = try session { _, _ in
      AskSession.progress?(0.5)
      try await Task.sleep(nanoseconds: 200_000_000)
      if case .working(let share) = held?.state { seen.append(share) }
      return []
    }
    held = session
    await session.run()
    XCTAssertEqual(seen, [0.5])
  }
}

final class NamesAreNamesTests: ToolTestCase {
  /// A photograph of a mirror, a loop of drums, page three of a scan.
  func test_anOrdinaryConversionReadsNoTools() async throws {
    let mirror = path("bathroom_mirror.png")
    try Quarters.image(at: mirror)
    let made = try await run([], on: mirror, to: .png, readsName: false)[0]
    XCTAssertEqual(made.lastPathComponent, "bathroom_mirror.png")
    XCTAssertEqual(try Quarters.read(made), [.red, .green, .blue, .white])
    let drums = try Fixture.audio(at: path("drums_loop4.wav"), seconds: 1)
    let sound = try await run([], on: drums, to: .wav, readsName: false)[0]
    let length = try await seconds(sound)
    XCTAssertEqual(length, 1, accuracy: 0.05)
  }

  func test_onlyWhatIsRenamedHereIsTold() throws {
    let home = try folder("watched")
    let before = home.appendingPathComponent("clip.mp4"), came = home.appendingPathComponent("bathroom_mirror.png")
    try Data("x".utf8).write(to: before)
    let memory = RenameMemory()
    memory.remember(home, subfolders: false)
    try Data("y".utf8).write(to: came)
    XCTAssertFalse(memory.wasRenamed(came), "it came with that name")
    XCTAssertFalse(memory.wasRenamed(came), "and is still called it")
    let after = home.appendingPathComponent("clip_mute.mp4")
    try FileManager.default.moveItem(at: before, to: after)
    XCTAssertTrue(memory.wasRenamed(after))
    XCTAssertFalse(memory.wasRenamed(after), "once")
  }

  func test_capitalsAreKept() {
    XCTAssertEqual(NameTokens.read("a_mark(Hello).png").tools, [.mark("Hello")])
  }
}

final class OriginalsStayTests: ToolTestCase {
  func test_aFingerprintTakesNothingsPlace() async throws {
    for (mode, word) in [(DestinationMode.moveTo, "sha256"), (.overwrite, "base64")] {
      let source = path("\(word).png")
      try Quarters.image(at: source)
      let made = try await run([word], on: source, mode: mode)
      XCTAssertTrue(exists(source), "\(mode) took the original")
      XCTAssertTrue(exists(made[0]))
    }
    let film = try await Fixture.video(at: path("film.mp4"), seconds: 2)
    let made = try await run(["frames1s"], on: film, mode: .overwrite)
    XCTAssertTrue(exists(film))
    XCTAssertEqual(made.count, 2)
  }

  func test_whateverFormatIsAsked() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let made = try await run(["sha256"], on: source, to: .pdf)[0]
    XCTAssertEqual(made.pathExtension, "txt")
    let film = try await Fixture.video(at: path("film.mp4"), seconds: 2)
    let frames = try await run(["frames1s"], on: film, to: .mpeg4Movie)
    XCTAssertEqual(Set(frames.map(\.pathExtension)), ["jpeg"])
  }

  /// The second of two cannot be written, and the first does not stay behind.
  func test_halfOfItIsNotLeft() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 2)
    let out = try folder("out")
    let preset = RulePreset(name: "t", description: "", category: .custom, actions: [
      .split([Branch(name: "ok", actions: [.convertFormat(to: .mpeg4Movie)]), Branch(name: "no", actions: [.convertFormat(to: .json)])]),
    ])
    do {
      _ = try await coordinator().processFile(try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: out) { _ in }
      XCTFail("it went through")
    } catch {}
    XCTAssertEqual(contents(of: out), [])
    XCTAssertTrue(exists(source))
  }
}

final class ToolReviewTests: ToolTestCase {
  func test_pagesAfterTheLast() {
    XCTAssertEqual(PageList("7-")?.indices(of: 5), [])
    XCTAssertEqual(PageList("2,9-")?.indices(of: 5), [1])
    XCTAssertEqual(PageList("5-")?.indices(of: 5), [4])
  }

  /// A word nothing reads back takes the whole preset with it.
  func test_whatAnEditorCanSayIsReadable() {
    XCTAssertNil(Tool.trim(Span(from: 50, to: 30)).readable)
    XCTAssertNil(Tool.trim(Span()).readable)
    XCTAssertNil(Tool.frames(every: 0.0004).readable)
    XCTAssertEqual(Tool.trim(Span(from: 1.23456, to: nil)).readable, .trim(Span(from: 1.235, to: nil)))
  }

  func test_aDrawingIsNotTraced() async throws {
    try XCTSkipIf(!VectorProcessor.canDraw, "this Mac draws no SVG")
    let source = path("a.svg")
    try ##"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#3178c6"/></svg>"##.write(to: source, atomically: true, encoding: .utf8)
    let said = await reason { _ = try await self.run(["rotate90"], on: source) }
    XCTAssertTrue(said.contains("is a drawing"), said)
  }

  func test_nothingIsLeftOfSoundWithoutSound() async throws {
    let source = try await Fixture.video(at: path("a.mp4"), seconds: 1)
    let said = await reason { _ = try await self.run(["mute"], on: source, to: .m4a) }
    XCTAssertTrue(said.contains("nothing left"), said)
  }

  func test_moreFilesThanAnybodyWants() async throws {
    let source = try Fixture.audio(at: path("a.wav"), seconds: 2)
    let said = await reason { _ = try await self.run([], on: source, more: [.tool(.divide(.every(0.0000001)))]) }
    XCTAssertTrue(said.contains("more than 2000"), said)
    let film = try await Fixture.video(at: path("a.mp4"), seconds: 2)
    let frames = await reason { _ = try await self.run([], on: film, more: [.tool(.frames(every: 0.0001))]) }
    XCTAssertTrue(frames.contains("10000"), frames)
  }

  func test_somebodyElsesPresetNamesNoFile() {
    var film = FilmSettings()
    film.lut = "/etc/hosts"
    let preset = RulePreset(name: "x", description: "", category: .video, actions: [.when(Condition(), then: [.film(film)], otherwise: [])])
    XCTAssertFalse(PresetGallery.isRunnable(preset))
    let left = preset.withoutFilesOfItsOwn.actions.flatMap(\.leaves).film
    XCTAssertNotNil(left)
    XCTAssertNil(left?.lut)
    XCTAssertEqual(film.refusal(for: "mp4"), "A LUT is a .cube file.")
  }

  /// Joined, a film says no more about who made it than it would converted.
  func test_aJoinKeepsThePrivacyAskedFor() async throws {
    let film = path("film.mov")
    let place = AVMutableMetadataItem()
    place.identifier = .quickTimeMetadataLocationISO6709
    place.value = "+45.4371+012.3326/" as NSString
    place.dataType = kCMMetadataBaseDataType_UTF8 as String
    try await Fixture.writePictureTrack(to: film, seconds: 1, size: CGSize(width: 320, height: 200), metadata: [place])
    let sound = try Fixture.audio(at: path("v.wav"), seconds: 1)
    let words = path("w.srt")
    try "1\n00:00:00,100 --> 00:00:00,800\nHonk\n".write(to: words, atomically: true, encoding: .utf8)
    func saysWhere(_ kind: Joiner.Kind, with other: URL, _ policy: PrivacyPolicy) async throws -> Bool {
      var settings = AppSettings()
      settings.privacy = policy
      let files = [try ProcessableFile(url: film), try ProcessableFile(url: other)]
      let made = try await coordinator(settings: settings).join(files, as: kind, into: path("o-\(UUID().uuidString)"))
      return try Data(contentsOf: made).range(of: Data("45.4371".utf8)) != nil
    }
    let kept = try await saysWhere(.dubbed, with: sound, .keepAll)
    XCTAssertTrue(kept, "or the rest proves nothing")
    for policy in [PrivacyPolicy.stripLocation, .stripAll] {
      let dubbed = try await saysWhere(.dubbed, with: sound, policy)
      XCTAssertFalse(dubbed, "\(policy)")
      guard ExternalTools.locate("ffmpeg") != nil else { continue }
      let subtitled = try await saysWhere(.subtitled, with: words, policy)
      XCTAssertFalse(subtitled, "\(policy)")
    }
  }

  func test_anAnimationIsCroppedInOnePlace() async throws {
    let frames = (0..<6).map { index -> ImageFrame in
      let context = CGContext(
        data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )!
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 150 + index * 10, y: 35, width: 30, height: 30))
      return ImageFrame(image: context.makeImage()!, duration: 0.1)
    }
    let source = path("a.gif")
    try ImageFrames.write(frames, to: source, as: .gif, frameOptions: [:])
    let made = try await run(["crop1x1"], on: source)[0]
    let read = try XCTUnwrap(CGImageSourceCreateWithURL(made as CFURL, nil))
    let places = (0..<CGImageSourceGetCount(read)).compactMap { index -> Int? in
      guard let image = CGImageSourceCreateImageAtIndex(read, index, nil) else { return nil }
      var bytes = [UInt8](repeating: 0, count: image.width * image.height)
      let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
      )!
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return bytes[(50 * image.width)..<(51 * image.width)].firstIndex { $0 > 128 }.map { $0 - 50 * image.width }
    }
    XCTAssertEqual(places, [0, 10, 20, 30, 40, 50], "it moves as it moved")
  }
}

@MainActor
final class CutReviewTests: ToolTestCase {
  /// To the right is to the right, in a mirror too.
  func test_turningWhatIsMirrored() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let model = try XCTUnwrap(CutModel(file: try ProcessableFile(url: source)))
    await model.load()
    model.mirror()
    model.turn()
    let made = try await run([], on: source, more: model.preset.actions)[0]
    // Mirrored: green red over white blue. Then to the right: white green over blue red.
    XCTAssertEqual(try Quarters.read(made), [.white, .green, .blue, .red])
  }
}
