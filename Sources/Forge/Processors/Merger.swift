import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Puts the copies a split wrote into one file.
enum Merger {
  /// One PDF, a page per copy: images become pages, PDFs contribute theirs.
  static func pdf(from sources: [URL], to destination: URL) throws {
    let document = PDFDocument()
    for source in sources {
      if let existing = PDFDocument(url: source) {
        for index in 0..<existing.pageCount {
          if let page = existing.page(at: index) { document.insert(page, at: document.pageCount) }
        }
      } else if let image = NSImage(contentsOf: source), let page = PDFPage(image: image) {
        document.insert(page, at: document.pageCount)
      } else {
        throw ProcessingError.conversionFailed(reason: "\(source.lastPathComponent) cannot be put into a PDF")
      }
    }
    guard document.pageCount > 0 else {
      throw ProcessingError.conversionFailed(reason: "Nothing to merge")
    }
    guard document.write(to: destination) else {
      throw ProcessingError.conversionFailed(reason: "The merged PDF could not be written")
    }
  }
}
