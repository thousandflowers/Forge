import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// The tables in a page or in a photo of one, as rows and columns.
enum TableReader {
  /// Drawn this finely to be read.
  private static let dots: CGFloat = 200

  static func write(
    from input: URL, to output: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    guard #available(macOS 26, *) else {
      throw ProcessingError.conversionFailed(reason: "Reading tables needs macOS 26.")
    }
    let sheets = try await tables(in: input, progress: progress)
    guard !sheets.isEmpty else { throw ProcessingError.conversionFailed(reason: "There are no tables to be seen in \(input.lastPathComponent).") }
    let wanted = output.pathExtension.lowercased()
    let first: [(name: String, table: Separated.Table)] = sheets.enumerated().map { Grid.sheet(sheets.count == 1 ? "Table" : "Table \($0.offset + 1)", $0.element) }
    var extras: [URL] = []
    if ["csv", "tsv"].contains(wanted) {
      // One table in a CSV, so a file each.
      for (index, sheet) in first.enumerated() {
        let place = index == 0 ? output : output.numbered(index + 1, of: first.count)
        try Separated.text(from: sheet.table.rows, columns: sheet.table.columns, separator: wanted == "tsv" ? "\t" : ",")
          .write(to: place, atomically: true, encoding: .utf8)
        if index > 0 { extras.append(place) }
      }
    } else {
      // Through a sheet, whatever it is to become.
      let book = FileManager.default.temporaryDirectory.appendingPathComponent("forge-tables-\(UUID().uuidString).xlsx")
      defer { try? FileManager.default.removeItem(at: book) }
      try Xlsx.write(try Grid.book(first)).write(to: book)
      if wanted == "xlsx" { try FileManager.default.copyItem(at: book, to: output) } else {
        _ = try await DataProcessor().process(book, to: output, with: []) { _ in }
      }
    }
    progress(1)
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    return ProcessingResult(outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start), additionalOutputs: extras)
  }

  @available(macOS 26, *)
  private static func tables(in input: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [[[String]]] {
    var found: [[[String]]] = []
    if let pdf = PDFDocument(url: input) {
      try SimpleDocProcessor.refuseIfLocked(pdf, named: input.lastPathComponent)
      for index in 0..<pdf.pageCount {
        try Task.checkCancellation()
        if let page = pdf.page(at: index), let image = PageDrawing.image(of: page, dots: dots) { found += try await tables(in: image) }
        progress(Double(index + 1) / Double(pdf.pageCount))
      }
    } else if let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
      found = try await tables(in: image, up: ImageProcessor.orientation(of: source))
    } else {
      throw ProcessingError.conversionFailed(reason: "Cannot open \(input.lastPathComponent)")
    }
    return found
  }

  @available(macOS 26, *)
  private static func tables(in image: CGImage, up: CGImagePropertyOrientation = .up) async throws -> [[[String]]] {
    let seen = try await RecognizeDocumentsRequest().perform(on: image, orientation: up)
    return seen.flatMap { $0.document.tables }.map { table in
      let wide = table.rows.flatMap { $0 }.map { $0.columnRange.upperBound + 1 }.max() ?? 0
      var sheet = [[Cell]](repeating: [Cell](repeating: Cell(), count: wide), count: table.rows.count)
      for (number, row) in table.rows.enumerated() {
        // A cell over several rows is written in the first of them.
        for cell in row where cell.rowRange.lowerBound == number {
          let words = cell.content.text.transcript.replacingOccurrences(of: "\n", with: " ")
          let box = cell.content.boundingRegion.boundingBox.cgRect
          sheet[number][cell.columnRange.lowerBound] = Cell(words: words, box: words.isEmpty ? nil : box, isWhole: cell.columnRange.count == 1 && cell.rowRange.count == 1)
        }
      }
      return lookedAtAgain(sheet, in: image, up: up)
    }
  }

  private struct Cell {
    var words = ""
    var box: CGRect?
    /// Not one that spreads over others.
    var isWhole = true
  }

  /// A figure by itself in a cell is now and then not seen. A cell that came
  /// back empty is read once more on its own, where its row and column cross.
  private static func lookedAtAgain(_ sheet: [[Cell]], in image: CGImage, up: CGImagePropertyOrientation) -> [[String]] {
    let rows = sheet.map { row in row.compactMap(\.box).reduce(CGRect.null) { $0.union($1) } }
    let wide = sheet.first?.count ?? 0
    let columns = (0..<wide).map { index in sheet.compactMap { $0[index].isWhole ? $0[index].box : nil }.reduce(CGRect.null) { $0.union($1) } }
    return sheet.enumerated().map { number, row in
      row.enumerated().map { index, cell in
        guard cell.words.isEmpty, cell.isWhole, !rows[number].isNull, !columns[index].isNull, up == .up else { return cell.words }
        let place = CGRect(x: columns[index].minX, y: rows[number].minY, width: columns[index].width, height: rows[number].height)
        // Short of the lines round it.
        return read(place.insetBy(dx: place.height * 0.08, dy: place.height * 0.08), of: image)
      }
    }
  }

  private static func read(_ place: CGRect, of image: CGImage) -> String {
    let box = CGRect(
      x: place.minX * CGFloat(image.width), y: (1 - place.maxY) * CGFloat(image.height),
      width: place.width * CGFloat(image.width), height: place.height * CGFloat(image.height)
    ).integral
    guard box.height > 4, box.width > 4, let cell = image.cropping(to: box), let ink = ink(in: cell), let piece = cell.cropping(to: ink),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return "" }
    // Larger, with room round it, and three times over: one figure by itself
    // is nothing to whoever reads, and a row of them is a number.
    let scale = 64 / ink.height, gap = 40.0, width = ink.width * scale
    guard width < 8000, let context = CGContext(
      data: nil, width: Int(width * 3 + gap * 4), height: Int(64 + gap * 2), bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return "" }
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    context.interpolationQuality = .high
    for turn in 0..<3 { context.draw(piece, in: CGRect(x: gap + Double(turn) * (width + gap), y: gap, width: width, height: 64)) }
    guard let drawn = context.makeImage() else { return "" }
    let request = VNRecognizeTextRequest()
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: drawn).perform([request])
    let words = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first?.string }.joined()
    let letters = Array(words.filter { !$0.isWhitespace })
    // The same three times, or it was not read.
    guard letters.count % 3 == 0, !letters.isEmpty else { return "" }
    let third = letters.count / 3
    guard letters[..<third] == letters[third..<(2 * third)], letters[..<third] == letters[(2 * third)...] else { return "" }
    return String(letters[..<third])
  }

  /// Where something is written, if anything is: most empty cells are empty.
  private static func ink(in piece: CGImage) -> CGRect? {
    let width = piece.width, height = piece.height
    var bytes = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(
      data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    context.draw(piece, in: CGRect(x: 0, y: 0, width: width, height: height))
    let paper = Int(bytes.sorted()[bytes.count / 2])
    let marked = bytes.indices.filter { abs(Int(bytes[$0]) - paper) > 60 }
    guard marked.count > 4, let top = marked.first.map({ $0 / width }), let bottom = marked.last.map({ $0 / width }),
          let left = marked.map({ $0 % width }).min(), let right = marked.map({ $0 % width }).max(), bottom > top + 2 else { return nil }
    return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
  }
}

/// A page as a picture, as finely as it is asked for.
enum PageDrawing {
  static func image(of page: PDFPage, dots: CGFloat, mostOnASide: CGFloat = 20_000) -> CGImage? {
    let bounds = page.bounds(for: .cropBox), turned = page.rotation % 180 != 0
    let shown = CGSize(width: turned ? bounds.height : bounds.width, height: turned ? bounds.width : bounds.height)
    guard shown.width > 0, shown.height > 0 else { return nil }
    let scale = min(dots / 72, mostOnASide / max(shown.width, shown.height))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
      data: nil, width: max(1, Int((shown.width * scale).rounded())), height: max(1, Int((shown.height * scale).rounded())),
      bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: context)
    return context.makeImage()
  }
}
