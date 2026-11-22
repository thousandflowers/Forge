import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// What running every data conversion on awkward files turned up: each of
/// these wrote the wrong thing, or nothing, and reported success.
final class DataEdgeTests: BaseTestCase {

  private func convert(_ source: URL, to format: UTType) async throws -> URL {
    let destination = try folder("out-\(UUID().uuidString.prefix(6))")
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: format, category: .custom),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    return try XCTUnwrap(entry.outputURL)
  }

  private func write(_ text: String, to name: String) throws -> URL {
    let url = path(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  // MARK: - Line endings

  /// "\r\n" is one Character in Swift, equal to neither "\n" nor "\r", so a
  /// file saved on Windows - or by Python's csv module, which writes CRLF by
  /// default - was read as a single record and came out as `[]`.
  func test_csvWithWindowsLineEndingsKeepsItsRows() async throws {
    let source = try write("name,city\r\nAda,London\r\nGrace,New York\r\n", to: "crlf.csv")

    let output = try await convert(source, to: .json)
    let rows = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: output)) as? [[String: String]]
    )
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.first?["city"], "London", "no stray return left on the last field")
    XCTAssertEqual(rows.last?["name"], "Grace")
  }

  func test_csvWithOldMacLineEndingsKeepsItsRows() throws {
    let rows = try Separated.rows(from: "a,b\r1,2\r3,4\r", separator: ",")
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.last?["b"], "4")
  }

  // MARK: - Columns

  /// The columns went through a dictionary and came back alphabetical, so
  /// `id,name,amount` was rewritten as `amount,id,name`.
  func test_aTableKeepsItsColumnsInTheOrderItHadThem() async throws {
    let source = try write("id,name,amount\n1,Ada,30\n2,Grace,45\n", to: "ledger.csv")
    let tsv = try XCTUnwrap(DataProcessor.tsv)

    let output = try await convert(source, to: tsv)
    let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.first, "id\tname\tamount")
    XCTAssertEqual(lines.last, "2\tGrace\t45")
  }

  /// A cell holding a list or a record was written as Objective-C's debug
  /// description of it, and a boolean as 1 or 0.
  func test_aCellSaysWhatItHoldsInAFormAnythingCanRead() async throws {
    let source = try write(#"[{"name":"Ada","admin":true,"tags":["a","b"]}]"#, to: "people.json")
    let csv = try XCTUnwrap(DataProcessor.csv)

    let output = try await convert(source, to: csv)
    let rows = try Separated.rows(from: try String(contentsOf: output, encoding: .utf8), separator: ",")
    XCTAssertEqual(rows.first?["admin"], "true")
    XCTAssertEqual(rows.first?["tags"], #"["a","b"]"#)
  }

  // MARK: - Values one format has and another does not

  /// A property list holds dates and raw bytes; JSON holds neither. Foundation
  /// answers that with an Objective-C exception, which Swift cannot catch, so
  /// the whole app went down - measured on the released build: `Abort trap: 6`.
  func test_aPropertyListWithADateAndBytesBecomesJSON() async throws {
    let source = path("stamp.plist")
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["when": when, "blob": Data([0, 1, 2]), "name": "Forge"],
      format: .xml,
      options: 0
    )
    try data.write(to: source)

    let output = try await convert(source, to: .json)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: output)) as? [String: Any]
    )
    XCTAssertEqual(json["name"] as? String, "Forge")
    XCTAssertEqual(json["when"] as? String, "2023-11-14T22:13:20Z")
    XCTAssertEqual(json["blob"] as? String, "AAEC", "bytes travel as base64")
  }

  /// A property list has no way to say "nothing here", and the refusal used to
  /// be Foundation's: "an error in the destination for the data".
  func test_aNullThatCannotBecomeAPropertyListIsRefusedInWords() async throws {
    let source = try write(#"{"name":"Forge","note":null}"#, to: "null.json")

    do {
      _ = try await convert(source, to: .propertyList)
      XCTFail("a property list cannot hold a null")
    } catch {
      XCTAssertTrue(error.localizedDescription.lowercased().contains("null"), error.localizedDescription)
    }
  }

  /// Zero and one are numbers. They were written as `false` and `true`,
  /// because any NSNumber holding 0 or 1 will pass itself off as a Bool.
  func test_tomlKeepsZeroAndOneAsNumbers() async throws {
    let source = try write(#"{"zero":0,"one":1,"on":true,"list":[0,1,2]}"#, to: "ints.json")
    // The TOML type is declared by the system, and only by recent ones.
    guard let toml = DataProcessor.toml else { throw XCTSkip("this macOS has no TOML type") }

    let output = try await convert(source, to: toml)
    let text = try String(contentsOf: output, encoding: .utf8)
    XCTAssertTrue(text.contains("zero = 0"), text)
    XCTAssertTrue(text.contains("one = 1"), text)
    XCTAssertTrue(text.contains("on = true"), text)
    XCTAssertTrue(text.contains("list = [0, 1, 2]"), text)
  }
}
