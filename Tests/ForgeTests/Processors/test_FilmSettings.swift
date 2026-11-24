import AVFoundation
import UniformTypeIdentifiers
import XCTest
@testable import Forge

/// The settings behind Advanced, and what they come to.
final class FilmSettingsTests: BaseTestCase {
  private func arguments(_ change: (inout FilmSettings) -> Void, _ container: String = "mp4") -> [String] {
    var settings = FilmSettings()
    change(&settings)
    return settings.outputArguments(for: container, size: nil, bars: nil)
  }

  private func value(after flag: String, _ arguments: [String]) -> String? {
    arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
  }

  func test_qualityIsOnEachEncodersOwnScale() {
    XCTAssertEqual(FilmSettings.Encoder.h264.level(for: 100), 16)
    XCTAssertEqual(FilmSettings.Encoder.h264.level(for: 1), 40)
    XCTAssertEqual(FilmSettings.Encoder.hevcApple.level(for: 100), 100)
    XCTAssertEqual(FilmSettings.Encoder.av1.level(for: 500), 18, "out of range is brought back in")
  }

  func test_whatWasNotAskedForIsNotSaid() {
    let plain = arguments { _ in }
    for flag in ["-vf", "-r", "-af", "-ac", "-t", "-an"] { XCTAssertFalse(plain.contains(flag), flag) }
  }

  func test_aQualityAndARateAreNeverBothAsked() {
    XCTAssertNil(value(after: "-b:v", arguments { _ in }))
    let rated = arguments { $0.rate = .kilobits(2500) }
    XCTAssertEqual(value(after: "-b:v", rated), "2500k")
    XCTAssertNil(value(after: "-crf", rated))
    XCTAssertEqual(value(after: "-b:v", arguments({ $0.encoder = .vp9 }, "webm")), "0")
  }

  func test_filtersAreInTheOrderThatWorks() {
    var settings = FilmSettings()
    settings.interlacing = .deinterlace
    settings.noise = .light
    settings.sharpness = .light
    settings.crop = .edges(top: 10, bottom: 20, left: 4, right: 6)
    settings.turn = .right
    let filter = value(after: "-vf", settings.outputArguments(for: "mp4", size: "scale=640:-2", bars: nil)) ?? ""
    let places = ["bwdif", "hqdn3d", "crop=iw-10:ih-30:4:10", "scale=640", "transpose", "unsharp", "trunc"].map { filter.range(of: $0)?.lowerBound }
    XCTAssertFalse(places.contains(nil), filter)
    XCTAssertEqual(places.compactMap { $0 }, places.compactMap { $0 }.sorted(), filter)
  }

  func test_aCopyThatHasToChangeIsNotACopy() {
    XCTAssertEqual(value(after: "-c:a", arguments { $0.sound = .asItIs }), "copy")
    XCTAssertNil(value(after: "-c:a", arguments { $0.sound = .asItIs; $0.evensLoudness = true }))
    XCTAssertTrue(arguments { $0.sound = .none }.contains("-an"))
    XCTAssertNil(value(after: "-b:a", arguments { $0.sound = .flac; $0.soundKilobits = 128 }))
  }

  func test_whatDoesNotFitIsSaidWithWhatDoes() {
    var settings = FilmSettings()
    settings.encoder = .av1
    XCTAssertNil(settings.refusal(for: "mkv"))
    XCTAssertTrue(settings.refusal(for: "mov")?.contains("MKV") == true)
    settings.sound = .mp3
    XCTAssertNotNil(settings.refusal(for: "webm"))
    settings = FilmSettings()
    (settings.from, settings.to) = (20, 10)
    XCTAssertNotNil(settings.refusal(for: "mp4"))
  }

