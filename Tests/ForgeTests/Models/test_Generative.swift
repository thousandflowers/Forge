import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// Presets that ask instead of deciding, and the general preferences a preset
/// falls back to when it says nothing.
final class GenerativePresetTests: BaseTestCase {

  /// The whole point of a size ceiling: the file that lands is under it, and
  /// says so in its name.
  func test_aPresetAskedForASizeFitsUnderItAndSaysSoInTheName() async throws {
    let source = try Fixture.image(at: path("holiday.png"), width: 2400, height: 1600)
    let destination = try folder("out")
    let ceiling = 100_000

    var preset = RulePreset(
      name: "Under a size",
      description: "",
      category: .image,
      actions: [.convertFormat(to: .jpeg)]
    )
    preset.parameters = [PresetParameter(key: "maxsize", label: "Maximum size", kind: .maxFileSize, defaultValue: 0.1)]
    preset.nameTemplate = "{name}_{maxsize}"
    // What the sheet does once the question is answered.
    preset = preset.replacing(.limitSize(bytes: ceiling))
    preset.parameterValues["maxsize"] = 0.1

    let history = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination,
      progress: { _ in }
    )

    let output = try XCTUnwrap(history.outputURL)
    XCTAssertEqual(output.lastPathComponent, "holiday_0.1MB.jpeg")
    XCTAssertLessThanOrEqual(size(of: output), Int64(ceiling))
    XCTAssertGreaterThan(size(of: output), 0)
  }

  /// A preset with no template is named the way it always was.
  func test_aPresetWithoutATemplateKeepsTheOldName() async throws {
    let source = try Fixture.image(at: path("plain.png"), width: 400, height: 300)
    let destination = try folder("out")

    let preset = RulePreset(
      name: "Plain",
      description: "",
      category: .image,
      actions: [.convertFormat(to: .jpeg)]
    )

    let history = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination,
      progress: { _ in }
    )

    XCTAssertEqual(try XCTUnwrap(history.outputURL).lastPathComponent, "plain.jpeg")
  }

  /// A token nobody answered is dropped, not printed as itself.
  func test_anUnansweredTokenLeavesNoBraces() async throws {
    let source = try Fixture.image(at: path("odd.png"), width: 200, height: 200)
    let destination = try folder("out")

    var preset = RulePreset(
      name: "Odd",
      description: "",
      category: .image,
      actions: [.convertFormat(to: .jpeg)]
    )
    preset.nameTemplate = "{name}_{nobodyAnswered}"

    let history = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination,
      progress: { _ in }
    )

    let name = try XCTUnwrap(history.outputURL).lastPathComponent
    XCTAssertFalse(name.contains("{"))
    XCTAssertFalse(name.contains("}"))
  }
}

/// A question knows the action it becomes and how it reads in a filename.
final class PresetParameterTests: XCTestCase {

  func test_eachQuestionBecomesTheActionItStandsFor() {
    let size = PresetParameter(key: "maxsize", label: "Max", kind: .maxFileSize)
    guard case .limitSize(let bytes) = size.operation(for: 10) else { return XCTFail("expected a ceiling") }
    XCTAssertEqual(bytes, 10_000_000)

    let width = PresetParameter(key: "w", label: "Width", kind: .width)
    guard case .resize(let pixels, _, _) = width.operation(for: 1280) else { return XCTFail("expected a resize") }
    XCTAssertEqual(pixels, 1280)

    let quality = PresetParameter(key: "q", label: "Quality", kind: .quality)
    guard case .quality(let level) = quality.operation(for: 70) else { return XCTFail("expected a quality") }
    XCTAssertEqual(level, 70)
  }

  func test_theAnswerReadsAsSomethingAFilenameCanCarry() {
    XCTAssertEqual(PresetParameter(key: "s", label: "", kind: .maxFileSize).token(for: 10), "10MB")
    XCTAssertEqual(PresetParameter(key: "s", label: "", kind: .maxFileSize).token(for: 2.5), "2.5MB")
    XCTAssertEqual(PresetParameter(key: "w", label: "", kind: .width).token(for: 1920), "1920px")
    XCTAssertEqual(PresetParameter(key: "q", label: "", kind: .quality).token(for: 80), "Q80")
  }

