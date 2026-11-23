import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Forge

/// What the Convert sheet offers for the files in front of it.
///
/// It offered by the kind of file - "a document" - and not by the file, so a
/// Word document was offered JPEG, which only a PDF can become, and the
/// conversion then failed with "Forge cannot convert DOCX to JPEG". Measured
/// on 147 real files, most of 906 refusals were of this kind. The README says
/// Forge never offers a conversion it cannot finish.
final class OfferTests: BaseTestCase {

  private func offered(for file: ProcessableFile) throws -> Set<UTType> {
    let kind = try XCTUnwrap(ConvertKind(fileType: file.fileType))
    return Set(kind.outputGroups(for: [file]).flatMap(\.formats).compactMap(\.type))
  }

  private func word() throws -> ProcessableFile {
    let url = path("letter.docx")
    let words = NSAttributedString(string: "A letter.")
    try words.data(
      from: NSRange(location: 0, length: words.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
    ).write(to: url)
    return try ProcessableFile(url: url)
  }

  func test_aDocumentIsOfferedPicturesOnlyIfItIsAPDF() throws {
    let letter = try offered(for: try word())
    // LibreOffice, where it is installed, does draw a Word file's first page.
    if ExternalBridge.libreOffice == nil {
      XCTAssertFalse(letter.contains(.jpeg), "a Word document cannot become a JPEG, and was offered one")
      XCTAssertFalse(letter.contains(.png))
    }
    XCTAssertFalse(letter.contains(try XCTUnwrap(UTType("com.apple.icns"))), "nothing here makes an icon of a letter")
    XCTAssertTrue(letter.contains(.rtf))
    XCTAssertTrue(letter.contains(.pdf))

    let pdf = try offered(for: try ProcessableFile(url: try Fixture.pdf(at: path("scan.pdf"), pages: 1)))
    XCTAssertTrue(pdf.contains(.jpeg), "a PDF's pages can")
  }

  /// A batch is offered what every file in it can become: one that only some
  /// can finish is one that fails for the rest.
  func test_aBatchIsOfferedWhatEveryFileInItCanBecome() throws {
    let letter = try word()
    let scan = try ProcessableFile(url: try Fixture.pdf(at: path("scan.pdf"), pages: 1))

    let together = Set(ConvertKind.document.outputGroups(for: [letter, scan]).flatMap(\.formats).compactMap(\.type))

    XCTAssertFalse(together.contains(.jpeg))
    XCTAssertTrue(together.contains(.rtf))
  }

  /// Whatever is offered, the converter takes: no offered pair may be turned
  /// down as a pair. What is inside a file can still stop it, with a reason.
  func test_nothingOfferedIsTurnedDownAsAPair() async throws {
    let files = [
      try ProcessableFile(url: try Fixture.image(at: path("photo.png"), width: 256, height: 256)),
      try word(),
      try ProcessableFile(url: try Fixture.pdf(at: path("scan.pdf"), pages: 1)),
    ]
    for file in files {
      // Sound takes seconds a file to make and is covered by the conformance
      // tests on real files; pictures and documents are enough to hold the rule.
      for format in try offered(for: file) where !format.conforms(to: .audio) {
        do {
          _ = try await coordinator().processFile(
            file, with: .make(format: format, category: .custom),
            destinationMode: .copyTo, destinationURL: try folder("out-\(UUID().uuidString.prefix(6))")
          ) { _ in }
        } catch let error as ProcessingError {
          if case .unsupportedConversion = error {
            XCTFail("\(file.url.lastPathComponent) was offered \(format.identifier), then refused as a pair")
          }
        } catch {}
      }
    }
  }

  /// The same for a preset: one that writes JPEGs is not offered for a Word
  /// document, which cannot become one.
  func test_aPresetIsOfferedOnlyForFilesThatCanBecomeWhatItWrites() throws {
    let jpegs = RulePreset.make(format: .jpeg, category: .image)
    let smaller = RulePreset.make(resize: ResizeSpec(width: 800, height: nil), category: .image)
    let letter = try word()
    let photo = try ProcessableFile(url: try Fixture.image(at: path("photo.png"), width: 64, height: 64))

    XCTAssertTrue(jpegs.suits([photo]))
    XCTAssertFalse(jpegs.suits([letter]))
    XCTAssertFalse(jpegs.suits([photo, letter]), "one file that cannot finish is enough")
    XCTAssertTrue(smaller.suits([letter]), "a preset that names no format asks nothing of the file")
  }

  /// AVFoundation counts playlists and caption files among the types it opens,
  /// and finds no tracks in one. Filed as films, they were offered everything a
  /// film is offered - thirty-five formats - and failed into every one.
  func test_aPlaylistIsNotFiledAsAFilm() throws {
    for name in ["public.m3u-playlist", "public.pls-playlist", "com.scenarist.closed-caption"] {
      guard let type = UTType(name) else { continue }
      let kind = ConvertKind(fileType: type)
      XCTAssertNotEqual(kind, .video, name)
      XCTAssertNotEqual(kind, .audio, name)
      XCTAssertFalse(FormatCatalog.isReadableMedia(type), name)
    }
    XCTAssertTrue(FormatCatalog.isReadableMedia(.quickTimeMovie))
    XCTAssertTrue(FormatCatalog.isReadableMedia(.mp3))
  }

  /// macOS lists DDS among the formats it writes and then writes none. A
  /// format is offered only if a picture has actually been written in it.
  func test_everyPictureFormatOfferedCanBeWritten() throws {
    let image = try XCTUnwrap(
      CGImageSourceCreateWithURL(try Fixture.image(at: path("square.png"), width: 256, height: 256) as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    )
    for type in FormatCatalog.writableImageTypes {
      let data = NSMutableData()
      let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination), "\(type.identifier) is offered and cannot be written")
    }
  }

