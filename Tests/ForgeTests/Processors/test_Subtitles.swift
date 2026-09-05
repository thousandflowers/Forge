import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// Subtitles, which Forge parses itself because macOS parses none of them.
final class SubtitleTests: BaseTestCase {

  private static let subRip = """
    1
    00:00:01,000 --> 00:00:04,000
    Buongiorno.

    2
    00:00:05,500 --> 00:00:08,250
    Seconda riga,
    con due righe.

    """

  private func file(_ name: String, _ contents: String) throws -> URL {
    let url = path(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func convert(_ source: URL, to ext: String) async throws -> URL {
    let format = try XCTUnwrap(UTType(filenameExtension: ext, conformingTo: .plainText))
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: format, category: .document),
      destinationMode: .copyTo,
      destinationURL: try folder("out")
    ) { _ in }
    XCTAssertEqual(entry.status, .completed)
    return try XCTUnwrap(entry.outputURL)
  }

  /// macOS has no type for `.srt`: `UTType(filenameExtension:)` invents a
  /// dynamic one, which the file model refuses for everything else. A format
  /// Forge can actually read has to get past that.
  func test_aSubRipFileIsAccepted() throws {
    let source = try file("film.srt", Self.subRip)
    let parsed = try ProcessableFile(url: source)
    XCTAssertTrue(parsed.fileType.conforms(to: .plainText))
  }

  /// A file with an extension nobody parses is still refused, which is what
  /// keeps the exception above from being a hole.
  func test_anUnknownExtensionIsStillRefused() throws {
    let source = try file("mystery.zzzz", "whatever")
    XCTAssertThrowsError(try ProcessableFile(url: source))
  }

  func test_subRipBecomesWebVTT() async throws {
    let output = try await convert(try file("film.srt", Self.subRip), to: "vtt")
    let written = try String(contentsOf: output, encoding: .utf8)

    XCTAssertTrue(written.hasPrefix("WEBVTT"), "a WebVTT file starts by saying so")
    XCTAssertTrue(written.contains("00:00:01.000 --> 00:00:04.000"), written)
    XCTAssertTrue(written.contains("Seconda riga,\ncon due righe."), "the second line was lost")
  }

  /// AVFoundation lists WebVTT among the types it opens and then finds no
  /// tracks in one, so a subtitle used to fail with "contains no audio or
  /// video tracks" instead of converting.
  func test_webVTTComesBackToSubRip() async throws {
    let vtt = try await convert(try file("film.srt", Self.subRip), to: "vtt")
    let back = try await convert(vtt, to: "srt")
    let written = try String(contentsOf: back, encoding: .utf8)

    XCTAssertTrue(written.contains("00:00:05,500 --> 00:00:08,250"), written)
    XCTAssertTrue(written.hasPrefix("1\n"), "SubRip numbers its cues")
  }

  /// MicroDVD counts frames, states its own rate, and writes a line break as
  /// a pipe.
  func test_microDVDIsReadInFrames() async throws {
    let source = try file("vecchio.sub", "{25}{100}Prima battuta\n{150}{250}Seconda|battuta\n")
    let output = try await convert(source, to: "srt")
    let written = try String(contentsOf: output, encoding: .utf8)

    // 25 frames at the default 25 a second is one second in.
    XCTAssertTrue(written.contains("00:00:01,000 --> 00:00:04,000"), written)
    XCTAssertTrue(written.contains("00:00:06,000 --> 00:00:10,000"), written)
    XCTAssertTrue(written.contains("Seconda\nbattuta"), "the pipe is a line break")
  }

  /// A file that states its rate is read at that rate rather than at 25.
  func test_microDVDUsesTheRateItStates() throws {
    let source = try file("rate.sub", "{1}{1}50\n{50}{100}Meta velocita\n")
    let cues = try Subtitles.read(source)
    XCTAssertEqual(cues.first?.start, 1.0)
    XCTAssertEqual(cues.first?.end, 2.0)
  }

  /// Asked for words, a subtitle gives up its words and keeps its times to
  /// itself.
  func test_subtitlesBecomePlainText() async throws {
    let output = try await convert(try file("film.srt", Self.subRip), to: "txt")
    let written = try String(contentsOf: output, encoding: .utf8)

    XCTAssertTrue(written.contains("Buongiorno."))
    XCTAssertFalse(written.contains("-->"), "the times came along: \(written)")
  }

  /// Every punctuation these formats use for a time, and the shortened forms
  /// that turn up in files somebody wrote by hand.
  func test_theTimeIsReadHoweverItIsWritten() {
    XCTAssertEqual(Subtitles.seconds(from: "01:02:03,456"), 3723.456)
    XCTAssertEqual(Subtitles.seconds(from: "01:02:03.456"), 3723.456)
    XCTAssertEqual(Subtitles.seconds(from: "0:02:03.45"), 123.45)
    XCTAssertEqual(Subtitles.seconds(from: "02:03.456"), 123.456)
    // A WebVTT cue can carry settings after the time.
    XCTAssertEqual(Subtitles.seconds(from: "00:00:04.000 align:start"), 4)
    XCTAssertNil(Subtitles.seconds(from: "not a time"))
  }

  // MARK: - The track inside a film

  /// Muxes a subtitle track into a Matroska file. ffmpeg is doing this because
  /// nothing on macOS writes one - the same reason it does the reading.
  private func filmWithSubtitles() async throws -> URL {
    let picture = try await Fixture.video(at: path("clip.mp4"), seconds: 1)
    let words = try file("track.srt", Self.subRip)
    let film = path("film.mkv")

    let ffmpeg = try XCTUnwrap(ExternalTools.locate("ffmpeg"))
    try ExternalTools.run(ffmpeg, [
      "-hide_banner", "-loglevel", "error", "-y",
      "-i", picture.path, "-i", words.path, "-c", "copy", "-c:s", "srt", film.path,
    ])
    return film
  }

  /// A subtitle asked of a film is the track already in it. AVFoundation
  /// exposes no reader for subtitle samples, so this is ffmpeg's - and asking
  /// for `.srt` rather than `.txt` is how the two are told apart, since a
  /// video asked for words still gets its soundtrack transcribed.
  func test_aFilmGivesUpItsSubtitles() async throws {
    try XCTSkipUnless(ExternalTools.locate("ffmpeg") != nil, "ffmpeg is not installed here")
    let film = try await filmWithSubtitles()

    let output = try await convert(film, to: "srt")
    let written = try String(contentsOf: output, encoding: .utf8)

    XCTAssertTrue(written.contains("Buongiorno."), written)
    XCTAssertTrue(written.contains("00:00:01,000 --> 00:00:04,000"), written)
  }

  /// ffmpeg answers a missing track with "Stream map '' matches no streams. To
  /// ignore this, add a trailing '?' to the map", which is about a flag nobody
  /// typed.
  func test_aFilmWithNoSubtitlesSaysSo() async throws {
    try XCTSkipUnless(ExternalTools.locate("ffmpeg") != nil, "ffmpeg is not installed here")
    let silent = try await Fixture.video(at: path("plain.mp4"), seconds: 1)

    do {
      _ = try await convert(silent, to: "srt")
      XCTFail("a film with no subtitle track cannot give one up")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.lowercased().contains("no subtitles"),
        "the tool's own words came through: \(error.localizedDescription)"
      )
    }
  }

  /// A text file with no cues in it is not an empty subtitle: it is not a
  /// subtitle, and saying so beats writing an empty one.
  func test_aFileWithNoCuesFails() throws {
    let source = try file("empty.srt", "just some words\nand some more\n")
    XCTAssertThrowsError(try Subtitles.read(source))
  }
}
