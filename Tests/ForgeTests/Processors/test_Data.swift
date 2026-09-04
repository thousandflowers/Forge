import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// CSV, JSON and Property List, all Foundation's.
final class DataConversionTests: BaseTestCase {

  private func convert(_ source: URL, to format: UTType) async throws -> URL {
    let destination = try folder("out-\(format.preferredFilenameExtension ?? "x")")
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: format, category: .custom),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    return try XCTUnwrap(entry.outputURL)
  }

  func test_csvBecomesJSON() async throws {
    let source = path("people.csv")
    try "name,city\nAda,London\nGrace,New York\n".write(to: source, atomically: true, encoding: .utf8)

    let output = try await convert(source, to: .json)
    let rows = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: output)) as? [[String: String]]
    )
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0]["name"], "Ada")
    XCTAssertEqual(rows[1]["city"], "New York")
  }

  func test_jsonBecomesCSV() async throws {
    let source = path("people.json")
    let json = """
    [{"name":"Ada","city":"London"},{"name":"Grace","city":"New York"}]
    """
    try json.write(to: source, atomically: true, encoding: .utf8)

    let csv = try XCTUnwrap(DataProcessor.csv)
    let text = try String(contentsOf: try await convert(source, to: csv), encoding: .utf8)
    XCTAssertTrue(text.hasPrefix("city,name"), text)
    XCTAssertTrue(text.contains("London,Ada"), text)
  }

  /// The awkward parts of the format: quotes, separators inside fields, and
  /// newlines inside fields.
  func test_csvSurvivesQuotesAndCommas() async throws {
    let source = path("tricky.csv")
    try "name,note\n\"Ada, Countess\",\"said \"\"hello\"\"\"\n"
      .write(to: source, atomically: true, encoding: .utf8)

    let output = try await convert(source, to: .json)
    let rows = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: output)) as? [[String: String]]
    )
    XCTAssertEqual(rows.first?["name"], "Ada, Countess")
    XCTAssertEqual(rows.first?["note"], "said \"hello\"")
  }

  func test_aRoundTripKeepsTheAwkwardFields() async throws {
    let source = path("tricky.csv")
    let original = "name,note\n\"Ada, Countess\",\"line one\nline two\"\n"
    try original.write(to: source, atomically: true, encoding: .utf8)

    let csv = try XCTUnwrap(DataProcessor.csv)
    let json = try await convert(source, to: .json)
    let back = try await convert(json, to: csv)

    let rows = try Separated.rows(from: try String(contentsOf: back, encoding: .utf8), separator: ",")
    XCTAssertEqual(rows.first?["name"], "Ada, Countess")
    XCTAssertEqual(rows.first?["note"], "line one\nline two")
  }

  func test_jsonBecomesPropertyList() async throws {
    let source = path("settings.json")
    try #"{"enabled":true,"count":3,"name":"Forge"}"#.write(to: source, atomically: true, encoding: .utf8)

    let output = try await convert(source, to: .propertyList)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: try Data(contentsOf: output), format: nil) as? [String: Any]
    )
    XCTAssertEqual(plist["name"] as? String, "Forge")
    XCTAssertEqual(plist["count"] as? Int, 3)
    XCTAssertEqual(plist["enabled"] as? Bool, true)
  }

  func test_propertyListBecomesJSON() async throws {
    let source = path("settings.plist")
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["name": "Forge", "count": 3],
      format: .xml,
      options: 0
    )
    try data.write(to: source)

    let output = try await convert(source, to: .json)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: output)) as? [String: Any]
    )
    XCTAssertEqual(json["name"] as? String, "Forge")
  }

  /// Not every JSON document is a table, and saying so beats writing nonsense.
  func test_jsonThatIsNotATableIsRefusedClearly() async throws {
    let source = path("nested.json")
    try #"{"a":{"b":[1,2,3]}}"#.write(to: source, atomically: true, encoding: .utf8)
    let csv = try XCTUnwrap(DataProcessor.csv)

    do {
      _ = try await convert(source, to: csv)
      XCTFail("a nested document is not a table")
    } catch {
      XCTAssertTrue(error.localizedDescription.lowercased().contains("table"), error.localizedDescription)
    }
  }

  /// YAML and TOML have no parser to call, so nothing may claim them.
  func test_yamlAndTomlAreNotClaimed() throws {
    for ext in ["yaml", "yml", "toml"] {
      guard let type = UTType(filenameExtension: ext), !type.isDynamic else { continue }
      XCTAssertFalse(
        DataProcessor.readable.contains { type.conforms(to: $0) },
        "\(ext) has no parser in Foundation"
      )
    }
  }
}
