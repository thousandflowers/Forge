import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// What a converted file ends up called.
///
/// The interesting half is the timing: a name asking how wide the picture came
/// out cannot be answered until the picture has been written, and answering it
/// early would put an empty space where the number belongs.
final class NameTemplateTests: BaseTestCase {

  private static let context = NameTemplate.Static(
    name: "holiday",
    parent: "Photos",
    date: Date(timeIntervalSince1970: 1_757_030_400),
    counter: 7,
    ext: "jpeg",
    quality: 80,
    codec: "h264",
    parameters: ["maxsize": "10MB"]
  )

  private static let dynamic = NameTemplate.Dynamic(
    width: 1920, height: 1080, bytes: 2_400_000, quality: 72
  )

  private func resolve(_ template: String, dynamic: NameTemplate.Dynamic? = nil) -> String {
    NameTemplate.resolve(template, with: Self.context, and: dynamic)
  }

  // MARK: - One token at a time

  func test_theStaticTokens() {
    XCTAssertEqual(resolve("{name}"), "holiday")
    XCTAssertEqual(resolve("{parent}"), "Photos")
    XCTAssertEqual(resolve("{counter}"), "7")
    XCTAssertEqual(resolve("{format}"), "jpeg")
    XCTAssertEqual(resolve("{ext}"), "jpeg")
    XCTAssertEqual(resolve("{codec}"), "h264")
  }

  func test_counter_padsToTheWidthItIsGiven() {
    XCTAssertEqual(resolve("{counter:03}"), "007")
    XCTAssertEqual(resolve("{counter:2}"), "07")
    XCTAssertEqual(resolve("{counter:}"), "7", "an argument that says nothing is not a width")
  }

  func test_date_takesThePatternItIsGiven() {
    let day = resolve("{date}")
    XCTAssertEqual(day.count, 10, "a sensible shape when nobody says: \(day)")
    XCTAssertEqual(resolve("{date:yyyy}"), String(day.prefix(4)))
    XCTAssertEqual(resolve("{date:yyyyMMdd}"), day.replacingOccurrences(of: "-", with: ""))
  }

  /// The preset's own questions are tokens too, which is what already turned
  /// `holiday.png` into `holiday_10MB.jpg`.
  func test_aPresetsOwnQuestionIsAToken() {
    XCTAssertEqual(resolve("{name}_{maxsize}"), "holiday_10MB")
  }

  // MARK: - The two passes

  /// The whole reason for two passes.
  func test_dynamicTokens_areLeftAloneUntilTheFileExists() {
    XCTAssertEqual(
      resolve("{name}_{width}x{height}"), "holiday_{width}x{height}",
      "nothing knows how wide it came out yet, and guessing would be worse than waiting"
    )
    XCTAssertTrue(NameTemplate.needsSecondPass(resolve("{name}_{dimensions}")))
    XCTAssertFalse(NameTemplate.needsSecondPass(resolve("{name}_{counter:03}")))
  }

  func test_dynamicTokens_answerOnceThereIsAFile() {
    XCTAssertEqual(resolve("{name}_{width}x{height}", dynamic: Self.dynamic), "holiday_1920x1080")
    XCTAssertEqual(resolve("{dimensions}", dynamic: Self.dynamic), "1920x1080")
    XCTAssertFalse(resolve("{size}", dynamic: Self.dynamic).contains(" "), "a name with a space in the number is a mess")
    XCTAssertTrue(resolve("{size}", dynamic: Self.dynamic).uppercased().contains("MB"))
  }

  /// A ceiling settles the quality, so the file's own number beats the one the
  /// encoder was told.
  func test_quality_prefersWhatTheFileActuallyCost() {
    XCTAssertEqual(resolve("q{quality}"), "q80")
    XCTAssertEqual(resolve("q{quality}", dynamic: Self.dynamic), "q72")
  }

  /// Running the second pass over the first pass's output is what the
  /// coordinator does, so it has to give the same answer as doing it all at
  /// once.
  func test_twoPasses_giveTheSameNameAsOne() {
    let first = resolve("{name}_{counter:03}_{dimensions}")
    XCTAssertEqual(first, "holiday_007_{dimensions}")

    let second = NameTemplate.resolve(first, with: Self.context, and: Self.dynamic)
    XCTAssertEqual(second, "holiday_007_1920x1080")
    XCTAssertEqual(second, resolve("{name}_{counter:03}_{dimensions}", dynamic: Self.dynamic))
  }

  // MARK: - What is not a token

  /// A typo somebody can see is better than a name that quietly lost a piece.
  func test_unknownTokens_areLeftWhereTheyAre() {
    XCTAssertEqual(resolve("{name}_{nmae}"), "holiday_{nmae}")
    XCTAssertEqual(resolve("{ }"), "{ }")
    XCTAssertEqual(resolve("holiday {unclosed"), "holiday {unclosed")
  }

  /// A token that was understood and had nothing to say leaves nothing behind,
  /// which is the old behaviour and the right one: `holiday.jpg` beats
  /// `holiday_{codec}.jpg` for a picture that has no codec.
  func test_knownTokensWithNoAnswer_leaveNothing() {
    var context = Self.context
    context.codec = nil
    context.quality = nil
    XCTAssertEqual(NameTemplate.resolve("{name}_{codec}", with: context), "holiday")
    XCTAssertEqual(NameTemplate.resolve("{name}-{quality}", with: context), "holiday")
  }

  func test_combinedTemplate() {
    XCTAssertEqual(
      resolve("{name}_{maxsize}_{counter:03}", dynamic: Self.dynamic),
      "holiday_10MB_007"
    )
  }

  // MARK: - Through a real conversion

  /// The names a batch actually comes out with.
  func test_aBatch_isNumberedInOrder() async throws {
    let photos = try folder("Photos")
    let sources = try (1...3).map { index in
      try Fixture.image(at: photos.appendingPathComponent("shot-\(index).png"))
    }
    let destination = try folder("out")

    var settings = AppSettings()
    settings.nameTemplate = "{parent}_{counter:03}"

    let report = await Batch.run(
      try sources.map { try ProcessableFile(url: $0) },
      preset: .make(format: .jpeg, category: .image),
      mode: .copyTo,
      destination: destination,
      limit: 1,
      coordinator: coordinator(settings: settings)
    ) { _ in }

    XCTAssertEqual(report.converted, 3)
    let written = try FileManager.default
      .contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
      .map(\.lastPathComponent)
      .sorted()
    XCTAssertEqual(written, ["Photos_001.jpeg", "Photos_002.jpeg", "Photos_003.jpeg"])
  }

  /// The dynamic half, measured rather than promised: the file is named after
  /// what it turned out to be.
  func test_aResizedFile_isNamedAfterWhatItBecame() async throws {
    let source = try Fixture.image(at: path("holiday.png"), width: 800, height: 600)
    let destination = try folder("out")

    var settings = AppSettings()
    settings.nameTemplate = "{name}_{dimensions}"

    let entry = try await coordinator(settings: settings).processFile(
      try ProcessableFile(url: source),
      with: .make(
        format: .jpeg,
        resize: ResizeSpec(width: 400, height: nil, fitMode: .proportional),
        category: .image
      ),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(output.lastPathComponent, "holiday_400x300.jpeg")
    XCTAssertTrue(exists(output), "the file is where its name says it is")
  }
}