  /// What an installed tool writes was reachable from the command line only:
  /// the sheet offered what macOS writes and nothing else. It is offered now,
  /// in a group of its own, for the files that can become it.
  func test_whatAToolWritesIsOfferedInAGroupOfItsOwn() async throws {
    try XCTSkipUnless(ExternalTools.locate("ffmpeg") != nil, "ffmpeg is not installed here")
    _ = ExternalBridge.ffmpegWrites
    _ = ExternalBridge.pandocFormats
    let mkv = try XCTUnwrap(UTType(filenameExtension: "mkv"))
    XCTAssertTrue(ExternalBridge.ffmpegWrites.contains("mkv"), "asked of ffmpeg, not written down here")

    let film = try ProcessableFile(url: try await Fixture.video(at: path("clip.mov"), seconds: 1, withAudio: true))
    let groups = ConvertKind.video.outputGroups(for: [film])
    let tools = try XCTUnwrap(groups.first { $0.title == "With your tools" })
    XCTAssertTrue(tools.formats.contains { $0.type == mkv })
    XCTAssertFalse(tools.formats.contains { $0.type == .mpeg4Movie }, "what macOS writes stays where it was")
  }

  /// A tool not on this Mac is offered for the kinds of file it serves and
  /// for no other, and an old Office file - which nothing on macOS opens -
  /// points at the one tool that would.
  func test_aMissingToolIsOfferedWhereItWouldHelp() throws {
    let office = try XCTUnwrap(ToolOffers.all.first { $0.formula == "libreoffice" })
    XCTAssertTrue(office.isCask)
    XCTAssertEqual(office.installCommand, "brew install --cask libreoffice")
    XCTAssertEqual(office.serves, [.document])

    let word97 = path("letter.doc")
    try Data("not really".utf8).write(to: word97)
    if !office.isInstalled {
      XCTAssertEqual(ToolOffers.opener(for: word97)?.formula, "libreoffice")
      XCTAssertTrue(ToolOffers.missing(for: [.document]).contains(office))
    }
    XCTAssertFalse(ToolOffers.missing(for: [.image]).contains(office), "not offered for pictures")
    XCTAssertNil(ToolOffers.opener(for: path("photo.png")), "a picture needs nothing installed")
  }
}