  func test_theBarIsThePartThatIsKept() {
    var settings = FilmSettings()
    XCTAssertEqual(settings.kept(of: 60), 60)
    (settings.from, settings.to) = (10, 25)
    XCTAssertEqual(settings.kept(of: 60), 15)
    XCTAssertEqual(settings.kept(of: 20), 10)
    XCTAssertEqual(settings.kept(of: 5), 0)
  }

  func test_settingsSavedWithLessInThemStillLoad() throws {
    let old = try JSONDecoder().decode(FilmSettings.self, from: Data(#"{"encoder":"av1"}"#.utf8))
    XCTAssertEqual(old.encoder, .av1)
    XCTAssertEqual(old.noise, .leave)
  }

  func test_theBlockSurvivesBeingSaved() throws {
    var settings = FilmSettings()
    settings.crop = .edges(top: 1, bottom: 2, left: 3, right: 4)
    settings.rate = .kilobits(900)
    settings.from = 3
    let chain: [Forge.Operation] = [.film(settings)]
    XCTAssertEqual(try JSONDecoder().decode([Forge.Operation].self, from: JSONEncoder().encode(chain)), chain)
  }

  // MARK: - With ffmpeg

  private func run(_ settings: FilmSettings, to ext: String, extra: [Forge.Operation] = [], seconds: Double = 2) async throws -> AVURLAsset {
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil, "needs ffmpeg")
    let source = try await Fixture.video(at: path("film-\(UUID().uuidString).mov"), seconds: seconds)
    let preset = RulePreset(name: "t", description: "", category: .video, actions: [.convertFormat(to: try XCTUnwrap(UTType(filenameExtension: ext))), .film(settings)] + extra)
    let entry = try await coordinator().processFile(try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
    return AVURLAsset(url: try XCTUnwrap(entry.outputURL))
  }

  private func codec(_ asset: AVURLAsset) async throws -> FourCharCode? {
    try await asset.loadTracks(withMediaType: .video).first?.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
  }

  /// macOS writes MP4 itself, so this is the pair where settings would be
  /// dropped without a word.
  func test_anMP4IsWrittenAsItWasSaid() async throws {
    var settings = FilmSettings()
    settings.encoder = .hevc
    settings.speed = .fast
    settings.framesPerSecond = 12
    settings.turn = .right
    let made = try await run(settings, to: "mp4", extra: [.resize(width: 320, height: nil, fitMode: .proportional)])
    let written = try await codec(made)
    XCTAssertEqual(written, kCMVideoCodecType_HEVC)
    let track = try await XCTUnwrapAsync(try await made.loadTracks(withMediaType: .video).first)
    let (size, rate) = try await track.load(.naturalSize, .nominalFrameRate)
    XCTAssertEqual(size, CGSize(width: 180, height: 320))
    XCTAssertEqual(rate, 12, accuracy: 0.5)
  }

  func test_onlyThePartAskedForIsKept() async throws {
    var settings = FilmSettings()
    (settings.from, settings.to) = (1, 3)
    let made = try await run(settings, to: "mp4", seconds: 4)
    let duration = try await made.load(.duration).seconds
    XCTAssertEqual(duration, 2, accuracy: 0.2)
  }

  func test_soundCanBeLeftOut() async throws {
    var settings = FilmSettings()
    settings.sound = .none
    let tracks = try await run(settings, to: "mp4").loadTracks(withMediaType: .audio)
    XCTAssertTrue(tracks.isEmpty)
  }

  /// Every encoder into every container it is said to fit: the list is a
  /// promise, and this is what keeps it.
  func test_everythingOfferedReallyFits() async throws {
    let ffmpeg = try XCTUnwrap(ExternalTools.locate("ffmpeg").map { $0 } ?? { throw XCTSkip("needs ffmpeg") }())
    let source = try await Fixture.video(at: path("film.mov"), seconds: 1, size: CGSize(width: 320, height: 240))
    let here = ExternalBridge.ffmpegEncoders
    for encoder in FilmSettings.Encoder.allCases where here.contains(encoder.name) {
      for container in encoder.containers {
        var settings = FilmSettings()
        settings.encoder = encoder
        settings.speed = .fast
        settings.sound = container == "webm" ? .opus : .automatic
        let output = path("\(encoder.rawValue).\(container)")
        XCTAssertNoThrow(try ExternalTools.run(ffmpeg, ["-loglevel", "error", "-y", "-i", source.path] + settings.outputArguments(for: container, size: nil, bars: nil) + [output.path]), "\(encoder) \(container)")
      }
    }
  }

  /// Every filter this offers is one ffmpeg takes.
  func test_everyFilterIsTaken() async throws {
    var all: [FilmSettings] = []
    for value in FilmSettings.Interlacing.allCases { var s = FilmSettings(); s.interlacing = value; all.append(s) }
    for value in FilmSettings.Noise.allCases { var s = FilmSettings(); s.noise = value; all.append(s) }
    for value in FilmSettings.Sharpness.allCases { var s = FilmSettings(); s.sharpness = value; all.append(s) }
    for value in FilmSettings.Turn.allCases { var s = FilmSettings(); s.turn = value; all.append(s) }
    for value in FilmSettings.Channels.allCases { var s = FilmSettings(); s.channels = value; all.append(s) }
    var rest = FilmSettings()
    rest.smoothsBlocks = true
    rest.isGrey = true
    rest.isRec709 = true
    rest.evensLoudness = true
    rest.crop = .blackBars
    all.append(rest)
    for var settings in all {
      settings.encoder = .h264Apple
      _ = try await run(settings, to: "mp4", seconds: 0.3)
    }
  }

  func test_blackBarsAreFoundAndCutOff() async throws {
    let ffmpeg = try XCTUnwrap(ExternalTools.locate("ffmpeg").map { $0 } ?? { throw XCTSkip("needs ffmpeg") }())
    let barred = path("barred.mp4")
    try ExternalTools.run(ffmpeg, ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=2:s=640x360", "-vf", "pad=640:480:0:60:black", "-c:v", "h264_videotoolbox", barred.path])
    var settings = FilmSettings()
    settings.crop = .blackBars
    let preset = RulePreset(name: "t", description: "", category: .video, actions: [.convertFormat(to: .mpeg4Movie), .film(settings)])
    let entry = try await coordinator().processFile(try ProcessableFile(url: barred), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
    let track = try await AVURLAsset(url: try XCTUnwrap(entry.outputURL)).loadTracks(withMediaType: .video).first
    let size = try await track?.load(.naturalSize)
    XCTAssertEqual(size?.width, 640)
    XCTAssertEqual(size?.height ?? 0, 360, accuracy: 16)
  }

  func test_whatDoesNotFitFailsAndSaysSo() async throws {
    var settings = FilmSettings()
    settings.encoder = .av1
    do {
      _ = try await run(settings, to: "mov")
      XCTFail()
    } catch ProcessingError.conversionFailed(let reason) {
      XCTAssertTrue(reason.contains("MKV"), reason)
    }
  }

  /// A long film moves the bar.
  func test_progressIsTheFilms() async throws {
    try XCTSkipIf(ExternalTools.locate("ffmpeg") == nil, "needs ffmpeg")
    var settings = FilmSettings()
    settings.encoder = .hevc
    settings.speed = .slow
    let source = try await Fixture.video(at: path("long.mov"), seconds: 8, size: CGSize(width: 1280, height: 720))
    let seen = Seen()
    let preset = RulePreset(name: "t", description: "", category: .video, actions: [.convertFormat(to: .mpeg4Movie), .film(settings)])
    _ = try await coordinator().processFile(try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { seen.add($0) }
    XCTAssertEqual(seen.all, seen.all.sorted())
    XCTAssertTrue(seen.all.contains { $0 > 0.15 && $0 < 0.95 }, "\(seen.all)")
  }

  private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
  }

  private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }
}
