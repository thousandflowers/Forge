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