  /// A preset that carries questions has to survive a save and a load, or the
  /// question is asked once and forgotten.
  func test_questionsSurviveASaveAndLoad() throws {
    var preset = RulePreset(name: "Asks", description: "", category: .image)
    preset.parameters = [PresetParameter(key: "maxsize", label: "How big", kind: .maxFileSize, defaultValue: 5)]
    preset.nameTemplate = "{name}_{maxsize}"

    let data = try JSONEncoder().encode(preset)
    let reloaded = try JSONDecoder().decode(RulePreset.self, from: data)

    XCTAssertEqual(reloaded.parameters.count, 1)
    XCTAssertEqual(reloaded.parameters.first?.key, "maxsize")
    XCTAssertEqual(reloaded.parameters.first?.defaultValue, 5)
    XCTAssertEqual(reloaded.nameTemplate, "{name}_{maxsize}")
  }

  /// An answer belongs to one conversion, not to the preset.
  func test_answersAreNotSaved() throws {
    var preset = RulePreset(name: "Asks", description: "", category: .image)
    preset.parameterValues["maxsize"] = 10

    let reloaded = try JSONDecoder().decode(RulePreset.self, from: try JSONEncoder().encode(preset))
    XCTAssertTrue(reloaded.parameterValues.isEmpty)
  }
}

/// The general preferences are only preferences if something reads them.
final class GeneralPreferenceTests: XCTestCase {

  func test_qualityFallsBackToThePreference() {
    var settings = AppSettings()
    settings.defaultQuality = 42

    let filled = settings.applyingDefaults(to: [.convertFormat(to: .jpeg)], writing: .jpeg)
    let quality = filled.compactMap { if case .quality(let level) = $0 { return level } else { return nil } }
    XCTAssertEqual(quality, [42])
  }

  /// Audio reads a quality as a bitrate, and Apple Lossless refuses one. A
  /// general preference must not turn a working conversion into a failure.
  func test_thePreferenceStaysOutOfAudio() {
    var settings = AppSettings()
    settings.defaultQuality = 42

    let filled = settings.applyingDefaults(to: [.encode(codec: .appleLossless)], writing: .mpeg4Audio)
    XCTAssertEqual(filled.count, 1)
  }

  func test_aPresetThatNamesAQualityKeepsIt() {
    var settings = AppSettings()
    settings.defaultQuality = 42

    let filled = settings.applyingDefaults(to: [.quality(level: 91)], writing: .jpeg)
    let quality = filled.compactMap { if case .quality(let level) = $0 { return level } else { return nil } }
    XCTAssertEqual(quality, [91])
  }
}

/// A preset that names more than one format wants both, not the last one.
final class MultipleFormatTests: BaseTestCase {

  func test_twoFormatsWriteTwoFiles() async throws {
    let source = try Fixture.image(at: path("shot.png"), width: 600, height: 400)
    let destination = try folder("out")

    var preset = RulePreset(name: "Both", description: "", category: .image)
    preset.actions = [
      .convertFormat(to: .jpeg),
      .convertFormat(to: .tiff),
      .resize(width: 300, height: nil, fitMode: .proportional),
    ]

    _ = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination,
      progress: { _ in }
    )

