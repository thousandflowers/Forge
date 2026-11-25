import AVFoundation
import CoreText
import ImageIO
import ModelIO
import PDFKit
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import Forge

/// The formats Forge reads and writes itself, through the same door as any
/// other file.
final class OwnFormatTests: BaseTestCase {

  private func convert(_ source: URL, to ext: String, file: StaticString = #filePath, line: UInt = #line) async throws -> URL {
    let entry = try await run(source, to: ext)
    XCTAssertEqual(entry.status, .completed, "\(source.lastPathComponent) to \(ext): \(entry.errorMessage ?? "")", file: file, line: line)
    let made = try XCTUnwrap(entry.outputURL, "\(source.lastPathComponent) to \(ext)", file: file, line: line)
    XCTAssertGreaterThan(size(of: made), 0, "\(source.lastPathComponent) to \(ext)", file: file, line: line)
    return made
  }

  private func run(_ source: URL, to ext: String) async throws -> ProcessingHistory {
    let type = try XCTUnwrap(FormatCatalog.type(named: ext), ext)
    let out = try folder("out-\(UUID().uuidString.prefix(6))")
    return try await coordinator().processFile(
      try ProcessableFile(url: source), with: .make(format: type, category: .custom), destinationMode: .copyTo, destinationURL: out
    ) { _ in }
  }

