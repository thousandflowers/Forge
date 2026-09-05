import XCTest
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

  /// The critical one. A file that has been made anonymous and unreadable is
  /// not a success.
  func test_stripAll_keepsTheOrientationAndTheColourProfile() async throws {
    let source = try photograph(at: path("holiday.jpg"))
    let output = try await convert(source, policy: .stripAll)

    let properties = try Self.properties(of: output)
    XCTAssertEqual(
      properties[kCGImagePropertyOrientation] as? Int, 6,
      "without this the photograph arrives on its side"
    )

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
