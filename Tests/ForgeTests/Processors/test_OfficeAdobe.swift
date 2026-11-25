import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Forge

/// Office, Adobe, CAD and the rest, through the same door as any other file.
final class OfficeAdobeTests: BaseTestCase {

  private func convert(_ source: URL, to ext: String, file: StaticString = #filePath, line: UInt = #line) async throws -> URL {
    let type = try XCTUnwrap(FormatCatalog.type(named: ext), ext, file: file, line: line)
    let out = try folder("out-\(UUID().uuidString.prefix(6))")
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source), with: .make(format: type, category: .custom), destinationMode: .copyTo, destinationURL: out
    ) { _ in }
    XCTAssertEqual(entry.status, .completed, "\(source.lastPathComponent) to \(ext): \(entry.errorMessage ?? "")", file: file, line: line)
    return try XCTUnwrap(entry.outputURL, file: file, line: line)
  }

  private func write(_ text: String, _ name: String) throws -> URL {
    let url = path(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  private func twoPages() throws -> URL {
    let pdf = path("two.pdf")
    var box = CGRect(x: 0, y: 0, width: 800, height: 450)
    let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
    for page in 0..<2 {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(srgbRed: page == 0 ? 1 : 0, green: 0, blue: page == 0 ? 0 : 1, alpha: 1))
      context.fill(CGRect(x: 100, y: 100, width: 300, height: 200))
      context.endPDFPage()
    }
    context.closePDF()
    return pdf
  }

  // MARK: - Office

  /// A PDF as slides, and the slides as a PDF: the same pages, the same shape.
  func test_slidesGoThereAndBack() async throws {
    let slides = try await convert(try twoPages(), to: "pptx")
    let zip = try Zip.Reader(slides)
    for name in zip.names where name.hasSuffix(".xml") || name.hasSuffix(".rels") { XCTAssertNoThrow(try XMLDocument(data: try zip.data(name)), name) }
    let back = try await convert(slides, to: "pdf")
    let pdf = try XCTUnwrap(PDFDocument(url: back))
    XCTAssertEqual(pdf.pageCount, 2)
    let box = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
    XCTAssertEqual(box.width / box.height, 800.0 / 450, accuracy: 0.03)
    let picture = try await convert(slides, to: "png")
    XCTAssertEqual(contents(of: picture.deletingLastPathComponent()).count, 2)
  }

  func test_aSheetBecomesPages() async throws {
    let rows = (1...200).map { "\($0),name \($0),\($0 * 3)" }.joined(separator: "\n")
    let sheet = try await convert(try write("id,name,total\n\(rows)\n", "s.csv"), to: "xlsx")
    let made = try await convert(sheet, to: "pdf")
    let pdf = try XCTUnwrap(PDFDocument(url: made))
    XCTAssertGreaterThan(pdf.pageCount, 1)
    let words = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
    XCTAssertTrue(words.contains("name 1") && words.contains("name 200"), "every row of it")
  }

  func test_aLongPageIsCutBetweenLines() {
    let lines = (0..<100).map { CGRect(x: 0, y: CGFloat($0) * 30, width: 600, height: 30) }
    let pages = Drawn.pages(of: [CGRect(x: 0, y: 0, width: 600, height: 3000)], breaks: lines, width: 600)
    XCTAssertEqual(pages.map(\.height).reduce(0, +), 3000)
    XCTAssertTrue(pages.allSatisfy { $0.minY.truncatingRemainder(dividingBy: 30) == 0 })
    XCTAssertTrue(pages.allSatisfy { $0.height <= 777 })
  }

  /// A small disk in a file, made by hand: one stream long enough for pieces of its own.
  private func ole(_ streams: [(String, Data)]) -> Data {
    var head = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 16)
    var sectors: [Data] = [], table: [Int] = [], entries: [(String, Int, Int)] = []
    for (name, data) in streams {
      let whole = data + Data(count: max(0, 4096 - data.count))
      let start = sectors.count, count = (whole.count + 511) / 512
      for index in 0..<count {
        var piece = whole.subdata(in: (index * 512)..<min(whole.count, (index + 1) * 512))
        piece += Data(count: 512 - piece.count)
        sectors.append(piece)
        table.append(index == count - 1 ? 0xFFFF_FFFE : start + index + 1)
      }
      entries.append((name, start, whole.count))
    }
    var folder = Data()
    func entry(_ name: String, _ kind: Int, _ right: Int, _ child: Int, _ start: Int, _ size: Int) {
      let units = Array(name.utf16) + [0]
      var one = Data()
      for unit in units { one.append(number: Int(unit), 2) }
      one += Data(count: 64 - one.count)
      one.append(number: units.count * 2, 2); one.append(number: kind, 1); one.append(number: 1, 1)
      one.append(number: 0xFFFF_FFFF, 4); one.append(number: right, 4); one.append(number: child, 4)
      one += Data(count: 36)
      one.append(number: start, 4); one.append(number: size, 8)
      folder += one
    }
    entry("Root Entry", 5, 0xFFFF_FFFF, 1, 0xFFFF_FFFE, 0)
    for (index, one) in entries.enumerated() { entry(one.0, 2, index + 1 < entries.count ? index + 2 : 0xFFFF_FFFF, 0xFFFF_FFFF, one.1, one.2) }
    while folder.count % 512 != 0 { folder += Data(count: 128) }
    let folderAt = sectors.count
    for index in 0..<(folder.count / 512) { sectors.append(folder.subdata(in: (index * 512)..<((index + 1) * 512))); table.append(index == folder.count / 512 - 1 ? 0xFFFF_FFFE : folderAt + index + 1) }
    let tableAt = sectors.count
    table.append(0xFFFF_FFFD)
    var flat = Data()
    for one in table { flat.append(number: one, 4) }
    flat += Data(repeating: 0xFF, count: 512 - flat.count)
    sectors.append(flat)
    head.append(number: 62, 2); head.append(number: 3, 2); head.append(number: 0xFFFE, 2); head.append(number: 9, 2); head.append(number: 6, 2)
    head += Data(count: 10)
    head.append(number: 1, 4); head.append(number: folderAt, 4); head.append(number: 0, 4); head.append(number: 4096, 4)
    head.append(number: 0xFFFF_FFFE, 4); head.append(number: 0, 4); head.append(number: 0xFFFF_FFFE, 4); head.append(number: 0, 4)
    head.append(number: tableAt, 4)
    head += Data(repeating: 0xFF, count: 512 - head.count)
    return sectors.reduce(head, +)
  }

  func test_aMessageFromOutlook() async throws {
    func wide(_ text: String) -> Data { text.utf16.reduce(into: Data()) { $0.append(number: Int($1), 2) } }
    let source = path("a.msg")
    try ole([("__substg1.0_0037001F", wide("Lunch?")), ("__substg1.0_0C1A001F", wide("Anna")), ("__substg1.0_1000001F", wide("At one, è ok"))]).write(to: source)
    let words = try text(try await convert(source, to: "txt"))
    XCTAssertTrue(words.contains("Subject: Lunch?") && words.contains("At one, è ok"), words)
    _ = try await convert(source, to: "pdf")
  }

  func test_anOldWorkbook() throws {
    func record(_ kind: Int, _ body: Data) -> Data { var out = Data(); out.append(number: kind, 2); out.append(number: body.count, 2); return out + body }
    func bytes(_ numbers: [(Int, Int)]) -> Data { numbers.reduce(into: Data()) { $0.append(number: $1.0, $1.1) } }
    let words = bytes([(2, 4), (2, 4), (4, 2), (0, 1)]) + Data("name".utf8) + bytes([(2, 2), (1, 1), (0xE8, 2), (0x21, 2)])
    var book = record(0x809, bytes([(0x600, 2), (5, 2), (0, 4), (0, 4), (0, 4)])) + record(0xE0, Data(count: 20)) + record(0xE0, bytes([(0, 2), (14, 2)]) + Data(count: 16))
    let sheetSize = 4 + 8 + 5
    book += record(0xFC, words)
    let at = book.count + sheetSize + 4
    book += record(0x85, bytes([(at, 4), (0, 2), (5, 1), (0, 1)]) + Data("Sales".utf8)) + record(0x0A, Data())
    XCTAssertEqual(book.count, at)
    book += record(0x809, bytes([(0x600, 2), (16, 2), (0, 4), (0, 4), (0, 4)]))
    book += record(0xFD, bytes([(0, 2), (0, 2), (0, 2), (0, 4)])) + record(0xFD, bytes([(1, 2), (0, 2), (0, 2), (1, 4)]))
    book += record(0x204, bytes([(0, 2), (1, 2), (0, 2), (1, 2), (0, 1)]) + Data("n".utf8))
    book += record(0x203, bytes([(1, 2), (1, 2), (0, 2), (Int(Int64(bitPattern: 12.5.bitPattern)), 8)]))
    book += record(0x27E, bytes([(0, 2), (2, 2), (1, 2), (45000 << 2 | 2, 4)])) + record(0x0A, Data())
    let source = path("old.xls")
    try ole([("Workbook", book)]).write(to: source)
    let table = try XCTUnwrap(DataFormats.read(source) as? Separated.Table)
    XCTAssertEqual(table.columns, ["name", "n", "2023-03-15"])
    XCTAssertEqual(table.rows.first?["name"], "è!")
    XCTAssertEqual(table.rows.first?["n"], "12.5")
  }

  // MARK: - Adobe

  func test_anIllustratorFileIsItsPDF() async throws {
    let source = path("logo.ai")
    try FileManager.default.copyItem(at: try twoPages(), to: source)
    let made = try await convert(source, to: "pdf")
    XCTAssertEqual(PDFDocument(url: made)?.pageCount, 2)
    let picture = try await convert(source, to: "png")
    XCTAssertEqual(contents(of: picture.deletingLastPathComponent()).count, 2)
  }

  /// Saved without its PDF, what there is is a notice. It is not the drawing.
  func test_anIllustratorFileWithNoPDFIsRefused() async throws {
    let source = path("empty.ai")
    var box = CGRect(x: 0, y: 0, width: 400, height: 400)
    let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    for row in 0..<6 {
      for (line, words) in ["This is an Adobe Illustrator File that was", "saved without PDF Content."].enumerated() {
        context.textPosition = CGPoint(x: 10, y: 380 - CGFloat(row * 40 + line * 14))
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 10)])), context)
      }
    }
    context.endPDFPage()
    context.closePDF()
    do {
      _ = try await coordinator().processFile(try ProcessableFile(url: source), with: .make(format: .png, category: .custom), destinationMode: .copyTo, destinationURL: try folder("o")) { _ in }
      XCTFail("a notice is not a drawing")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Create PDF Compatible File"), error.localizedDescription) }
  }

  func test_blenderWritesAnFBXWeReadBack() async throws {
    try XCTSkipUnless(ExternalTool.blender.isInstalled, "Blender is not here")
    let source = try write("o t\nv 0 0 0\nv 2 0 0\nv 0 1 0\nv 0 0 3\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4\n", "it's; a \"name\".obj")
    let made = try await convert(source, to: "fbx")
    let points = try Meshes.read(made).flatMap(\.points)
    for (axis, size) in [(0, 2), (1, 1), (2, 3)] as [(Int, Float)] {
      XCTAssertEqual((points.map { $0[axis] }.max() ?? 0) - (points.map { $0[axis] }.min() ?? 0), size, accuracy: 0.01)
    }
    let blend = try await convert(source, to: "blend")
    let back = try await convert(blend, to: "glb")
    XCTAssertEqual(try Meshes.read(back).reduce(0) { $0 + $1.triangles.count }, 12)
  }

  func test_theWordsOfAnIDML() async throws {
    let source = path("book.idml")
    let story = #"<idPkg:Story xmlns:idPkg="x"><Story><ParagraphStyleRange AppliedParagraphStyle="ParagraphStyle/Title"><CharacterStyleRange><Content>First</Content><Br/></CharacterStyleRange></ParagraphStyleRange><ParagraphStyleRange><CharacterStyleRange FontStyle="Bold"><Content>loud &amp; clear</Content></CharacterStyleRange></ParagraphStyleRange></Story></idPkg:Story>"#
    try Zip.data([
      Zip.Entry(name: "designmap.xml", data: Data(#"<Document><idPkg:Story src="Stories/Story_u1.xml"/></Document>"#.utf8)), Zip.Entry(name: "Stories/Story_u1.xml", data: Data(story.utf8)),
    ]).write(to: source)
    let words = try text(try await convert(source, to: "txt"))
    XCTAssertTrue(words.contains("First") && words.contains("loud & clear"), words)
    let page = try text(try await convert(source, to: "html"))
    XCTAssertTrue(page.contains("loud &amp; clear"), page)
  }

  func test_aPreviewIsTakenOut() async throws {
    let small = try Data(contentsOf: Fixture.image(at: path("a.png")))
    let source = path("a.indd")
    try (Data([6, 6, 0xED, 0xF5]) + Data("<xmpGImg:image>\(small.base64EncodedString())</xmpGImg:image>".utf8)).write(to: source)
    let made = try await convert(source, to: "jpeg")
    XCTAssertNotNil(CGImageSourceCreateWithURL(made as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
  }

  func test_aLargePhotoshopPicture() async throws {
    var data = Data("8BPS".utf8)
    data.append(big: 2, 2); data += Data(count: 6)
    data.append(big: 3, 2); data.append(big: 2, 4); data.append(big: 4, 4); data.append(big: 8, 2); data.append(big: 3, 2)
    data.append(big: 0, 4); data.append(big: 0, 4); data.append(big: 0, 8); data.append(big: 1, 2)
    for _ in 0..<6 { data.append(big: 2, 4) }
    // Four the same, in two bytes: all red.
    for value in [UInt8(255), 0, 0] { for _ in 0..<2 { data += Data([UInt8(bitPattern: -3), value]) } }
    let source = path("big.psb")
    try data.write(to: source)
    let made = try await convert(source, to: "png")
    let image = try XCTUnwrap(CGImageSourceCreateWithURL(made as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    XCTAssertEqual([image.width, image.height], [4, 2])
    var pixel = [UInt8](repeating: 0, count: 4)
    CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    XCTAssertEqual(Array(pixel.prefix(3)), [255, 0, 0])
  }

  func test_palettesGoThereAndBack() async throws {
    let source = try write("name,hex\nSun,#FFCC00\nSea,#0066AA\n", "p.csv")
    for ext in ["ase", "gpl"] {
      let there = try await convert(source, to: ext)
      let made1 = try await convert(there, to: "csv")
      XCTAssertEqual(try text(made1), "name,hex\nSun,#FFCC00\nSea,#0066AA\n", ext)
    }
  }

  // MARK: - CAD

  private let drawing = """
    0\nSECTION\n2\nBLOCKS\n0\nBLOCK\n2\nBOX\n10\n0\n20\n0\n0\nLINE\n8\n0\n10\n0\n20\n0\n11\n10\n21\n0\n0\nENDBLK\n0\nENDSEC
    0\nSECTION\n2\nENTITIES\n0\nCIRCLE\n8\n0\n62\n1\n10\n50\n20\n50\n40\n25\n0\nLWPOLYLINE\n8\n0\n90\n2\n70\n0\n10\n0\n20\n0\n42\n1\n10\n100\n20\n0\n0\nINSERT\n2\nBOX\n10\n0\n20\n90\n41\n3\n0\nTEXT\n8\n0\n10\n10\n20\n10\n40\n5\n1\nHello & co\n0\nENDSEC\n0\nEOF\n
    """

  func test_aCADDrawing() async throws {
    let source = try write(drawing, "plan.dxf")
    let svg = try text(try await convert(source, to: "svg"))
    XCTAssertTrue(svg.contains("Hello &amp; co") && svg.contains("#d90000"), svg)
    XCTAssertNoThrow(try XMLDocument(xmlString: svg))
    let made2 = try await convert(source, to: "pdf")
    XCTAssertEqual(PDFDocument(url: made2)?.pageCount, 1)
    _ = try await convert(source, to: "png")
    let read = try Dxf.read(source)
    XCTAssertEqual(read.strokes.count, 3)
    XCTAssertEqual(read.strokes[1].path.boundingBoxOfPath.height, 50, accuracy: 1, "half a circle, from a bulge of one")
    XCTAssertEqual(read.strokes[2].path.boundingBoxOfPath.width, 30, accuracy: 0.1, "the block, three times as wide")
  }

  func test_aDrawingForACutter() async throws {
    let source = try write(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><g transform="translate(10 0)"><rect x="0" y="0" width="20" height="30"/><path d="M50 50a10 10 0 1 1 20 0a10 10 0 11-20 0z"/></g><circle cx="10" cy="90" r="5"/></svg>"#, "a.svg")
    let made = try Dxf.read(try await convert(source, to: "dxf"))
    XCTAssertEqual(made.strokes.count, 3)
    let boxes = made.strokes.map { $0.path.boundingBoxOfPath }
    XCTAssertEqual(boxes[0], CGRect(x: 10, y: 70, width: 20, height: 30))
    XCTAssertEqual(boxes[1].width, 20, accuracy: 0.1)
    XCTAssertEqual(boxes[1].midY, 50, accuracy: 0.2)
    XCTAssertEqual(boxes[2].midY, 10, accuracy: 0.1, "down on a screen is up on a board")
  }

  /// As a PDF an SVG is still lines, not a picture of them.
  func test_anSVGAsAPDFIsStillLines() async throws {
    let source = try write(#"<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect width="100" height="100" fill="red"/><text x="10" y="150">Words here</text></svg>"#, "v.svg")
    let made = try await convert(source, to: "pdf")
    let pdf = try XCTUnwrap(PDFDocument(url: made))
    XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 300, height: 200))
    XCTAssertFalse(String(decoding: try Data(contentsOf: made), as: UTF8.self).contains("/Subtype /Image"))
  }

  // MARK: - Shapes

  func test_otherProgramsShapes() throws {
    let x3d = try write(#"<X3D><Scene><Transform translation="1 0 0" scale="2 2 2"><Shape><IndexedFaceSet coordIndex="0 1 2 3 -1"><Coordinate point="0 0 0 1 0 0 1 1 0 0 1 0"/></IndexedFaceSet></Shape></Transform></Scene></X3D>"#, "a.x3d")
    let one = try Meshes.read(x3d)
    XCTAssertEqual(one.first?.triangles.count, 6)
    XCTAssertEqual(one.first?.points.map(\.x).max(), 3)
    let amf = try write("<amf><object id=\"1\"><mesh><vertices><vertex><coordinates><x>0</x><y>0</y><z>0</z></coordinates></vertex><vertex><coordinates><x>1</x><y>0</y><z>0</z></coordinates></vertex><vertex><coordinates><x>0</x><y>2</y><z>0</z></coordinates></vertex></vertices><volume><triangle><v1>0</v1><v2>1</v2><v3>2</v3></triangle></volume></mesh></object></amf>", "a.amf")
    XCTAssertEqual(try Meshes.read(amf).first?.points.map(\.y).max(), 2)
    // 3D Studio: an object of three points and a side.
    func chunk(_ kind: Int, _ body: Data) -> Data { var out = Data(); out.append(number: kind, 2); out.append(number: body.count + 6, 4); return out + body }
    var points = Data(), sides = Data()
    points.append(number: 3, 2)
    for value in [0, 0, 0, 1, 0, 0, 0, 0, 1] as [Float] { points.append(number: Int(value.bitPattern), 4) }
    sides.append(number: 1, 2)
    for value in [0, 1, 2, 0] { sides.append(number: value, 2) }
    let mesh = chunk(0x4100, chunk(0x4110, points) + chunk(0x4120, sides))
    let file = path("a.3ds")
    try chunk(0x4D4D, chunk(0x3D3D, chunk(0x4000, Data("tri\0".utf8) + mesh))).write(to: file)
    let tri = try XCTUnwrap(Meshes.read(file).first)
    XCTAssertEqual(tri.name, "tri")
    XCTAssertEqual(tri.points[2].y, 1, accuracy: 0.001, "its up is our up")
  }

  // MARK: - Data

  func test_packedRecordsGoThereAndBack() async throws {
    let source = try write(#"{"a":1,"b":-5,"big":70000,"f":1.5,"s":"è 🎈","n":null,"t":true,"l":[1,[2],{"x":"y"}],"long":"\#(String(repeating: "z", count: 300))"}"#, "a.json")
    let wanted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? NSDictionary)
    for ext in ["msgpack", "cbor"] {
      let there = try await convert(source, to: ext), back = try await convert(there, to: "json")
      XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: back)) as? NSDictionary, wanted, ext)
    }
    XCTAssertEqual(try Cbor.read(Data([0x9F, 0x01, 0xF9, 0x3C, 0x00, 0x7F, 0x61, 0x61, 0x61, 0x62, 0xFF, 0xFF])) as? NSArray, [1, 1.0, "ab"])
  }

  func test_otherData() async throws {
    let loose = try write("// note\n{ a: 1, 'b': [1,2,], }", "a.json5")
    let made3 = try await convert(loose, to: "yaml")
    XCTAssertTrue(try text(made3).contains("a: 1"))
    let settings = try write("# c\nexport A=1\nB=\"two words\"\n", "a.env")
    let made4 = try await convert(try await convert(settings, to: "json"), to: "env")
    XCTAssertEqual(try text(made4), "A=1\nB=\"two words\"\n")
    let po = try write("msgid \"\"\nmsgstr \"x\"\n\n#: a\nmsgid \"Hello\"\nmsgstr \"Ci\"\n\"ao\"\n", "a.po")
    let made5 = try await convert(po, to: "csv")
    XCTAssertEqual(try text(made5), "source,translation\nHello,Ciao\n")
    var dbf = Data([3, 124, 1, 1]); dbf.append(number: 1, 4); dbf.append(number: 32 + 64 + 1, 2); dbf.append(number: 1 + 4 + 8, 2); dbf += Data(count: 20)
    for (name, kind, size) in [("NAME", "C", 4), ("DAY", "D", 8)] { dbf += Data(name.utf8) + Data(count: 11 - name.utf8.count) + Data(kind.utf8) + Data(count: 4) + Data([UInt8(size)]) + Data(count: 15) }
    dbf += Data([0x0D]) + Data(" Anna20261124".utf8)
    let table = path("a.dbf")
    try dbf.write(to: table)
    let made6 = try await convert(table, to: "csv")
    XCTAssertEqual(try text(made6), "NAME,DAY\nAnna,2026-11-24\n")
  }

  func test_whatIsBrokenSaysSo() async throws {
    let targets = ["pptx": "pdf", "ppt": "pdf", "ai": "pdf", "idml": "txt", "indd": "png", "eps": "png", "psb": "png", "pcx": "png", "msg": "txt", "emlx": "txt", "dxf": "svg", "fbx": "obj", "3ds": "obj", "x3d": "obj", "amf": "obj", "xls": "csv", "dbf": "csv", "ase": "csv", "aco": "csv", "msgpack": "json", "cbor": "json", "po": "csv", "json5": "json", "xlsm": "csv"]
    for (ext, target) in targets {
      for junk in ["", "junk \u{0}\u{1}", "PK\u{3}\u{4}", "%PDF-\n"] {
        let source = path("bad.\(ext)")
        try Data(junk.utf8).write(to: source)
        let type = try XCTUnwrap(FormatCatalog.type(named: target))
        do {
          let entry = try await coordinator().processFile(try ProcessableFile(url: source), with: .make(format: type, category: .custom), destinationMode: .copyTo, destinationURL: try folder("o")) { _ in }
          XCTAssertEqual(entry.status, .failed, "\(ext) holding \(junk.debugDescription)")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
      }
    }
  }
}
