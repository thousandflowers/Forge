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

  /// YAML still has no parser to call, so nothing may claim it. Its
  /// specification is large enough that a subset would quietly misread files
  /// that look ordinary, which is the opposite of what a converter is for.
  func test_yamlIsNotClaimed() throws {
    for ext in ["yaml", "yml"] {
      guard let type = UTType(filenameExtension: ext), !type.isDynamic else { continue }
      XCTAssertFalse(
        DataProcessor.readable.contains { type.conforms(to: $0) },
        "\(ext) has no parser in Foundation"
      )
    }
  }

  // MARK: - TOML

  private static let toml = """
    # un commento
    titolo = "Forge"          # anche qui
    versione = 2
    attivo = true
    soglia = 0.8
    formati = ["png", "jpeg", "webp"]

    [autore]
    nome = "Eugenio"

    [server.limiti]
    massimo = 10_000

    [[preset]]
    nome = "Web JPEG"
    qualita = 80

    [[preset]]
    nome = "Archivio PNG"
    qualita = 100
    """

  /// Nothing on this machine reads TOML, so this is Forge's own parser and it
  /// is checked against a file with every shape it claims to know in it.
  func test_toml_isReadIntoItsParts() throws {
    let table = try Toml.object(from: Self.toml)

    XCTAssertEqual(table["titolo"] as? String, "Forge")
    XCTAssertEqual(table["versione"] as? Int, 2)
    XCTAssertEqual(table["attivo"] as? Bool, true)
    XCTAssertEqual(table["soglia"] as? Double, 0.8)
    XCTAssertEqual(table["formati"] as? [String], ["png", "jpeg", "webp"])

    let author = try XCTUnwrap(table["autore"] as? [String: Any])
    XCTAssertEqual(author["nome"] as? String, "Eugenio")

    // A dotted header makes the tables it names, not a key with a dot in it.
    let server = try XCTUnwrap(table["server"] as? [String: Any])
    let limits = try XCTUnwrap(server["limiti"] as? [String: Any])
    XCTAssertEqual(limits["massimo"] as? Int, 10_000, "the underscore in 10_000 was not dropped")

    let presets = try XCTUnwrap(table["preset"] as? [[String: Any]])
    XCTAssertEqual(presets.count, 2)
    XCTAssertEqual(presets.first?["nome"] as? String, "Web JPEG")
    XCTAssertEqual(presets.last?["qualita"] as? Int, 100)
  }

  /// The point of converting a file is that it still says the same thing
  /// afterwards.
  func test_toml_saysTheSameThingAfterARoundTrip() throws {
    let first = try Toml.object(from: Self.toml)
    let written = try Toml.text(from: first)
    let second = try Toml.object(from: written)

    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: first, options: [.sortedKeys]),
      try JSONSerialization.data(withJSONObject: second, options: [.sortedKeys]),
      "the file changed on the way through:\n\(written)"
    )
  }

  /// A `#` inside a string is part of the string. Treating it as a comment
  /// would quietly truncate somebody's value.
  func test_toml_aHashInsideAStringIsNotAComment() throws {
    let table = try Toml.object(from: "colore = \"#3178c6\" # il blu")
    XCTAssertEqual(table["colore"] as? String, "#3178c6")
  }

  func test_toml_readsInlineTablesAndNestedLists() throws {
    let table = try Toml.object(from: "punto = { x = 1, y = 2 }\nmatrice = [[1, 2], [3, 4]]")
    let point = try XCTUnwrap(table["punto"] as? [String: Any])
    XCTAssertEqual(point["x"] as? Int, 1)
    XCTAssertEqual(point["y"] as? Int, 2)
    XCTAssertEqual(try XCTUnwrap(table["matrice"] as? [[Int]]), [[1, 2], [3, 4]])
  }

  /// What this parser does not do, it refuses. A date read as a string, or a
  /// multi-line string read as three empty ones, is a file quietly changed.
  func test_toml_refusesWhatItDoesNotRead() {
    XCTAssertThrowsError(try Toml.object(from: "quando = 1979-05-27T07:32:00Z")) { error in
      XCTAssertTrue(error.localizedDescription.contains("date"), error.localizedDescription)
      XCTAssertTrue(error.localizedDescription.contains("Line 1"), error.localizedDescription)
    }
    XCTAssertThrowsError(try Toml.object(from: "testo = \"\"\"due\nrighe\"\"\""))
  }

  /// TOML has no null, and writing one as an empty key would put a value in a
  /// file that nobody put there.
  func test_toml_refusesToWriteANull() {
    XCTAssertThrowsError(try Toml.text(from: ["chiave": NSNull()]))
  }

  /// A format is named the same way wherever it is said to a person: in the
  /// menu, in an error, in `forge presets`, in `forge formats`. It used to be
  /// named by whatever extension the system preferred, so TOML was CFG in
  /// some places and TOML in others.
  func test_anErrorCallsAFormatWhatPeopleCallIt() throws {
    guard let toml = UTType("public.toml") else { throw XCTSkip("no TOML type on this macOS") }
    let said = ProcessingError.unsupportedConversion(from: .png, to: toml).localizedDescription
    XCTAssertTrue(said.contains("TOML"), said)
    XCTAssertFalse(said.contains("CFG"), said)
  }

  /// `public.toml` prefers the extension `cfg`, which nobody calls a TOML
  /// file, and `public.yaml` prefers `yml`. A type named after one of the
  /// extensions it declares uses that one instead.
  func test_theExtensionIsTheOneTheTypeIsNamedAfter() throws {
    // Those two types are not on every macOS - `public.toml` is missing on 14 -
    // so they are checked where they exist and skipped where they do not.
    if let toml = UTType("public.toml") {
      XCTAssertEqual(FormatCatalog.fileExtension(for: toml), "toml")
    }
    if let yaml = UTType("public.yaml") {
      XCTAssertEqual(FormatCatalog.fileExtension(for: yaml), "yaml")
    }
    // Everything else keeps the system's own answer.
    XCTAssertEqual(FormatCatalog.fileExtension(for: .jpeg), "jpeg")
    XCTAssertEqual(
      FormatCatalog.fileExtension(for: try XCTUnwrap(UTType("com.apple.m4a-audio"))), "m4a"
    )
  }
}
