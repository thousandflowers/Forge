import Foundation
import PDFKit

/// Pages chosen, turned and cropped, in a PDF that stays the PDF it is: its
/// words are words, and its links go where they went.
enum PDFTools {
  /// Whether a step here has anything to do with a PDF's pages.
  static func change(_ operations: [Operation]) -> Bool {
    operations.tools.contains { [.pages, .dropPages, .turn, .crop].contains($0.kind) }
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