  private func write(_ text: String, _ name: String) throws -> URL {
    let url = path(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  private func json(_ url: URL) throws -> Any { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) }

  // MARK: - Data

  private let sales = "name,phone,total\nAnna & Co,0039041,12.5\n\"Bo, jr\",,-3\n"

  /// There and back through each of them is the table it was: a zero in front
  /// of a telephone number included.
  func test_aTableGoesThereAndBack() async throws {
    let source = try write(sales, "sales.csv")
    for ext in ["xlsx", "ods", "json", "jsonl", "yaml", "tsv"] {
      let there = try await convert(source, to: ext), back = try await convert(there, to: "csv")
      let rows = try Separated.rows(from: try text(back), separator: ",")
      XCTAssertEqual(rows.map { $0["name"] }, ["Anna & Co", "Bo, jr"], ext)
      XCTAssertEqual(rows.map { $0["phone"] ?? "" }, ["0039041", ""], ext)
      XCTAssertEqual(rows.map { $0["total"] }, ["12.5", "-3"], ext)
    }
  }

  func test_aTableBecomesSomethingToLookAt() async throws {
    let source = try write(sales, "sales.csv")
    let made1 = try await convert(source, to: "html")
    XCTAssertTrue(try text(made1).contains("<td>Anna &amp; Co</td>"))
    let made2 = try await convert(source, to: "md")
    XCTAssertTrue(try text(made2).contains("| name | phone | total |"))
    let made3 = try await convert(source, to: "sql")
    XCTAssertTrue(try text(made3).contains("'Bo, jr'"))
    let made4 = try await convert(source, to: "xml")
    XCTAssertTrue(try text(made4).contains("<name>Anna &amp; Co</name>"))
  }

  /// A workbook of two sheets is two CSVs, and one JSON with both.
  func test_aBookOfSheets() async throws {
    let book = path("book.xlsx")
    let first = Separated.Table(columns: ["a"], rows: [["a": "1"]]), second = Separated.Table(columns: ["b"], rows: [["b": "2"]])
    try DataFormats.data(DataFormats.Book(sheets: [("One", first), ("Two", second)]), as: "xlsx").write(to: book)
    let entry = try await run(book, to: "csv")
    let made = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(contents(of: made.deletingLastPathComponent()).count, 2)
    let asJSON = try await convert(book, to: "json")
    let both = try XCTUnwrap(try json(asJSON) as? [String: [[String: String]]])
    XCTAssertEqual(both["Two"]?.first?["b"], "2")
  }

  func test_datesInASheetAreDates() throws {
    let head = #"<?xml version="1.0"?>"#, rels = "http://schemas.openxmlformats.org/package/2006/relationships"
    let url = path("dates.xlsx")
    try Zip.data([
      Zip.Entry(name: "xl/workbook.xml", data: Data((head + #"<workbook xmlns:r="x"><sheets><sheet name="S" r:id="r1"/></sheets></workbook>"#).utf8)),
      Zip.Entry(name: "xl/_rels/workbook.xml.rels", data: Data((head + #"<Relationships xmlns="\#(rels)"><Relationship Id="r1" Target="worksheets/a.xml"/></Relationships>"#).utf8)),
      Zip.Entry(name: "xl/styles.xml", data: Data((head + #"<styleSheet><numFmts><numFmt numFmtId="170" formatCode="dd/mm/yyyy hh:mm"/></numFmts><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="170"/></cellXfs></styleSheet>"#).utf8)),
      Zip.Entry(name: "xl/sharedStrings.xml", data: Data((head + "<sst><si><r><t>wh</t></r><r><t>en</t></r></si></sst>").utf8)),
      Zip.Entry(name: "xl/worksheets/a.xml", data: Data((head + #"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row><row r="2"><c r="A2" s="1"><v>45000</v></c></row><row r="3"><c r="A3" s="2"><v>45000.5</v></c></row><row r="4"><c r="C4"><v>0.10000000000000001</v></c></row></sheetData></worksheet>"#).utf8)),
    ]).write(to: url)
    let table = try XCTUnwrap(DataFormats.read(url) as? Separated.Table)
    XCTAssertEqual(table.rows.map { $0["when"] ?? "" }, ["2023-03-15", "2023-03-15 12:00:00", ""])
    XCTAssertEqual(table.rows[2]["column 3"], "0.1")
  }

  func test_aDatabaseIsItsTables() async throws {
    let url = path("base.sqlite")
    var base: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &base), SQLITE_OK)
    sqlite3_exec(base, "CREATE TABLE people (name TEXT, age INT); INSERT INTO people VALUES ('Anna', 31), ('Bo', NULL);", nil, nil, nil)
    sqlite3_close(base)
    let rows = try Separated.rows(from: try text(try await convert(url, to: "csv")), separator: ",")
    XCTAssertEqual(rows.map { $0["age"] }, ["31", ""])
    XCTAssertEqual(contents(of: workspace).filter { $0.hasPrefix("base") }, ["base.sqlite"], "nothing left beside it")
  }

  func test_yamlIsReadForWhatItMeans() throws {
    let value = try Yaml.read("""
      # settings
      name: "Forge # not a comment"
      url: http://example.com:80/a   # comment
      port: 8080
      ratio: 1.5
      zip: 0123
      on: true
      none: ~
      list:
      - one
      - two: 2
        three: [3, 'it''s', {four: 4}]
      -
        - nested
      text: |
        first
          second

        third
      folded: >-
        a
        b
      empty: {}
      long: one
        two
      """) as? [String: Any]
    let all = try XCTUnwrap(value)
    XCTAssertEqual(all["name"] as? String, "Forge # not a comment")
    XCTAssertEqual(all["url"] as? String, "http://example.com:80/a")
    XCTAssertEqual(all["port"] as? Int, 8080)
    XCTAssertEqual(all["ratio"] as? Double, 1.5)
    XCTAssertEqual(all["zip"] as? String, "0123", "a zero in front is part of it")
    XCTAssertEqual(all["on"] as? Bool, true)
    XCTAssertTrue(all["none"] is NSNull)
    let list = try XCTUnwrap(all["list"] as? [Any])
    XCTAssertEqual(list[0] as? String, "one")
    let second = try XCTUnwrap(list[1] as? [String: Any])
    XCTAssertEqual(second["two"] as? Int, 2)
    let three = try XCTUnwrap(second["three"] as? [Any])
    XCTAssertEqual(three[1] as? String, "it's")
    XCTAssertEqual((three[2] as? [String: Any])?["four"] as? Int, 4)
    XCTAssertEqual(list[2] as? [String], ["nested"])
    XCTAssertEqual(all["text"] as? String, "first\n  second\n\nthird\n")
    XCTAssertEqual(all["folded"] as? String, "a b")
    XCTAssertEqual((all["empty"] as? [String: Any])?.count, 0)
    XCTAssertEqual(all["long"] as? String, "one two")
  }

  /// What it does not read it says, with the line.
  func test_cleverYamlIsRefused() {
    for text in ["a: &x 1\nb: *x", "a: !!binary x", "a: 1\n---\nb: 2", "a: 1\na: 2", "a: [1, 2", "a: 1\n   b: 2", "a: \"x"] {
      XCTAssertThrowsError(try Yaml.read(text), text) { XCTAssertTrue($0.localizedDescription.hasPrefix("Line "), $0.localizedDescription) }
    }
  }

  func test_yamlIsWrittenSoThatItIsReadBack() throws {
    let value: [String: Any] = [
      "words": "plain", "colon": "a: b", "number": "12", "yes": "true", "dash": "- x", "lines": "a\nb", "empty": "", "space": " x", "hash": "a #b",
      "int": 3, "list": [1, ["a": [String](), "b": NSNull()] as [String: Any], [2, 3]] as [Any], "bool": false, "date": "2026-11-24", "quote": "\"q\"", "tilde": "~", "emoji": "è 🎈",
    ]
    let back = try XCTUnwrap(Yaml.read(try Yaml.write(value)) as? [String: Any])
    XCTAssertEqual(back as NSDictionary, value as NSDictionary)
  }

  func test_settingsFiles() async throws {
    let source = try write("; note\nloose = 1\n[window]\nwidth = 800\ntitle = \"My app\"\n", "a.ini")
    let asJSON = try await convert(source, to: "json")
    let all = try XCTUnwrap(try json(asJSON) as? [String: Any])
    XCTAssertEqual((all["window"] as? [String: String])?["title"], "My app")
    let made5 = try await convert(source, to: "yaml")
    XCTAssertTrue(try text(made5).contains("window:\n  title: My app\n"))
    let strings = try write("\"hello\" = \"ci\\\"ao\";\n", "a.strings")
    let made6 = try await convert(strings, to: "json")
    XCTAssertEqual((try json(made6) as? [String: String])?["hello"], "ci\"ao")
  }

  func test_xmlGoesThereAndBack() async throws {
    let source = try write("<?xml version=\"1.0\"?><shop open=\"yes\"><item id=\"1\">Tea</item><item>Cup</item></shop>", "a.xml")
    let made = try await convert(source, to: "json")
    let shop = try XCTUnwrap((try json(made) as? [String: Any])?["shop"] as? [String: Any])
    XCTAssertEqual(shop["@open"] as? String, "yes")
    XCTAssertEqual((shop["item"] as? [Any])?.count, 2)
    let back = try text(try await convert(made, to: "xml"))
    XCTAssertTrue(back.contains("<item id=\"1\">Tea</item>"), back)
  }

  func test_placesAndTracks() async throws {
    let gpx = try write("""
      <?xml version="1.0"?><gpx xmlns="http://www.topografix.com/GPX/1/1"><wpt lat="45.4" lon="12.3"><name>Home &amp; away</name></wpt>
      <trk><name>Walk</name><trkseg><trkpt lat="45.1" lon="12.1"><ele>3</ele><time>2026-01-01T00:00:00Z</time></trkpt><trkpt lat="45.2" lon="12.2"><ele>4.5</ele></trkpt></trkseg></trk></gpx>
      """, "walk.gpx")
    for ext in ["geojson", "kml", "kmz"] {
      let there = try await convert(gpx, to: ext), back = try text(try await convert(there, to: "gpx"))
      XCTAssertTrue(back.contains("Home &amp; away") && back.contains(#"<trkpt lat="45.2" lon="12.2"><ele>4.5</ele>"#), "\(ext): \(back)")
    }
    let table = try text(try await convert(gpx, to: "csv"))
    XCTAssertTrue(table.hasPrefix("name,latitude,longitude,elevation,time\n"), table)
    let places = try write("Name,Lat,Lon\nBar,45.43,12.33\n", "places.csv")
    let made7 = try await convert(places, to: "kml")
    XCTAssertTrue(try text(made7).contains("<coordinates>12.33,45.43</coordinates>"))
    let noPlaces = try write(sales, "s.csv")
    do { _ = try await run(noPlaces, to: "kml"); XCTFail("there are none") } catch { XCTAssertTrue(error.localizedDescription.contains("latitude")) }
  }

  func test_contactsAndDiaries() async throws {
    let card = try write("BEGIN:VCARD\r\nVERSION:3.0\r\nN:Rossi;Anna;;;\r\nFN:Anna Rossi\r\nitem1.TEL;TYPE=CELL:+39 04\r\n 1234\r\nTEL:2\r\nNOTE:one\\, two\\nthree\r\nEND:VCARD\r\n", "anna.vcf")
    let rows = try Separated.rows(from: try text(try await convert(card, to: "csv")), separator: ",")
    XCTAssertEqual(rows.first?["phone"], "+39 041234")
    XCTAssertEqual(rows.first?["phone 2"], "2")
    XCTAssertEqual(rows.first?["note"], "one, two\nthree")
    let back = try text(try await convert(try await convert(card, to: "csv"), to: "vcf"))
    XCTAssertTrue(back.contains("FN:Anna Rossi\r\n") && back.contains("TEL:2\r\n") && back.contains("NOTE:one\\, two\\nthree"), back)

    let diary = try write("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Lunch\nDTSTART:20261124T120000Z\nBEGIN:VALARM\nDESCRIPTION:no\nEND:VALARM\nEND:VEVENT\nEND:VCALENDAR\n", "d.ics")
    let events = try Separated.rows(from: try text(try await convert(diary, to: "csv")), separator: ",")
    XCTAssertEqual(events.first?["summary"], "Lunch")
    XCTAssertNil(events.first?["description"], "an alarm's words are not the event's")
    let made = try text(try await convert(try write("summary,start\nTrip,2026-12-01\n", "e.csv"), to: "ics"))
    XCTAssertTrue(made.contains("DTSTART;VALUE=DATE:20261201\r\n"), made)
  }

  // MARK: - Fonts

  private let face = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia.ttf")

  /// Into every box and out again, the outlines are what they were.
  func test_aFontGoesThereAndBack() async throws {
    let source = path("Georgia.ttf")
    try FileManager.default.copyItem(at: face, to: source)
    let outlines = try XCTUnwrap(FontProcessor.faces(of: source).first?["glyf"])
    var weights: [String: Int64] = [:]
    for ext in ["woff", "woff2"] {
      let there = try await convert(source, to: ext)
      weights[ext] = size(of: there)
      let provider = try XCTUnwrap(CGDataProvider(url: there as CFURL))
      XCTAssertEqual(CGFont(provider)?.postScriptName as String?, "Georgia", ext)
      let back = try await convert(there, to: "ttf")
      XCTAssertEqual(try FontProcessor.faces(of: back).first?["glyf"], outlines, ext)
      XCTAssertNotNil(CTFontManagerCreateFontDescriptorsFromURL(back as CFURL))
    }
    XCTAssertLessThan(weights["woff"]!, size(of: source))
    XCTAssertLessThan(weights["woff2"]!, weights["woff"]!)
  }

  func test_aCollectionIsItsFonts() async throws {
    let source = path("Menlo.ttc")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc"), to: source)
    let made = try await convert(source, to: "ttf")
    XCTAssertEqual(contents(of: made.deletingLastPathComponent()).count, 4)
  }

  func test_aFontIsNotDrawnAgain() throws {
    let file = path("a.ttf")
    try FileManager.default.copyItem(at: face, to: file)
    XCTAssertFalse(Conversions.can(try ProcessableFile(url: file), become: try XCTUnwrap(FormatCatalog.type(named: "otf"))))
  }

  // MARK: - Shapes

  private func tetrahedron() throws -> URL {
    try write("o tetra\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4\n", "tetra.obj")
  }

  func test_aShapeGoesThereAndBack() async throws {
    let source = try tetrahedron()
    for ext in ["glb", "gltf", "3mf", "off", "dae", "scn", "usdz"] {
      let there = try await convert(source, to: ext)
      let back = try Meshes.of(MDLAsset(url: try await convert(there, to: "stl")))
      XCTAssertEqual(back.reduce(0) { $0 + $1.triangles.count }, 12, "\(ext): four sides of three corners")
      let points = back.flatMap(\.points)
      for axis in 0..<3 {
        XCTAssertEqual(points.map { $0[axis] }.min() ?? 9, 0, accuracy: 0.001, ext)
        XCTAssertEqual(points.map { $0[axis] }.max() ?? 9, 1, accuracy: 0.001, ext)
      }
    }
  }

  func test_aShapeBecomesAPicture() async throws {
    let made = try await convert(try tetrahedron(), to: "png")
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(made as CFURL, nil)), image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(image.width, 1600)
    XCTAssertGreaterThan(darkShare(of: image), 0.05, "there is something on it")
  }

  private func darkShare(of image: CGImage) -> Double {
    let side = 200
    var pixels = [UInt8](repeating: 255, count: side * side)
    let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return Double(pixels.filter { $0 < 250 }.count) / Double(side * side)
  }

  // MARK: - Pictures

  /// A ring traced is a ring: filled where it was dark, and its hole a hole.
  func test_aPictureIsTraced() async throws {
    let side = 300
    let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.setStrokeColor(.black)
    context.setLineWidth(40)
    context.strokeEllipse(in: CGRect(x: 60, y: 60, width: 180, height: 180))
    let image = try XCTUnwrap(context.makeImage()), source = path("ring.png")
    let sink = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(sink, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(sink))

    let traced = try await convert(source, to: "svg")
    XCTAssertEqual(try text(traced).components(separatedBy: "M").count, 3, "two outlines")
    let drawn = try await convert(traced, to: "png")
    let made = try XCTUnwrap(CGImageSourceCreateWithURL(drawn as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    XCTAssertEqual(darkShare(of: made), darkShare(of: image), accuracy: 0.02)
  }

  // MARK: - Documents

  /// Without pandoc, which is asked first where it is installed.
  @MainActor
  func test_aBookGoesThereAndBack() async throws {
    let words = NSMutableAttributedString(string: "A title\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
    words.append(NSAttributedString(string: "Some words & more < less.\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
    let book = path("story.epub")
    try DocumentText.write(words, to: book, as: try XCTUnwrap(Book.type), details: [.author: "Anna & Co"])
    let zip = try Zip.Reader(book)
    XCTAssertEqual(zip.names.first, "mimetype")
    for name in zip.names where name != "mimetype" { XCTAssertNoThrow(try XMLDocument(data: try zip.data(name)), name) }
    XCTAssertTrue(try zip.text("book.opf").contains("<dc:title>A title</dc:title><dc:creator>Anna &amp; Co</dc:creator>"))
    let back = try DocumentText.read(book, as: try XCTUnwrap(Book.type))
    XCTAssertTrue(back.string.contains("A title\n") && back.string.contains("Some words & more < less."), back.string)
    XCTAssertEqual(Book.details(of: book)[.author] as? String, "Anna & Co")
    for ext in ["txt", "html", "rtf", "docx", "pdf", "odt", "doc"] { _ = try await convert(book, to: ext) }
  }

  /// Words are words: pandoc, left to itself, calls Markdown a text file.
  func test_aBookAsTextHasNoMarksInIt() async throws {
    let source = try write("# A title\n\nSome *words* & more.\n", "story.md")
    let book = try await convert(source, to: "epub"), made = try await convert(book, to: "txt")
    let words = try text(made)
    XCTAssertTrue(words.contains("A title") && words.contains("words"), words)
    XCTAssertFalse(words.contains("---") || words.contains(":::"), words)
  }

  func test_oldWordAndOpenDocument() async throws {
    let source = try write("Perché no?\n", "a.txt")
    for ext in ["doc", "odt"] {
      let there = try await convert(source, to: ext)
      let made8 = try await convert(there, to: "txt")
      XCTAssertTrue(try text(made8).contains("Perché no?"), ext)
    }
  }

  func test_aComicIsItsPages() async throws {
    let pdf = path("two.pdf")
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
    for _ in 0..<2 { context.beginPDFPage(nil); context.fill(CGRect(x: 20, y: 20, width: 50, height: 50)); context.endPDFPage() }
    context.closePDF()
    let comic = try await convert(pdf, to: "cbz")
    XCTAssertEqual(try Zip.Reader(comic).names, ["0001.jpg", "0002.jpg"])
    let made9 = try await convert(comic, to: "pdf")
    XCTAssertEqual(PDFDocument(url: made9)?.pageCount, 2)
  }

  // MARK: - Sound and subtitles

  func test_moreSoundsAreWritten() async throws {
    let source = try await Fixture.audio(at: path("tone.wav"), seconds: 1)
    for ext in ["aifc", "au", "w64", "aac"] {
      let made = try await convert(source, to: ext)
      let file = try AVAudioFile(forReading: made)
      XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 1, accuracy: 0.1, ext)
    }
  }

  func test_sheetMusicIsPlayed() async throws {
    // One note, for a second at 120 to the minute.
    let bytes: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96, 0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 13, 0, 0x90, 60, 100, 0x81, 0x40, 0x80, 60, 0, 0, 0xFF, 0x2F, 0]
    let source = path("note.mid")
    try Data(bytes).write(to: source)
    let made = try await convert(source, to: "wav")
    let file = try AVAudioFile(forReading: made), buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    XCTAssertGreaterThan(Double(file.length) / file.fileFormat.sampleRate, 1)
    let loudest = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
    XCTAssertGreaterThan(loudest, 0.01, "it is not silence")
    XCTAssertEqual(ConvertKind(fileType: try ProcessableFile(url: source).fileType), .audio)
  }

  func test_subtitlesGoThereAndBack() async throws {
    let source = try write("1\n00:00:01,000 --> 00:00:02,500\nHello, <i>you</i>\nthere\n\n2\n00:00:04,000 --> 00:00:05,000\nBye & thanks\n", "a.srt")
    for ext in ["ass", "ttml", "lrc"] {
      let back = try Subtitles.read(try await convert(try await convert(source, to: ext), to: "srt"))
      XCTAssertEqual(back.map(\.start), [1, 4], ext)
      XCTAssertEqual(back.map(\.end), [2.5, 5], ext)
      XCTAssertEqual(back[0].text.replacingOccurrences(of: "\n", with: " "), "Hello, you there", ext)
      XCTAssertEqual(back[1].text, "Bye & thanks", ext)
    }
  }

  // MARK: - Archives

  func test_moreArchives() async throws {
    let inside = try folder("inside")
    try "hello".write(to: inside.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let source = path("things.zip")
    try ExternalTools.run(ArchiveProcessor.tool, ["-a", "-c", "-f", source.path, "-C", workspace.path, "inside"])
    for ext in ["txz", "tbz2", "cpio", "iso"] {
      let made = try await convert(source, to: ext)
      XCTAssertTrue(ExternalTools.answer(of: ArchiveProcessor.tool, ["-t", "-f", made.path]).lowercased().contains("a.txt"), ext)
      let made10 = try await convert(made, to: "zip")
      XCTAssertTrue(ExternalTools.answer(of: ArchiveProcessor.tool, ["-x", "-O", "-f", made10.path]).contains("hello"), ext)
    }
    let disk = try await convert(try await convert(source, to: "iso"), to: "dmg")
    XCTAssertTrue(ExternalTools.answer(of: URL(fileURLWithPath: "/usr/bin/hdiutil"), ["imageinfo", "-format", disk.path]).contains("UDZO"))
  }

  // MARK: - Damaged

  /// Whatever is in it, a file that is not what it says fails and says so.
  func test_whatIsBrokenSaysSo() async throws {
    for ext in ["xlsx", "ods", "epub", "cbz", "glb", "gltf", "3mf", "off", "dae", "sqlite", "kmz", "mid", "gpx", "kml", "vcf", "ics", "woff", "woff2", "ttf", "ass", "ttml", "lrc", "xml", "jsonl"] {
      for junk in ["", "not at all \u{0}\u{1}\u{2}", "PK\u{3}\u{4}", "{\"a\":"] {
        let source = path("bad.\(ext)")
        try Data(junk.utf8).write(to: source)
        let target = ["epub": "txt", "cbz": "pdf", "glb": "obj", "gltf": "obj", "3mf": "obj", "off": "obj", "dae": "obj", "mid": "wav", "woff": "ttf", "woff2": "ttf", "ttf": "woff", "ass": "srt", "ttml": "srt", "lrc": "srt"][ext] ?? "json"
        let status: ProcessingStatus?, said: String?
        do { let entry = try await run(source, to: target); (status, said) = (entry.status, entry.errorMessage) } catch { (status, said) = (.failed, error.localizedDescription) }
        XCTAssertEqual(status, .failed, "\(ext) holding \(junk.debugDescription)")
        XCTAssertFalse(said?.isEmpty ?? true, ext)
      }
    }
  }
}
