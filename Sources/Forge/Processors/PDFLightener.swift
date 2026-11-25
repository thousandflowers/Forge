import Foundation
import PDFKit
import Quartz

/// A PDF whose pictures weigh less, and whose words are still words.
///
/// Drawn again through the filter macOS itself uses for it, with less brutal
/// settings: its own "Reduce File Size" takes a scan to where it cannot be
/// read. Links are no part of a page's drawing, and are put back.
enum PDFLightener {
  struct Level: Sendable {
    let quality: Double
    let dotsPerInch: Int
  }

  /// From what nobody notices to what can still be read.
  static let levels = [Level(quality: 0.6, dotsPerInch: 150), Level(quality: 0.45, dotsPerInch: 120), Level(quality: 0.3, dotsPerInch: 96), Level(quality: 0.2, dotsPerInch: 72)]

  static func write(_ url: URL, to output: URL, at level: Level) throws {
    let name = url.lastPathComponent
    guard let drawn = CGPDFDocument(url as CFURL), let source = PDFDocument(url: url) else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(name)")
    }
    try SimpleDocProcessor.refuseIfLocked(source, named: name)
    try PDFTools.refuseIfSigned(url)
    guard let filter = QuartzFilter(properties: properties(level)),
          let context = CGContext(output as CFURL, mediaBox: nil, nil), filter.apply(to: context) else {
      throw ProcessingError.conversionFailed(reason: "\(name) could not be written")
    }
    for number in 1...max(1, drawn.numberOfPages) {
      try Task.checkCancellation()
      guard let page = drawn.page(at: number) else { continue }
      var box = page.getBoxRect(.mediaBox)
      context.beginPage(mediaBox: &box)
      context.drawPDFPage(page)
      context.endPage()
    }
    // Its contents list, by page number.
    if let outline = drawn.outline { CGPDFContextSetOutline(context, outline) }
    context.closePDF()
    filter.remove(from: context)

    guard let made = PDFDocument(url: output), made.pageCount == source.pageCount else {
      throw ProcessingError.conversionFailed(reason: "\(name) could not be written")
    }
    for index in 0..<source.pageCount {
      guard let old = source.page(at: index), let new = made.page(at: index) else { continue }
      new.rotation = old.rotation
      new.setBounds(old.bounds(for: .cropBox), for: .cropBox)
      for annotation in old.annotations {
        guard let copy = annotation.copy() as? PDFAnnotation else { continue }
        // Where a link goes, it goes in this document.
        if let destination = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination,
           let target = self.destination(destination, from: source, in: made) {
          copy.action = PDFActionGoTo(destination: target)
        }
        new.addAnnotation(copy)
      }
    }
    made.documentAttributes = source.documentAttributes
    guard made.write(to: output) else {
      throw ProcessingError.conversionFailed(reason: "\(name) could not be written")
    }
  }

  private static func properties(_ level: Level) -> [String: Any] {
    let scale: [String: Any] = [
      "ImageResolution": level.dotsPerInch, "ImageScaleFactor": 0, "ImageScaleInterpolate": 3, "ImageSizeMax": 0, "ImageSizeMin": 128,
    ]
    let images: [String: Any] = [
      "Compression Quality": level.quality, "ImageCompression": "ImageJPEGCompress", "ImageScaleSettings": scale,
    ]
    return [
      "Domains": ["Applications": true, "Printing": true], "FilterType": 1, "Name": "Forge",
      "FilterData": ["ColorSettings": ["ImageSettings": images]],
    ]
  }

  private static func destination(_ old: PDFDestination, from source: PDFDocument, in made: PDFDocument) -> PDFDestination? {
    guard let page = old.page, let target = made.page(at: source.index(for: page)) else { return nil }
    let new = PDFDestination(page: target, at: old.point)
    new.zoom = old.zoom
    return new
  }
}
