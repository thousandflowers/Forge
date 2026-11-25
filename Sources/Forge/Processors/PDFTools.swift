import CoreText
import Foundation
import PDFKit

/// Pages chosen, turned and cropped, in a PDF that stays the PDF it is: its
/// words are words, and its links go where they went.
enum PDFTools {
  /// Whether a step here has anything to do with a PDF's pages.
  static func change(_ operations: [Operation]) -> Bool {
    operations.tools.contains { [.pages, .dropPages, .turn, .crop, .numbers, .sheet].contains($0.kind) }
  }

  /// Changing a signed document is unsigning it.
  ///
  /// A signature says which bytes of the file it is of, and so is the one thing
  /// in a PDF that is always written out plainly.
  static func refuseIfSigned(_ url: URL) throws {
    guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe), bytes.range(of: Data("/ByteRange".utf8)) != nil else { return }
    throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is signed, and a change to it would undo the signature.")
  }

  static func apply(_ operations: [Operation], to url: URL, writing output: URL) throws {
    let name = url.lastPathComponent
    guard var pdf = PDFDocument(url: url) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(name)")
    }
    try SimpleDocProcessor.refuseIfLocked(pdf, named: name)
    for tool in operations.tools {
      switch tool {
      case .pages(let list): pdf = try keep(list.indices(of: pdf.pageCount), of: pdf, named: name)
      case .dropPages(let list):
        let dropped = Set(list.indices(of: pdf.pageCount))
        pdf = try keep((0..<pdf.pageCount).filter { !dropped.contains($0) }, of: pdf, named: name)
      case .turn(let turn):
        for page in pages(of: pdf) { page.rotation = (page.rotation + turn.degrees + 360) % 360 }
      case .crop(let crop):
        for page in pages(of: pdf) { try Self.crop(page, to: crop) }
      case .numbers: for (index, page) in pages(of: pdf).enumerated() { number(page, index + 1) }
      case .sheet(let count): pdf = try imposed(pdf, count, named: name)
      default: break
      }
    }
    guard pdf.write(to: output) else {
      throw ProcessingError.conversionFailed(reason: "\(name) could not be written")
    }
  }

  private static func pages(of pdf: PDFDocument) -> [PDFPage] { (0..<pdf.pageCount).compactMap(pdf.page(at:)) }

  private static func keep(_ kept: [Int], of pdf: PDFDocument, named name: String) throws -> PDFDocument {
    guard !kept.isEmpty else {
      throw ProcessingError.conversionFailed(
        reason: "\(name) has \(pdf.pageCount) \(pdf.pageCount == 1 ? "page" : "pages"), and that leaves none of them."
      )
    }
    // In order, the rest are taken out, and the document keeps its contents
    // list and everything else that is not a page.
    if kept == Array(Set(kept)).sorted() {
      let staying = Set(kept)
      for index in (0..<pdf.pageCount).reversed() where !staying.contains(index) { pdf.removePage(at: index) }
      return pdf
    }
    let made = PDFDocument()
    made.documentAttributes = pdf.documentAttributes
    for index in kept {
      // A copy, or a page asked for twice is taken from where it was first put.
      guard let page = pdf.page(at: index)?.copy() as? PDFPage else { continue }
      made.insert(page, at: made.pageCount)
    }
    return made
  }

  // MARK: - Numbers

  /// Put on the page rather than drawn into it: what it says stays words, and
  /// its links go where they went.
  private static func number(_ page: PDFPage, _ number: Int) {
    let box = page.bounds(for: .cropBox), turned = (page.rotation % 360 + 360) % 360
    let isOnItsSide = turned % 180 != 0
    let seen = CGSize(width: isOnItsSide ? box.height : box.width, height: isOnItsSide ? box.width : box.height)
    let height = max(8, min(seen.width, seen.height) * 0.017), width = height * 6
    // Middle of the foot of it, as it is seen, and then as it is stored.
    let foot = CGRect(x: (seen.width - width) / 2, y: height * 1.6, width: width, height: height * 1.4)
    let place: CGRect
    switch turned {
    case 90: place = CGRect(x: seen.height - foot.maxY, y: foot.minX, width: foot.height, height: foot.width)
    case 180: place = CGRect(x: seen.width - foot.maxX, y: seen.height - foot.maxY, width: foot.width, height: foot.height)
    case 270: place = CGRect(x: foot.minY, y: seen.width - foot.maxX, width: foot.height, height: foot.width)
    default: place = foot
    }
    page.addAnnotation(PageNumber(
      "\(number)", size: height, turned: turned, bounds: place.offsetBy(dx: box.minX, dy: box.minY)
    ))
  }

  private final class PageNumber: PDFAnnotation {
    private let said: String
    private let size: CGFloat
    private let turned: Int

    init(_ said: String, size: CGFloat, turned: Int, bounds: CGRect) {
      self.said = said
      self.size = size
      self.turned = turned
      super.init(bounds: bounds, forType: .stamp, withProperties: nil)
      contents = said
      shouldPrint = true
      isReadOnly = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
      context.saveGState()
      defer { context.restoreGState() }
      let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
      let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: said, attributes: [.font: font, fromContext: true]))
      let length = CTLineGetTypographicBounds(line, nil, nil, nil)
      context.textMatrix = .identity
      context.translateBy(x: bounds.midX, y: bounds.midY)
      context.rotate(by: CGFloat(turned) * .pi / 180)
      context.textPosition = CGPoint(x: -length / 2, y: -size * 0.35)
      // With an edge of white, to be read on a dark picture as well.
      context.setTextDrawingMode(.stroke)
      context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
      context.setLineWidth(size * 0.22)
      context.setLineJoin(.round)
      CTLineDraw(line, context)
      context.textPosition = CGPoint(x: -length / 2, y: -size * 0.35)
      context.setTextDrawingMode(.fill)
      context.setFillColor(CGColor(gray: 0.15, alpha: 1))
      CTLineDraw(line, context)
    }
  }

  // MARK: - Several to a sheet

  /// How many across and down, on a sheet as it is seen.
  static func grid(_ count: Int, of page: CGSize) -> (across: Int, down: Int) {
    let side = Int(Double(count).squareRoot())
    if side * side == count { return (side, side) }
    let short = (1...side).last { count % $0 == 0 } ?? 1, long = count / short
    // The sheet lies on its side, and the pages go along it.
    return page.width <= page.height ? (long, short) : (short, long)
  }

  private static func imposed(_ pdf: PDFDocument, _ count: Int, named name: String) throws -> PDFDocument {
    let all = pages(of: pdf)
    guard let first = all.first else { throw ProcessingError.conversionFailed(reason: "\(name) has no pages") }
    let one = shown(first), (across, down) = grid(count, of: one)
    let sheet = across == down ? one : CGSize(width: one.height, height: one.width)
    let data = NSMutableData()
    var media = CGRect(origin: .zero, size: sheet)
    guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
      throw ProcessingError.conversionFailed(reason: "\(name) could not be written")
    }
    let cell = CGSize(width: sheet.width / CGFloat(across), height: sheet.height / CGFloat(down))
    let gap = min(cell.width, cell.height) * 0.02
    for start in stride(from: 0, to: all.count, by: count) {
      try Task.checkCancellation()
      context.beginPDFPage(nil)
      for (index, page) in all[start..<min(start + count, all.count)].enumerated() {
        let size = shown(page)
        let scale = min((cell.width - 2 * gap) / size.width, (cell.height - 2 * gap) / size.height)
        let corner = CGPoint(x: CGFloat(index % across) * cell.width, y: sheet.height - CGFloat(index / across + 1) * cell.height)
        context.saveGState()
        context.translateBy(x: corner.x + (cell.width - size.width * scale) / 2, y: corner.y + (cell.height - size.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.clip(to: CGRect(origin: .zero, size: size))
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
      }
      context.endPDFPage()
    }
    context.closePDF()
    guard let made = PDFDocument(data: data as Data) else { throw ProcessingError.conversionFailed(reason: "\(name) could not be written") }
    made.documentAttributes = pdf.documentAttributes
    return made
  }

  private static func shown(_ page: PDFPage) -> CGSize {
    let box = page.bounds(for: .cropBox)
    return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
  }

  /// The crop is of the page as it is seen, and is kept as the page is stored.
  private static func crop(_ page: PDFPage, to crop: Tool.Crop) throws {
    let box = page.bounds(for: .cropBox)
    let turned = (page.rotation % 360 + 360) % 360
    let isOnItsSide = turned % 180 != 0
    let seen = CGSize(width: isOnItsSide ? box.height : box.width, height: isOnItsSide ? box.width : box.height)
    let kept = try crop.box(in: seen)
    let top = kept.minY, left = kept.minX, bottom = seen.height - kept.maxY, right = seen.width - kept.maxX
    // Which side of the stored page each side seen is.
    let edges: (left: CGFloat, bottom: CGFloat, right: CGFloat, top: CGFloat)
    switch turned {
    case 90: edges = (top, left, bottom, right)
    case 180: edges = (right, top, left, bottom)
    case 270: edges = (bottom, right, top, left)
    default: edges = (left, bottom, right, top)
    }
    page.setBounds(CGRect(
      x: box.minX + edges.left, y: box.minY + edges.bottom,
      width: box.width - edges.left - edges.right, height: box.height - edges.top - edges.bottom
    ), for: .cropBox)
  }
}

private extension Tool.Turn {
  /// A page says which way up it is, and has no way to say it is mirrored.
  var degrees: Int {
    switch self {
    case .right: return 90
    case .half: return 180
    case .left: return 270
    case .mirror, .flip: return 0
    }
  }
}
