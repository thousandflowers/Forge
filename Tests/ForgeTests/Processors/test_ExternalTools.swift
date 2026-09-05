import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// The conversions that only happen because a tool is installed.
///
/// Every test that needs one stands aside where it is not: these are the
/// user's tools, not Forge's, and a machine without them is a machine Forge
/// still has to work on.
final class ExternalToolTests: BaseTestCase {

  private func requireFFmpeg() throws {
    try XCTSkipUnless(ExternalTools.locate("ffmpeg") != nil, "ffmpeg is not installed here")
  }

  private func requirePandoc() throws {
    try XCTSkipUnless(ExternalTools.locate("pandoc") != nil, "pandoc is not installed here")
  }

  /// A container macOS reads and cannot write. The media path turns the pair
  /// down, and the file has to reach the tool rather than stop there.
  func test_video_reachesFFmpegWhenMacOSTurnsThePairDown() async throws {
    try requireFFmpeg()
    let source = try await Fixture.video(at: path("clip.mp4"), seconds: 1)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "wmv")), category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(output.pathExtension, "wmv")
    XCTAssertGreaterThan(size(of: output), 0)
  }

  /// EPUB is pandoc's, and nothing on the machine writes one.
  func test_document_reachesPandoc() async throws {
    try requirePandoc()
    let source = path("doc.md")
    try "# Titolo\n\nUn paragrafo.\n".write(to: source, atomically: true, encoding: .utf8)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "epub")), category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    XCTAssertGreaterThan(size(of: try XCTUnwrap(entry.outputURL)), 0)
  }

  /// A resize is not silently dropped on the way to ffmpeg.
  func test_theResizeReachesFFmpeg() throws {
    try requireFFmpeg()
    let plan = try XCTUnwrap(
      ExternalBridge.plan(
        from: URL(fileURLWithPath: "/tmp/in.mp4"),
        to: URL(fileURLWithPath: "/tmp/out.wmv"),
        operations: [.resize(width: 640, height: nil, fitMode: .proportional)]
      )
    )
    XCTAssertEqual(plan.toolName, "ffmpeg")
    XCTAssertTrue(plan.arguments.contains("scale=640:-2"), "the size did not cross: \(plan.arguments)")
  }

  /// pandoc is asked about the formats it says it has, and is not handed a
  /// video because it happens to be installed.
  func test_pandocIsOfferedOnlyItsOwnFormats() throws {
    try requirePandoc()
    XCTAssertTrue(ExternalBridge.pandocFormats.write.contains("epub"))

    let video = ExternalBridge.plan(
      from: URL(fileURLWithPath: "/tmp/in.mp4"),
      to: URL(fileURLWithPath: "/tmp/out.wmv"),
      operations: []
    )
    XCTAssertNotEqual(video?.toolName, "pandoc")
  }

  /// LibreOffice names its output after the input, so Forge gives it a folder
  /// to itself and moves what appears.
  func test_whatTheToolNamedItselfIsMovedIntoPlace() throws {
    let folder = try folder("office")
    let made = folder.appendingPathComponent("slides.pdf")
    try Data("%PDF-1.4\n".utf8).write(to: made)
    let wanted = path("deck.pdf")

    try ExternalProcessor.collect(from: folder, to: wanted, wanted: "pdf", tool: "LibreOffice")

    XCTAssertTrue(exists(wanted))
    XCTAssertFalse(exists(made), "the tool's own file was left behind")
  }

  /// A tool that exits successfully having written nothing is a failure, not
  /// an empty result: the alternative is a conversion reported as done with
  /// no file at the end of it.
  func test_aToolThatWroteNothingIsAFailure() throws {
    let folder = try folder("office")
    XCTAssertThrowsError(
      try ExternalProcessor.collect(
        from: folder, to: path("deck.pdf"), wanted: "pdf", tool: "LibreOffice"
      )
    )
  }

  /// A spreadsheet is nobody native's: macOS reads none. It is offered by
  /// whichever tool is here - and on a recent pandoc that is pandoc, which
  /// reads xlsx and pptx and made LibreOffice unnecessary for them.
  func test_spreadsheetsAreOfferedByWhicheverToolIsHere() throws {
    let xlsx = try XCTUnwrap(UTType(filenameExtension: "xlsx"))
    let somebodyCan = ExternalBridge.pandocFormats.read.contains("xlsx")
      || ExternalBridge.libreOffice != nil
    XCTAssertEqual(ExternalBridge.canHandle(xlsx), somebodyCan)
  }

  // MARK: - Fonts

  /// CoreText reads a font's tables and has no public API to write one, so
  /// this is fonttools' - and only for the pair it has a command for.
  func test_fontsGoToFonttools() throws {
    try XCTSkipUnless(ExternalTools.locate("fonttools") != nil, "fonttools is not installed here")
    let plan = try XCTUnwrap(
      ExternalBridge.plan(
        from: URL(fileURLWithPath: "/tmp/mono.ttf"),
        to: URL(fileURLWithPath: "/tmp/mono.woff2"),
        operations: []
      )
    )
    XCTAssertEqual(plan.toolName, "fonttools")
    XCTAssertTrue(plan.arguments.contains("ttLib.woff2"), "\(plan.arguments)")
    XCTAssertTrue(plan.arguments.contains("compress"), "\(plan.arguments)")
  }

  /// TTF to OTF is a change of outline format rather than of container, and
  /// fonttools has no command for it. Before this, a font that nobody could
  /// convert was handed to ffmpeg, which answered "Invalid data found when
  /// processing input".
  func test_aFontIsNeverHandedToFFmpeg() {
    let plan = ExternalBridge.plan(
      from: URL(fileURLWithPath: "/tmp/mono.ttf"),
      to: URL(fileURLWithPath: "/tmp/mono.otf"),
      operations: []
    )
    XCTAssertNotEqual(plan?.toolName, "ffmpeg")
  }

  /// A pip install --user puts its commands in a versioned directory no shell
  /// profile mentions, which is why fonttools was reported missing on a Mac
  /// that had it.
  func test_pythonsOwnDirectoriesAreSearched() throws {
    let python = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Python")
    let versions = (try? FileManager.default.contentsOfDirectory(
      at: python, includingPropertiesForKeys: nil
    )) ?? []
    try XCTSkipIf(versions.isEmpty, "no per-user Python on this machine")

    for version in versions {
      XCTAssertTrue(
        ExternalTools.searchPaths.contains(version.appendingPathComponent("bin").path),
        "\(version.lastPathComponent) is not searched"
      )
    }
  }

  /// fonttools can read a WOFF2 with what Python ships and cannot write one
  /// without brotli, which pip does not install alongside it. What it says is
  /// a traceback; what it means is one command away.
  func test_theBrotliTracebackIsTranslated() {
    let traceback = ProcessingError.conversionFailed(
      reason: "fonttools: Traceback (most recent call last): ImportError: No module named brotli"
    )
    let explained = ExternalProcessor.explain(traceback, about: URL(fileURLWithPath: "/tmp/mono.ttf"))
    XCTAssertTrue(
      explained.localizedDescription.contains("brotli module"),
      explained.localizedDescription
    )
    XCTAssertTrue(explained.localizedDescription.contains("pip3 install"))
  }

  /// Pictures are ImageIO's, whatever is installed. A tool that offered to
  /// take them would take them off the path that resizes, filters and
  /// measures.
  func test_picturesAreNotOfferedToAnyTool() {
    XCTAssertFalse(ExternalBridge.canHandle(.png))
    XCTAssertFalse(ExternalBridge.canHandle(.jpeg))
  }
}
