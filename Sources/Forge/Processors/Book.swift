import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// EPUB: pages of a website, in an order, in a box.
enum Book {
  static let type = UTType(filenameExtension: "epub")

  @MainActor
  static func read(_ url: URL) throws -> NSAttributedString {
    let pages = try chapters(of: url)
    let all = NSMutableAttributedString()
    for page in pages {
      guard let words = try? NSAttributedString(
        data: page, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
        documentAttributes: nil
      ), words.length > 0 else { continue }
      if all.length > 0 { all.append(NSAttributedString(string: "\n\n")) }
      all.append(words)
    }
    guard all.length > 0 else { throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) has no words in it, or is locked to a shop.") }
    return all
  }

  /// What it is called and who wrote it.
  static func details(of url: URL) -> [NSAttributedString.DocumentAttributeKey: Any] {
    guard let zip = try? Zip.Reader(url), let (_, package) = try? package(in: zip) else { return [:] }
    let found: [(NSAttributedString.DocumentAttributeKey, String)] = [(.title, "title"), (.author, "creator"), (.subject, "subject")]
    return found.reduce(into: [:]) { details, pair in
      if let value = elements(pair.1, in: package).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { details[pair.0] = value }
    }
  }

  private static func elements(_ name: String, in element: XMLElement) -> [XMLElement] {
    (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap { ($0.localName == name ? [$0] : []) + elements(name, in: $0) }
  }

  private static func root(_ text: String) throws -> XMLElement {
    guard let root = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]).rootElement() else { throw Zip.Reader.broken }
    return root
  }

  private static func package(in zip: Zip.Reader) throws -> (path: String, XMLElement) {
    guard let path = elements("rootfile", in: try root(try zip.text("META-INF/container.xml"))).first?.attribute(forName: "full-path")?.stringValue else { throw Zip.Reader.broken }
    return (path, try root(try zip.text(path)))
  }

  private static func chapters(of url: URL) throws -> [Data] {
    let zip = try Zip.Reader(url)
    let (path, package) = try package(in: zip)
    let folder = path.contains("/") ? String(path[...path.lastIndex(of: "/")!]) : ""
    let places = elements("item", in: package).reduce(into: [String: String]()) { places, item in
      if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue { places[id] = href }
    }
    return elements("itemref", in: package).compactMap { $0.attribute(forName: "idref")?.stringValue }.compactMap { places[$0] }.compactMap { href in
      let place = folder + (href.removingPercentEncoding ?? href)
      // Without its pictures: they are in the box, and whatever asks for them
      // out here would be asking somewhere else.
      guard let text = try? zip.text((place as NSString).standardizingPath) else { return nil }
      return Data(text.replacing(#/(?s)<(img|image|link|script|object|iframe)\b[^>]*>/#, with: "").utf8)
    }
  }

  // MARK: - Writing

  @MainActor
  static func data(_ document: NSAttributedString, details: DocumentText.Details, fallbackTitle: String) throws -> Data {
    let html = try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [
      .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
      .excludedElements: ["doctype", "meta", "title"],
    ])
    let tidy = try XMLDocument(data: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
    tidy.documentContentKind = .xhtml
    guard let page = tidy.rootElement() else { throw Zip.Reader.broken }
    page.removeNamespace(forPrefix: "")
    let inside = page.elements(forName: "body").first?.children?.map { $0.xmlString(options: [.nodeCompactEmptyElement]) }.joined(separator: "\n") ?? ""
    let style = (page.elements(forName: "head").first?.elements(forName: "style").first?.stringValue ?? "")
      // A book is set by whoever reads it: in what face, and how large, is theirs.
      .replacing(#/font: [0-9.]+px [^;}]*;?/#, with: "").replacing(#/(color|caret-color|-webkit-text-stroke)[^;}]*;?/#, with: "")
    func said(_ key: NSAttributedString.DocumentAttributeKey) -> String? { (details[key] as? String).flatMap { $0.isEmpty ? nil : DataFormats.escaped($0) } }
    let title = said(.title) ?? DataFormats.escaped(fallbackTitle), head = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
    let author = said(.author).map { "<dc:creator>\($0)</dc:creator>" } ?? ""
    let stamp = ISO8601DateFormatter().string(from: Date())
    let package = head + """
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
      <dc:identifier id="id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier><dc:title>\(title)</dc:title>\(author)<dc:language>\(Locale.current.language.languageCode?.identifier ?? "en")</dc:language>\
      <meta property="dcterms:modified">\(stamp)</meta></metadata><manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>\
      <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="text"/></spine></package>
      """
    func xhtml(_ body: String, _ style: String = "") -> Data {
      Data((head + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>\(title)</title><style>\(DataFormats.escaped(style))</style></head><body>\(body)</body></html>").utf8)
    }
    return Zip.data([
      Zip.Entry(name: "mimetype", data: Data("application/epub+zip".utf8), isStored: true),
      Zip.Entry(name: "META-INF/container.xml", data: Data((head + #"<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#).utf8)),
      Zip.Entry(name: "book.opf", data: Data(package.utf8)),
      Zip.Entry(name: "text.xhtml", data: xhtml(inside, style)),
      Zip.Entry(name: "nav.xhtml", data: xhtml("<nav epub:type=\"toc\"><ol><li><a href=\"text.xhtml\">\(title)</a></li></ol></nav>")),
    ])
  }
}

/// Comics: a box of pictures in the order of their names.
final class ComicProcessor: FileProcessor, @unchecked Sendable {
  let name = "Comic Processor"

  static let readable: Set<String> = ["cbz", "cbr", "cb7", "cbt"]

  func canProcess(_ file: ProcessableFile) -> Bool {
    Self.readable.contains(file.url.pathExtension.lowercased()) || file.fileType.conforms(to: .pdf)
  }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    let source = file.url.pathExtension.lowercased(), target = Conversions.fileExtension(of: target)
    return source == "pdf" ? target == "cbz" : source != target && ["pdf", "cbz"].contains(target)
  }

  private static let longestSide: CGFloat = 2400

  func process(
    _ input: URL, to output: URL, with operations: [Operation], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    // A processor that reads a file is asked for any format, and hands on what is not its own.
    guard ["pdf", "cbz"].contains(output.pathExtension.lowercased()), input.pathExtension.lowercased() != output.pathExtension.lowercased() else {
      throw ProcessingError.unsupportedConversion(from: UTType(filenameExtension: input.pathExtension) ?? .data, to: UTType(filenameExtension: output.pathExtension) ?? .data)
    }
    let start = Date()
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("forge-comic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    if input.pathExtension.lowercased() == "pdf" {
      try Self.draw(input, into: scratch, progress: progress)
    } else {
      do { try ExternalTools.run(ArchiveProcessor.tool, ["-x", "-f", input.path, "-C", scratch.path]) } catch is CancellationError { throw CancellationError() } catch {
        throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) cannot be read: it may be damaged, or want a password.")
      }
    }
    let pages = Self.pictures(in: scratch)
    guard !pages.isEmpty else { throw ProcessingError.conversionFailed(reason: "There are no pictures in \(input.lastPathComponent).") }

    if output.pathExtension.lowercased() == "cbz" {
      let entries = try pages.enumerated().map { index, page in
        Zip.Entry(name: String(format: "%04d.%@", index + 1, page.pathExtension.lowercased()), data: try Data(contentsOf: page))
      }
      try Zip.data(entries).write(to: output, options: .atomic)
    } else {
      let book = PDFDocument()
      for (index, page) in pages.enumerated() {
        try Task.checkCancellation()
        // By its file, so that a JPEG is kept as the JPEG it is.
        if let picture = NSImage(contentsOf: page), let made = PDFPage(image: picture) { book.insert(made, at: book.pageCount) }
        progress(Double(index + 1) / Double(pages.count))
      }
      guard book.pageCount > 0, book.write(to: output) else { throw ProcessingError.conversionFailed(reason: "Cannot write \(output.lastPathComponent)") }
    }
    progress(1)
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    return ProcessingResult(outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start))
  }

  private static func pictures(in folder: URL) -> [URL] {
    let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    return (all?.compactMap { $0 as? URL } ?? []).filter { url in
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        && !url.path.contains("__MACOSX")
    }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  private static func draw(_ input: URL, into folder: URL, progress: (Double) -> Void) throws {
    guard let pdf = PDFDocument(url: input) else { throw ProcessingError.conversionFailed(reason: "Cannot open \(input.lastPathComponent)") }
    try SimpleDocProcessor.refuseIfLocked(pdf, named: input.lastPathComponent)
    for index in 0..<pdf.pageCount {
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else { continue }
      let box = page.bounds(for: .cropBox), scale = longestSide / max(box.width, box.height, 1)
      let picture = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
      guard let tiff = picture.tiffRepresentation, let made = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { continue }
      try made.write(to: folder.appendingPathComponent(String(format: "%05d.jpg", index + 1)))
      progress(Double(index + 1) / Double(pdf.pageCount) * 0.8)
    }
  }
}