    let written = contents(of: destination)
    XCTAssertEqual(written.count, 2, "one file per format: \(written)")
    XCTAssertTrue(written.contains { $0.hasSuffix(".jpeg") })
    XCTAssertTrue(written.contains { $0.hasSuffix(".tiff") })
  }

  /// Every copy still gets the rest of the chain.
  func test_bothCopiesAreResized() async throws {
    let source = try Fixture.image(at: path("wide.png"), width: 800, height: 400)
    let destination = try folder("out")

    var preset = RulePreset(name: "Both", description: "", category: .image)
    preset.actions = [
      .convertFormat(to: .jpeg),
      .convertFormat(to: .png),
      .resize(width: 200, height: nil, fitMode: .proportional),
    ]

    _ = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination,
      progress: { _ in }
    )

    for name in contents(of: destination) {
      let url = destination.appendingPathComponent(name)
      let file = try ProcessableFile(url: url)
      XCTAssertEqual(file.dimensions?.width, 200, "\(name) should have been resized too")
    }
  }

  /// Two files cannot both replace one original, and saying so beats writing
  /// one over the other.
  func test_twoFormatsRefuseToOverwrite() async throws {
    let source = try Fixture.image(at: path("only.png"), width: 200, height: 200)

    var preset = RulePreset(name: "Both", description: "", category: .image)
    preset.actions = [.convertFormat(to: .jpeg), .convertFormat(to: .tiff)]

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: preset,
        destinationMode: .overwrite,
        progress: { _ in }
      )
      XCTFail("replacing one original with two files should be refused")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains("cannot replace the original"),
        "the message has to say why: \(error.localizedDescription)"
      )
    }

    // And the original is untouched.
    XCTAssertEqual(try ProcessableFile(url: source).fileType, .png)
  }

  /// One format is the ordinary case and must stay ordinary.
  func test_oneFormatStillWritesOneFile() async throws {
    let source = try Fixture.image(at: path("single.png"), width: 200, height: 200)
    let destination = try folder("out")

    var preset = RulePreset(name: "One", description: "", category: .image)
    preset.actions = [.convertFormat(to: .jpeg)]

    _ = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination,
      progress: { _ in }
    )

    XCTAssertEqual(contents(of: destination), ["single.jpeg"])
  }
}

/// A size written into a file's own name is an instruction.
final class SizeInNameTests: BaseTestCase {

  func test_theNameIsRead() {
    XCTAssertEqual(SizeInName.ceiling(in: "holiday_10MB.jpg"), 10_000_000)
    XCTAssertEqual(SizeInName.ceiling(in: "holiday_2024_5MB.jpg"), 5_000_000)
    XCTAssertEqual(SizeInName.ceiling(in: "scan_500kb.png"), 500_000)
    XCTAssertEqual(SizeInName.ceiling(in: "clip_1.5MB.mp4"), 1_500_000)
    XCTAssertEqual(SizeInName.ceiling(in: "clip_1,5mb.mp4"), 1_500_000)
  }

  /// A name that is not asking for anything must not be read as if it were.
  func test_anOrdinaryNameAsksForNothing() {
    XCTAssertNil(SizeInName.ceiling(in: "holiday.jpg"))
    XCTAssertNil(SizeInName.ceiling(in: "10MB.jpg"), "the size is the subject here, not an instruction")
    XCTAssertNil(SizeInName.ceiling(in: "report_final.pdf"))
    XCTAssertNil(SizeInName.ceiling(in: "photo_0MB.jpg"))
  }

  /// The name is the more specific answer, so it replaces a preset's ceiling.
  func test_theNameBeatsThePreset() {
    let chain = SizeInName.applying(
      to: [.convertFormat(to: .jpeg), .limitSize(bytes: 99_000_000)],
      from: "holiday_2MB.jpg"
    )
    let ceilings = chain.compactMap { if case .limitSize(let bytes) = $0 { return bytes } else { return nil } }
    XCTAssertEqual(ceilings, [2_000_000])
  }

  /// The whole point: rename the file, convert it, and it fits.
  func test_renamingTheFileIsEnoughToCompressIt() async throws {
    let source = try Fixture.image(at: path("holiday_15kb.png"), width: 1600, height: 1200)
    let destination = try folder("out")
    XCTAssertGreaterThan(size(of: source), 15_000, "the source has to start too big for this to prove anything")

    var preset = RulePreset(name: "Just JPEG", description: "", category: .image)
    preset.actions = [.convertFormat(to: .jpeg)]

    let history = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: preset,
      destinationMode: .copyTo,
      destinationURL: destination,
      progress: { _ in }
    )

    let output = try XCTUnwrap(history.outputURL)
    XCTAssertLessThanOrEqual(size(of: output), 15_000)
    XCTAssertGreaterThan(size(of: output), 0)
  }
}
