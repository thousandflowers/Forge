import XCTest
import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Forge

/// What a converted file stops saying about the person who made it, and what it
/// must go on saying about itself.
///
/// The second half is the one that breaks things: an image without its
/// orientation arrives on its side, and one without its colour profile arrives
/// the wrong colour. Both are asserted on every strip.
final class PrivacyTests: BaseTestCase {

  // MARK: - Images

  func test_stripLocation_takesTheGPSAndLeavesTheRest() async throws {
    let source = try photograph(at: path("holiday.jpg"))
    let output = try await convert(source, policy: .stripLocation)

    let properties = try Self.properties(of: output)
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "where it was taken is gone")

    let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Fake", "and nothing else was touched")
  }

  func test_stripAll_takesTheDeviceAndTheMomentTo() async throws {
    let source = try photograph(at: path("holiday.jpg"))
    let output = try await convert(source, policy: .stripAll)

    let properties = try Self.properties(of: output)
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])

    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNil(tiff[kCGImagePropertyTIFFMake], "which camera took it is not the picture")
    XCTAssertNil(tiff[kCGImagePropertyTIFFModel])

    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal], "when it was taken is not the picture either")
    XCTAssertNil(exif[kCGImagePropertyExifBodySerialNumber])
  }

  /// "Remove the location" took the coordinates and left the name of the place:
  /// city, province, country and neighbourhood, which any photo app that knows
  /// them writes beside the coordinates. Measured in JPEG, PNG, HEIC and TIFF.
  func test_stripLocation_takesTheNameOfThePlaceToo() async throws {
    let source = try Fixture.image(at: path("venice.jpg"), metadata: [
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 45.4408,
        kCGImagePropertyGPSLongitude: 12.3155,
      ] as [CFString: Any],
      kCGImagePropertyIPTCDictionary: [
        kCGImagePropertyIPTCCity: "Venezia",
        kCGImagePropertyIPTCSubLocation: "Dorsoduro",
        kCGImagePropertyIPTCProvinceState: "Veneto",
        kCGImagePropertyIPTCCountryPrimaryLocationName: "Italia",
        kCGImagePropertyIPTCCountryPrimaryLocationCode: "ITA",
        kCGImagePropertyIPTCByline: ["Mario Rossi"],
      ] as [CFString: Any],
    ])
    try Self.expect(["Venezia", "Dorsoduro", "Veneto", "Italia", "Mario Rossi"], in: source)

    let output = try await convert(source, policy: .stripLocation)

    try Self.expectNone(of: ["Venezia", "Dorsoduro", "Veneto", "Italia"], in: output)
    try Self.expect(["Mario Rossi"], in: output)  // who took it was not asked about
  }

  /// "Remove identifying metadata" left the caption - the line most likely to
  /// say whose house it is.
  func test_stripAll_takesTheCaption() async throws {
    let source = try Fixture.image(at: path("house.jpg"), metadata: [
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFImageDescription: "Casa di Mario",
        kCGImagePropertyTIFFDocumentName: "mario-privato",
      ] as [CFString: Any],
    ])
    try Self.expect(["Casa di Mario", "mario-privato"], in: source)

    let output = try await convert(source, policy: .stripAll)

    try Self.expectNone(of: ["Casa di Mario", "mario-privato"], in: output)
  }

  /// A PNG says who made it in its own words - Author, Software, Comment -
  /// which are not EXIF and were carried across whole, then written out again
  /// as XMP in whatever format was asked for.
  func test_stripAll_takesWhatAPNGSaysAboutItsAuthor() async throws {
    let source = try Fixture.image(at: path("drawing.png"), metadata: [
      kCGImagePropertyPNGDictionary: [
        kCGImagePropertyPNGAuthor: "Mario Rossi",
        kCGImagePropertyPNGSoftware: "SecretApp",
        kCGImagePropertyPNGDescription: "Casa di Mario",
        kCGImagePropertyPNGTitle: "titolo-privato",
        kCGImagePropertyPNGCopyright: "diritti-di-mario",
      ] as [CFString: Any],
    ])
    try Self.expect(["Mario Rossi", "SecretApp"], in: source)
    let words = ["Mario Rossi", "SecretApp", "Casa di Mario", "titolo-privato", "diritti-di-mario"]

    for format in [UTType.png, .jpeg] {
      var preset = RulePreset.make(format: format, category: .image)
      preset.actions.append(.stripMetadata(policy: .stripAll))
      let entry = try await coordinator().processFile(
        try ProcessableFile(url: source), with: preset,
        destinationMode: .copyTo, destinationURL: try folder("out-\(format.preferredFilenameExtension ?? "x")")
      ) { _ in }
      try Self.expectNone(of: words, in: try XCTUnwrap(entry.outputURL))
    }
  }

  /// The words, looked for in the bytes: a tag removed under one name and
  /// written again under another (IPTC as XMP) is still in the file.
  private static func expectNone(of words: [String], in url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let bytes = try Data(contentsOf: url)
    for word in words {
      XCTAssertNil(bytes.range(of: Data(word.utf8)), "\(url.lastPathComponent) still says “\(word)”", file: file, line: line)
    }
  }

  private static func expect(_ words: [String], in url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let bytes = try Data(contentsOf: url)
    for word in words {
      XCTAssertNotNil(bytes.range(of: Data(word.utf8)), "\(url.lastPathComponent) should say “\(word)”", file: file, line: line)
    }
  }

  /// The critical one. A file that has been made anonymous and unreadable is
  /// not a success.
  func test_stripAll_keepsTheOrientationAndTheColourProfile() async throws {
    let source = try photograph(at: path("holiday.jpg"))
    let output = try await convert(source, policy: .stripAll)

    // The picture is turned upright in its pixels now, so what has to survive
    // is not the note that said "turn me" but the turn itself: the source is
    // stored one way and seen the other, and the output is seen the same way.
    func seen(_ url: URL) throws -> [Int] {
      let properties = try Self.properties(of: url)
      let stored = [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight].map { properties[$0] as? Int ?? 0 }
      let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
      return orientation >= 5 ? stored.reversed() : stored
    }
    XCTAssertEqual(try seen(output), try seen(source), "without this the photograph arrives on its side")
    XCTAssertEqual(try Self.properties(of: source)[kCGImagePropertyOrientation] as? Int, 6, "the fixture is a turned one")

    let image = try XCTUnwrap(Self.image(at: output))
    XCTAssertNotNil(image.colorSpace, "without a profile the colours are a guess")
  }

  /// Keeping everything is what a conversion does when nobody asked otherwise.
  func test_keepAll_carriesTheLocationAcross() async throws {
    let source = try photograph(at: path("holiday.jpg"))
    let output = try await convert(source, policy: nil)

    let properties = try Self.properties(of: output)
    XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary])
  }

  /// The filter is a pure function over the properties, so the rule can be read
  /// without writing a file at all.
  func test_filter_isDecidedByLists_notByFormat() {
    let properties: [CFString: Any] = [
      kCGImagePropertyGPSDictionary: ["Latitude": 45.44],
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyProfileName: "sRGB IEC61966-2.1",
      "{MakerApple}" as CFString: ["3": 1],
      kCGImagePropertyIPTCDictionary: ["Byline": "Somebody"],
    ]

    let located = PrivacyFilter.filter(properties, to: .stripLocation)
    XCTAssertNil(located[kCGImagePropertyGPSDictionary])
    XCTAssertNotNil(located["{MakerApple}" as CFString], "the location, and only the location")

    let stripped = PrivacyFilter.filter(properties, to: .stripAll)
    XCTAssertNil(
      stripped["{MakerApple}" as CFString],
      "a maker note is named after its camera; the shape of the key is the rule"
    )
    XCTAssertNil(stripped[kCGImagePropertyIPTCDictionary])
    XCTAssertEqual(stripped[kCGImagePropertyOrientation] as? Int, 6)
    XCTAssertNotNil(stripped[kCGImagePropertyProfileName])
  }

  // MARK: - Films and recordings

  private func film(at name: String) async throws -> URL {
    let url = path(name)
    try await Fixture.writePictureTrack(to: url, seconds: 1, size: CGSize(width: 320, height: 240), metadata: [
      Fixture.tag(.commonIdentifierTitle, "Titolo Film"),
      Fixture.tag(.commonIdentifierLocation, "+45.4408+012.3155/"),
      Fixture.tag(.commonIdentifierCopyrights, "diritti-di-mario"),
      Fixture.tag(.commonIdentifierMake, "TestCam"),
      Fixture.tag(.commonIdentifierDescription, "nota privata"),
    ])
    return url
  }

  private func run(_ source: URL, to format: UTType, _ policy: PrivacyPolicy, category: PresetCategory) async throws -> URL {
    var preset = RulePreset.make(format: format, category: category)
    preset.actions.append(.stripMetadata(policy: policy))
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source), with: preset,
      destinationMode: .copyTo, destinationURL: try folder("out-\(UUID().uuidString.prefix(6))")
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    return try XCTUnwrap(entry.outputURL)
  }

  /// "Remove the location" left where a film was shot in the film: the test
  /// for a location key looked for the word in the key's name, and QuickTime
  /// calls it `©xyz`.
  func test_film_stripLocation_takesWhereItWasShot() async throws {
    let source = try await film(at: "holiday.mov")
    try Self.expect(["+45.4408", "Titolo Film"], in: source)

    for format in [UTType.quickTimeMovie, .mpeg4Movie] {
      let output = try await run(source, to: format, .stripLocation, category: .video)
      try Self.expectNone(of: ["+45.4408", "45.44"], in: output)
      try Self.expect(["Titolo Film"], in: output)  // only the place was asked about
    }
  }

  /// "Remove identifying metadata" left the copyright line and the camera.
  func test_film_stripAll_takesTheCopyrightTheCameraAndTheNote() async throws {
    let source = try await film(at: "holiday.mov")
    try Self.expect(["diritti-di-mario", "TestCam", "nota privata"], in: source)

    for format in [UTType.quickTimeMovie, .mpeg4Movie] {
      let output = try await run(source, to: format, .stripAll, category: .video)
      try Self.expectNone(of: ["diritti-di-mario", "TestCam", "nota privata", "+45.4408"], in: output)
    }
  }

  /// On a recording it removed nothing at all: the comment and the copyright
  /// line stayed. What the recording is called and who performs it stay on
  /// purpose - that is what a music file is.
  func test_recording_stripAll_takesTheNoteAndTheCopyrightAndKeepsTheTitle() async throws {
    let source = try await Fixture.taggedAudio(at: path("song.m4a"), title: "Titolo Brano", artist: "Banda", more: [
      Fixture.tag(.commonIdentifierCopyrights, "diritti-di-mario"),
      Fixture.tag(.commonIdentifierDescription, "nota privata"),
      Fixture.tag(.commonIdentifierSoftware, "SecretApp"),
    ])
    try Self.expect(["diritti-di-mario", "Titolo Brano"], in: source)
    let m4a = try XCTUnwrap(UTType("com.apple.m4a-audio"))

    let output = try await run(source, to: m4a, .stripAll, category: .audio)

    try Self.expectNone(of: ["diritti-di-mario", "nota privata", "SecretApp"], in: output)
    try Self.expect(["Titolo Brano", "Banda"], in: output)
  }

  /// Keeping everything lost everything whenever the recording changed family:
  /// the tags were handed over under the names the old format calls them, and
  /// the new one did not know those names.
  func test_recording_keepsItsTagsWhenItChangesFamily() async throws {
    let source = try await Fixture.taggedAudio(
      at: path("memo.mov"), title: "Titolo Brano", artist: "Banda",
      preset: AVAssetExportPresetPassthrough, fileType: .mov
    )
    try Self.expect(["Titolo Brano", "Banda"], in: source)
    let m4a = try XCTUnwrap(UTType("com.apple.m4a-audio"))

    let output = try await run(source, to: m4a, .keepAll, category: .audio)

    try Self.expect(["Titolo Brano", "Banda"], in: output)
  }

  // MARK: - Documents

  /// Keeping everything lost who wrote a document and what it is called.
  @MainActor
  func test_document_keepsItsAuthorAndTitle_andLosesTheAuthorWhenAsked() async throws {
    let source = path("letter.docx")
    let words = NSAttributedString(string: "HeadingAlpha and the rest of the letter.")
    try words.data(from: NSRange(location: 0, length: words.length), documentAttributes: [
      .documentType: NSAttributedString.DocumentType.officeOpenXML,
      .author: "Mario Rossi", .title: "Titolo Documento", .company: "Azienda Privata",
    ]).write(to: source)
    let docx = try XCTUnwrap(UTType("org.openxmlformats.wordprocessingml.document"))
    func attributes(of url: URL) throws -> [NSAttributedString.DocumentAttributeKey: Any] {
      var read: NSDictionary?
      _ = try NSAttributedString(url: url, options: [:], documentAttributes: &read)
      return (read as? [NSAttributedString.DocumentAttributeKey: Any]) ?? [:]
    }
    XCTAssertEqual(try attributes(of: source)[.author] as? String, "Mario Rossi", "the fixture carries it")

    let kept = try attributes(of: try await run(source, to: docx, .keepAll, category: .document))
    XCTAssertEqual(kept[.author] as? String, "Mario Rossi")
    XCTAssertEqual(kept[.title] as? String, "Titolo Documento")

    let stripped = try await run(source, to: docx, .stripAll, category: .document)
    let left = try attributes(of: stripped)
    XCTAssertNil(left[.author])
    XCTAssertNil(left[.company])
    XCTAssertEqual(left[.title] as? String, "Titolo Documento", "what it is called is not who wrote it")
  }

  // MARK: - PDF

  func test_pdf_losesItsAuthorButKeepsItsPages() throws {
    let source = try Self.pdf(at: path("contract.pdf"), author: "Somebody Real", title: "Contract")
    let before = try XCTUnwrap(PDFDocument(url: source))
    XCTAssertEqual(
      before.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Somebody Real"
    )

    try PrivacyFilter.strip(pdfAt: source, to: .stripAll)

    let after = try XCTUnwrap(PDFDocument(url: source))
    XCTAssertNil(after.documentAttributes?[PDFDocumentAttribute.authorAttribute])
    XCTAssertNil(after.documentAttributes?[PDFDocumentAttribute.creatorAttribute])
    XCTAssertEqual(after.pageCount, before.pageCount, "the document is still the document")
    XCTAssertEqual(
      after.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Contract",
      "what it is called is not who wrote it"
    )
  }

  /// A PDF has no location, so asking for the location to go changes nothing.
  /// A PDF says who wrote it twice: in its Info dictionary, and in an XMP
  /// packet. Taking the first and copying the second across left the name in a
  /// file that had been through "remove identifying metadata" - which is what
  /// `contract_privacy.pdf` in the README is for.
  func test_pdf_losesItsAuthorFromTheXMPPacketToo() throws {
    let url = path("contract.pdf")
    var box = CGRect(x: 0, y: 0, width: 300, height: 200)
    let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, [
      kCGPDFContextAuthor: "Mario Rossi",
      kCGPDFContextTitle: "Contratto",
    ] as CFDictionary))
    let packet = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <pdf:Author>Mario Rossi</pdf:Author><dc:creator><rdf:Seq><rdf:li>Mario Rossi</rdf:li></rdf:Seq></dc:creator>
    </rdf:Description></rdf:RDF></x:xmpmeta>
    <?xpacket end="w"?>
    """
    context.addDocumentMetadata(Data(packet.utf8) as CFData)
    for _ in 0..<2 {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(gray: 0.5, alpha: 1))
      context.fill(box)
      context.endPDFPage()
    }
    context.closePDF()
    try Self.expect(["Mario Rossi"], in: url)
    XCTAssertTrue(Self.packet(of: url).contains("Mario Rossi"), "the fixture carries the packet")

    try PrivacyFilter.strip(pdfAt: url, to: .stripAll)

    // Both ways: in the bytes, and in the packet as a reader decodes it, since
    // a packet can be stored compressed and say nothing to a search.
    try Self.expectNone(of: ["Mario Rossi"], in: url)
    XCTAssertFalse(Self.packet(of: url).contains("Mario Rossi"), Self.packet(of: url))
    let document = try XCTUnwrap(PDFDocument(url: url), "and it is still a PDF")
    XCTAssertEqual(document.pageCount, 2)
    XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Contratto")
  }

  func test_pdf_isLeftAloneWhenOnlyTheLocationWasAskedAbout() throws {
    let source = try Self.pdf(at: path("contract.pdf"), author: "Somebody Real", title: "Contract")
    try PrivacyFilter.strip(pdfAt: source, to: .stripLocation)

    let after = try XCTUnwrap(PDFDocument(url: source))
    XCTAssertEqual(
      after.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Somebody Real"
    )
  }

  // MARK: - The name

  func test_nameTokens_readBothInstructions() {
    XCTAssertEqual(
      NameTokens.read("holiday_10MB_privacy.jpg"),
      NameTokens.Read(ceiling: 10_000_000, privacy: .stripAll),
      "one name, two instructions - reading only the last piece hid the size"
    )
    XCTAssertEqual(
      NameTokens.read("contract_privacy.pdf"),
      NameTokens.Read(ceiling: nil, privacy: .stripAll)
    )
    XCTAssertEqual(NameTokens.read("holiday_10MB.jpg"), NameTokens.Read(ceiling: 10_000_000, privacy: nil))
    XCTAssertEqual(NameTokens.read("holiday.jpg"), NameTokens.Read())
  }

  /// The old rules still hold: an instruction is at the end of the name, and a
  /// size that is the subject of the name is not an instruction.
  func test_nameTokens_stopAtTheFirstPieceThatIsNotAnInstruction() {
    XCTAssertNil(NameTokens.read("10MB_notes.jpg").ceiling)
    XCTAssertNil(NameTokens.read("privacy.pdf").privacy, "a file called privacy is a file called privacy")
    XCTAssertEqual(NameTokens.read("holiday_2024_5MB.jpg").ceiling, 5_000_000)
    XCTAssertNil(NameTokens.read("report_final.pdf").ceiling)
  }

  func test_nameTokens_putBothStepsInTheChain() {
    let chain = NameTokens.applying(to: [.convertFormat(to: .jpeg)], from: "holiday_10MB_privacy.jpg")

    XCTAssertTrue(chain.contains(.limitSize(bytes: 10_000_000)))
    XCTAssertTrue(chain.contains(.stripMetadata(policy: .stripAll)))
    XCTAssertTrue(chain.contains(.convertFormat(to: .jpeg)), "and what was already asked for stays")
  }

  /// Typed by the user, so it is their instruction, not a surprise to confirm
  /// back at them.
  func test_privacyToken_isExplicitSoNothingIsAsked() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("holiday_privacy.png")))
    let plan = ConversionPlan(
      file: file,
      preset: .make(format: .jpeg, category: .image),
      destinationMode: .copyTo
    )
    XCTAssertEqual(plan.confirmationLevel, .silent)

    let both = try ProcessableFile(url: try Fixture.image(at: path("holiday_10MB_privacy.png")))
    let bothPlan = ConversionPlan(
      file: both,
      preset: .make(format: .jpeg, category: .image),
      destinationMode: .copyTo
    )
    XCTAssertTrue(bothPlan.magicWasExplicit, "the size is still read when a second token follows it")
    XCTAssertEqual(bothPlan.confirmationLevel, .silent)
  }

  // MARK: - Who wins

  /// General, then specific, then this once, then the name.
  func test_precedence_settingsThenPresetThenName() {
    var settings = AppSettings()
    settings.privacy = .stripLocation

    // Settings alone: filled in wherever the chain says nothing.
    let fromSettings = settings.applyingDefaults(to: [.convertFormat(to: .jpeg)], writing: .jpeg)
    XCTAssertEqual(PrivacyFilter.policy(in: fromSettings), .stripLocation)

    // A preset - or a batch, which builds the same chain - is not overruled by
    // the preference, in either direction.
    let fromPreset = settings.applyingDefaults(
      to: [.convertFormat(to: .jpeg), .stripMetadata(policy: .keepAll)], writing: .jpeg
    )
    XCTAssertEqual(PrivacyFilter.policy(in: fromPreset), .keepAll, "a preset can also ask for less")

    // And the name beats all of it.
    let fromName = NameTokens.applying(to: fromPreset, from: "holiday_privacy.jpg")
    XCTAssertEqual(PrivacyFilter.policy(in: fromName), .stripAll)
    XCTAssertEqual(
      fromName.filter { if case .stripMetadata = $0 { return true } else { return false } }.count, 1,
      "one answer, not two"
    )
  }

  // MARK: - What the sheet shows

  /// Picking a preset fills the fields in from it - and clears the ones it says
  /// nothing about.
  ///
  /// Leaving the last preset's answer behind is not only a wrong-looking chip:
  /// touching any other field lets the preset go, and then that stale answer is
  /// what actually runs.
  func test_choosingAPreset_clearsWhatTheLastOneSaid() {
    var thorough = RulePreset.make(format: .jpeg, category: .image)
    thorough.actions.append(.stripMetadata(policy: .stripAll))
    thorough.actions.append(.limitSize(bytes: 5_000_000))

    let choice = ConvertChoice().adopting(thorough)
    XCTAssertEqual(choice.privacy, .stripAll)
    XCTAssertEqual(choice.maxBytes, 5_000_000)

    let plain = RulePreset.make(format: .png, category: .image)
    let after = choice.adopting(plain)

    XCTAssertNil(after.privacy, "this preset says nothing about metadata, so neither does the sheet")
    XCTAssertNil(after.maxBytes, "and nothing about a size ceiling either")
    XCTAssertEqual(after.presetID, plain.id)
  }

  // MARK: - Fixtures

  /// A JPEG with the things a camera writes: where, what, when, and which way
  /// up.
  private func photograph(at url: URL) throws -> URL {
    try Fixture.image(at: url, metadata: [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 45.4408,
        kCGImagePropertyGPSLongitude: 12.3155,
      ] as [CFString: Any],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Fake",
        kCGImagePropertyTIFFModel: "Camera One",
      ] as [CFString: Any],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:09:05 12:00:00",
        kCGImagePropertyExifBodySerialNumber: "SN-000000",
      ] as [CFString: Any],
    ])
  }

  /// Convert it the way the app would, with the policy in the chain.
  private func convert(_ source: URL, policy: PrivacyPolicy?) async throws -> URL {
    var preset = RulePreset.make(format: .jpeg, quality: 90, category: .image)
    if let policy { preset.actions.append(.stripMetadata(policy: policy)) }

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: try folder("out")
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    return try XCTUnwrap(entry.outputURL)
  }

  /// The document's XMP packet, decoded the way a reader would.
  private static func packet(of url: URL) -> String {
    guard let document = CGPDFDocument(url as CFURL), let catalog = document.catalog else { return "" }
    var stream: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return "" }
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(stream, &format) else { return "" }
    return String(decoding: data as Data, as: UTF8.self)
  }

  private static func properties(of url: URL) throws -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
      throw Failure("Cannot read \(url.lastPathComponent)")
    }
    return properties
  }

  private static func image(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func pdf(at url: URL, author: String, title: String) throws -> URL {
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    document.documentAttributes = [
      PDFDocumentAttribute.authorAttribute: author,
      PDFDocumentAttribute.creatorAttribute: "Something That Writes PDFs",
      PDFDocumentAttribute.titleAttribute: title,
    ]
    guard document.write(to: url) else { throw Failure("Cannot write the PDF fixture") }
    return url
  }
}
