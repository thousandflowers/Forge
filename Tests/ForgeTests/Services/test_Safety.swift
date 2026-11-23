import XCTest
import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
@testable import Forge

/// What running every function of the released build turned up in the parts
/// that decide whether a file survives: each of these lost something, or left
/// something behind, and most of them said the conversion had gone well.
final class SafetyTests: BaseTestCase {

  private func everything(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  // MARK: - Move

  /// A preset that writes two files ran the conversion twice, and the first
  /// run, told to move, deleted the original. The second then had nothing to
  /// read: one output, an error, and no source.
  func test_aMoveWithTwoFormatsKeepsTheOriginalUntilBothAreWritten() async throws {
    let source = try Fixture.image(at: path("photo.jpg"))
    let destination = try folder("out")
    var preset = RulePreset.make(category: .image)
    preset.actions = [.convertFormat(to: .png), .convertFormat(to: .tiff)]

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .moveTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    XCTAssertEqual(contents(of: destination), ["photo.png", "photo.tiff"])
    XCTAssertFalse(exists(source), "a move takes the original away once both copies exist")
  }

  func test_aMoveThroughASplitKeepsTheOriginalUntilEveryCopyIsWritten() async throws {
    let source = try Fixture.image(at: path("photo.jpg"))
    let destination = try folder("out")
    var preset = RulePreset.make(category: .image)
    preset.actions = [.split([
      Branch(name: "web", actions: [.convertFormat(to: .jpeg)]),
      Branch(name: "arch", actions: [.convertFormat(to: .png)]),
    ])]

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .moveTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    XCTAssertEqual(contents(of: destination), ["photo_arch.png", "photo_web.jpg"])
    XCTAssertFalse(exists(source))
  }

  // MARK: - History

  /// The record of a conversion is bookkeeping. With a History file that could
  /// not be read, every conversion wrote its output and was then reported as
  /// failed, for ever, because nothing ever repaired the file.
  func test_anUnreadableHistoryDoesNotTurnAConversionIntoAFailure() async throws {
    let source = try Fixture.image(at: path("photo.png"))
    let destination = try folder("out")
    let history = store.root.appendingPathComponent("History.json")
    try Data("not json at all".utf8).write(to: history)

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    XCTAssertEqual(contents(of: destination), ["photo.jpeg"])
    let recorded = try await store.loadHistory()
    XCTAssertEqual(recorded.count, 1, "history starts again, with this conversion in it")
    XCTAssertTrue(
      everything(in: store.root).contains { $0.hasPrefix("History.unreadable") },
      "what could not be read is set aside, not thrown away: \(everything(in: store.root))"
    )
  }

  // MARK: - Names

  /// A name template is text somebody else may have written - a preset from
  /// the gallery, a file a friend sent. `../../x` in one wrote outside the
  /// folder the user chose.
  func test_aNameTemplateCannotLeaveTheDestinationFolder() async throws {
    let source = try Fixture.image(at: path("photo.png"))
    let destination = try folder("deep/er/out")
    var preset = RulePreset.make(format: .jpeg, category: .image)
    preset.nameTemplate = "../../escaped_{name}"

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(
      output.deletingLastPathComponent().standardizedFileURL.path,
      destination.standardizedFileURL.path
    )
    XCTAssertEqual(everything(in: path("deep")), ["er"], "nothing was written above the destination")
  }

  func test_aNameIsOneNameNotAPath() {
    let context = NameTemplate.Static(name: "photo", ext: "jpeg")
    XCTAssertEqual(NameTemplate.resolve("a/b:{name}", with: context), "a-b-photo")
    XCTAssertEqual(NameTemplate.resolve("..{name}", with: context), "photo", "no hidden files, no way up")
    XCTAssertEqual(NameTemplate.resolve("{name}\nv2", with: context), "photo v2")
  }

  // MARK: - Leftovers

  /// ImageIO writes through a temporary file of its own, named after the one
  /// it was asked for with a dot in front. When the write failed that file
  /// stayed, hidden, in the user's folder - and the error named Forge's own
  /// scratch file instead of anything the user would recognise.
  func test_aWriteThatFailsLeavesNothingBehindAndNamesTheFile() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 300, height: 200)
    let destination = try folder("out")
    // Not square: ICNS only takes its own handful of square sizes.
    let icns = try XCTUnwrap(UTType("com.apple.icns"))

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: icns, category: .image),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      // If this Mac can write it after all, there is nothing to check.
    } catch {
      XCTAssertFalse(error.localizedDescription.contains(".forge-"), error.localizedDescription)
      XCTAssertTrue(error.localizedDescription.contains("photo.png"), error.localizedDescription)
    }
    XCTAssertEqual(
      everything(in: destination).filter { $0.hasPrefix(".") }, [],
      "hidden scratch files left in the destination"
    )
  }

  /// An OBJ keeps its materials in a library beside it. Model I/O wrote that
  /// under Forge's scratch name, where it stayed: a hidden `.forge-….mtl` in
  /// the user's folder, and an OBJ whose first lines pointed at it.
  func test_anOBJBringsItsMaterialsUnderItsOwnName() async throws {
    let source = path("shape.stl")
    // A tetrahedron, as ASCII STL.
    let corners = ["0 0 0", "1 0 0", "0 1 0", "0 0 1"]
    let faces = [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]].map { face in
      "facet normal 0 0 0\n outer loop\n" + face.map { "  vertex \(corners[$0])\n" }.joined() + " endloop\nendfacet\n"
    }
    try Data(("solid t\n" + faces.joined() + "endsolid t\n").utf8).write(to: source)
    let destination = try folder("out")
    let obj = try XCTUnwrap(UTType(filenameExtension: "obj"))

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: obj, category: .model),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")

    XCTAssertEqual(everything(in: destination).sorted(), ["shape.mtl", "shape.obj"])
    let written = try String(contentsOf: destination.appendingPathComponent("shape.obj"), encoding: .utf8)
    XCTAssertTrue(written.contains("mtllib shape.mtl"), written)
    XCTAssertFalse(written.contains(".forge-"), written)
  }

  /// OpenDocument was handed to the reader for Word files, which refused it:
  /// every ODT was "Cannot read", into every format.
  func test_anOpenDocumentFileIsRead() async throws {
    let source = path("letter.odt")
    let words = NSAttributedString(string: "HeadingAlpha and the rest of the letter.")
    try words.data(
      from: NSRange(location: 0, length: words.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]
    ).write(to: source)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .plainText, category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let text = try String(contentsOf: try XCTUnwrap(entry.outputURL), encoding: .utf8)
    XCTAssertTrue(text.contains("HeadingAlpha"), text)
  }

  // MARK: - Sound that is not there

  /// macOS opens FLAC inside Ogg - which is what `--to ogg` writes - but cannot
  /// say how long it is, so the copy loop ran zero times: an empty M4A,
  /// reported as converted. A recording with no frames at all takes the same
  /// path, and needs no ffmpeg to make.
  func test_aRecordingWithNothingToReadIsAFailureNotAnEmptyFile() async throws {
    let source = path("silence.wav")
    _ = try AVAudioFile(forWriting: source, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ])
    let destination = try folder("out")
    let m4a = try XCTUnwrap(UTType("com.apple.m4a-audio"))

    do {
      let entry = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: m4a, category: .audio),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      XCTAssertNotEqual(entry.status, .completed, "an empty file was reported as a conversion")
      XCTAssertTrue(entry.errorMessage?.contains("silence.wav") == true, entry.errorMessage ?? "no reason given")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("silence.wav"), error.localizedDescription)
    }
    XCTAssertEqual(everything(in: destination), [])
  }

  // MARK: - Duplicate

  /// Duplicate rebuilt the preset from the four fields the first version of
  /// Forge had, so the copy lost its name template, its questions, its test,
  /// its trigger word and every block that was not format, size, quality or
  /// filter - an If, a Split, a Merge, Remove metadata.
  func test_aDuplicateIsTheSamePresetUnderAnotherName() throws {
    var original = RulePreset.make(format: .jpeg, category: .image)
    original.name = "Web"
    original.actions += [
      .stripMetadata(policy: .stripAll),
      .split([Branch(name: "a", actions: [.resize(width: 800, height: nil, fitMode: .proportional)]), Branch(name: "b")]),
      .join,
    ]
    original.nameTemplate = "{name}_v{width}"
    original.nameTrigger = "web"
    original.inputFormats = ["png", "heic"]
    original.gate = try JSONDecoder().decode(
      Condition.self,
      from: Data(#"{"subject":"longestSide","comparison":"greaterThan","value":2000,"text":""}"#.utf8)
    )

    let copy = original.duplicate()

    XCTAssertNotEqual(copy.id, original.id)
    XCTAssertEqual(copy.name, "Web copy")
    XCTAssertEqual(copy.actions, original.actions)
    XCTAssertEqual(copy.nameTemplate, original.nameTemplate)
    XCTAssertEqual(copy.inputFormats, original.inputFormats)
    XCTAssertEqual(copy.gate, original.gate)
    XCTAssertEqual(copy.parameters, original.parameters)
    XCTAssertNil(copy.nameTrigger, "two presets answering to one word would fight over the file")
  }

  // MARK: - Several files from one

  /// Two image branches of a three-page PDF, merged, came to four pages: the
  /// first branch's three, and only the first page of the second.
  func test_aMergeKeepsEveryPageOfEveryCopy() async throws {
    let source = try Fixture.pdf(at: path("doc.pdf"), pages: 3)
    let destination = try folder("out")
    var preset = RulePreset.make(category: .document)
    preset.actions = [
      .split([
        Branch(name: "a", actions: [.convertFormat(to: .jpeg)]),
        Branch(name: "b", actions: [.convertFormat(to: .png)]),
      ]),
      .merge(.pdf),
    ]

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let merged = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(entry.outputURL)))
    XCTAssertEqual(merged.pageCount, 6)
  }

  /// A watched folder tells its own output from new arrivals by what the
  /// conversion says it wrote. A split of a several-page PDF named only some
  /// of its files, and the rest were converted again, and again.
  func test_aConversionNamesEveryFileItWrote() async throws {
    let source = try Fixture.pdf(at: path("doc.pdf"), pages: 3)
    let destination = try folder("out")
    var preset = RulePreset.make(category: .document)
    preset.actions = [.split([
      Branch(name: "a", actions: [.convertFormat(to: .jpeg)]),
      Branch(name: "b", actions: [.convertFormat(to: .png)]),
    ])]

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(contents(of: destination).count, 6)
    XCTAssertEqual(Set(entry.outputs.map(\.lastPathComponent)), Set(contents(of: destination)))
  }

  // MARK: - Locked

  /// A PDF that wants a password rendered as blank pages, was reported as
  /// converted, and with "move" the real document was then deleted.
  func test_aLockedPDFIsRefusedAndLeftWhereItIs() async throws {
    let plain = try Fixture.pdf(at: path("plain.pdf"), pages: 2)
    let source = path("locked.pdf")
    XCTAssertTrue(try XCTUnwrap(PDFDocument(url: plain)).write(
      to: source, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]
    ))
    XCTAssertTrue(try XCTUnwrap(PDFDocument(url: source)).isLocked, "the fixture is a locked one")
    let destination = try folder("out")

    for format in [UTType.jpeg, .plainText] {
      do {
        _ = try await coordinator().processFile(
          try ProcessableFile(url: source),
          with: .make(format: format, category: .document),
          destinationMode: .moveTo,
          destinationURL: destination
        ) { _ in }
        XCTFail("a locked PDF has nothing to convert yet (\(format.identifier))")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("locked"), error.localizedDescription)
      }
    }
    XCTAssertEqual(everything(in: destination), [])
    XCTAssertTrue(exists(source), "a refused file stays where it was")
  }

  // MARK: - The editor's If

  /// Choosing another subject changed only the comparison: the two were
  /// written one after the other and the second write undid the first.
  func test_aConditionAskedOfSomethingElseKeepsTheNewSubject() throws {
    let longest = try JSONDecoder().decode(
      Condition.self,
      from: Data(#"{"subject":"longestSide","comparison":"greaterThan","value":2000,"text":""}"#.utf8)
    )

    let byExtension = longest.testing(.fileExtension)
    XCTAssertEqual(byExtension.subject, .fileExtension)
    XCTAssertEqual(byExtension.comparison, .equals, "an extension cannot be more than anything")

    let byWidth = longest.testing(.width)
    XCTAssertEqual(byWidth.subject, .width)
    XCTAssertEqual(byWidth.comparison, .greaterThan, "a comparison that still makes sense is kept")
  }

  /// "jpeg" and "jpg" are one format spelled two ways, as are tif and tiff. A
  /// test for one spelling passed over every file named with the other.
  func test_anExtensionTestKnowsTwoSpellingsOfOneFormat() throws {
    let photo = try ProcessableFile(url: try Fixture.image(at: path("photo.jpg"), width: 10, height: 10))
    func holds(_ comparison: Condition.Comparison, _ text: String) -> Bool {
      var condition = Condition()
      condition.subject = .fileExtension
      condition.comparison = comparison
      condition.text = text
      return condition.holds(for: photo)
    }

    XCTAssertTrue(holds(.equals, "jpg"))
    XCTAssertTrue(holds(.equals, "jpeg"))
    XCTAssertTrue(holds(.equals, ".JPEG"))
    XCTAssertFalse(holds(.equals, "png"))
    XCTAssertFalse(holds(.differs, "jpeg"))
    XCTAssertTrue(holds(.differs, "png"))
    XCTAssertTrue(holds(.equals, ""), "no text yet is no test yet")
  }

  /// One extension, several types. macOS files an .orf as
  /// `com.olympus.raw-image`; ImageIO lists the two types beside it. Compared
  /// by name, every Olympus raw was "Forge cannot open ORF files", while the
  /// list of formats said ORF was read.
  func test_aPhotoFiledUnderAnotherNameForTheSameExtensionIsRead() throws {
    let filed = try XCTUnwrap(UTType(filenameExtension: "orf"))
    let listed = UTType.types(tag: "orf", tagClass: .filenameExtension, conformingTo: nil)
      .filter(FormatCatalog.readableImageTypes.contains)
    try XCTSkipIf(listed.isEmpty, "this Mac reads no ORF at all")

    XCTAssertTrue(FormatCatalog.isReadableImage(filed), filed.identifier)
    XCTAssertFalse(FormatCatalog.isReadableImage(.plainText))
    XCTAssertFalse(FormatCatalog.isReadableImage(try XCTUnwrap(UTType(filenameExtension: "nothing-reads-this"))))
  }

  /// Half a photograph decoded as far as it went, the rest grey; a third of a
  /// recording came out a third as long. Both were reported as converted.
  func test_aFileThatStopsBeforeItsEndIsRefused() async throws {
    let photo = try Fixture.image(at: path("whole.jpg"), width: 800, height: 600)
    let picture = try Fixture.image(at: path("whole.png"), width: 400, height: 300)
    let sound = try Fixture.audio(at: path("whole.wav"), seconds: 2)
    for whole in [photo, picture, sound] {
      XCTAssertNil(Completeness.whatIsMissing(whole), "\(whole.lastPathComponent) is whole")
      let bytes = try Data(contentsOf: whole)
      let cut = path("cut." + whole.pathExtension)
      try bytes.prefix(bytes.count * 6 / 10).write(to: cut)
      XCTAssertNotNil(Completeness.whatIsMissing(cut), "\(cut.lastPathComponent) was cut off")

      do {
        let entry = try await coordinator().processFile(
          try ProcessableFile(url: cut), with: .make(format: whole.pathExtension == "wav" ? .aiff : .tiff, category: .custom),
          destinationMode: .copyTo, destinationURL: try folder("out-\(UUID().uuidString.prefix(4))")
        ) { _ in }
        XCTAssertNotEqual(entry.status, .completed, "\(cut.lastPathComponent) was reported as converted")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("incomplete"), error.localizedDescription)
      }
    }
  }
}
