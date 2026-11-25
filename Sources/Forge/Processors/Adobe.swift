import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What can be had out of Adobe's files without Adobe: the PDF in an
/// Illustrator file, the words in an IDML, the whole of a large Photoshop
/// picture, and the preview in the rest.
enum Adobe {
  static func illustrator(_ input: URL, to output: URL) throws {
    let data = try Data(contentsOf: input, options: .mappedIfSafe)
    let isEmpty = PDFDocument(data: data).map(isOnlyANotice) ?? true
    guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil, !isEmpty else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) was saved without a PDF in it. In Illustrator, save it again with “Create PDF Compatible File”.")
    }
    try data.write(to: output)
  }

  /// Saved without its PDF, there is one all the same: a page that says so, in
  /// whatever language, over and over.
  private static func isOnlyANotice(_ pdf: PDFDocument) -> Bool {
    guard pdf.pageCount == 1, let words = pdf.page(at: 0)?.string, words.contains("Illustrator"), words.contains("PDF") else { return false }
    let lines = words.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    return Set(lines).count * 3 <= lines.count
  }

  /// PostScript is a program, and macOS no longer runs it. Ghostscript does,
  /// where it is; otherwise there is the picture some carry of themselves.
  static func postScript(_ input: URL, to output: URL) throws {
    if try Data(contentsOf: input, options: .mappedIfSafe).prefix(1024).range(of: Data("%PDF-".utf8)) != nil { return try illustrator(input, to: output) }
    let begins = try Data(contentsOf: input, options: .mappedIfSafe).prefix(1024)
    guard begins.range(of: Data("%!".utf8)) != nil || begins.prefix(4) == Data([0xC5, 0xD0, 0xD3, 0xC6]) else { throw Ole.broken }
    if let gs = ExternalTools.locate("gs") {
      try ExternalTools.run(gs, ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-q", "-dEPSCrop", "-sDEVICE=pdfwrite", "-sOutputFile=\(output.path.replacingOccurrences(of: "%", with: "%%"))", "-f", input.path])
      // A program that draws nothing ends well all the same.
      guard let made = PDFDocument(url: output), made.pageCount > 0, made.page(at: 0).map({ $0.bounds(for: .mediaBox).width > 1 }) ?? false else { throw Ole.broken }
      return
    }
    let picture = output.deletingPathExtension().appendingPathExtension("png")
    try preview(input, to: picture)
    let pdf = PDFDocument()
    guard let image = NSImage(contentsOf: picture), let page = PDFPage(image: image) else { throw Ole.broken }
    pdf.insert(page, at: 0)
    guard pdf.write(to: output) else { throw Ole.broken }
  }

  // MARK: - IDML

  static func story(_ input: URL, to output: URL) throws {
    var stories: [Data] = []
    if input.pathExtension.lowercased() == "icml" {
      stories = [try Data(contentsOf: input)]
    } else {
      let zip = try Zip.Reader(input)
      // In the order the document puts them in.
      let map = try zip.text("designmap.xml"), listed = map.matches(of: #/src="(Stories\/[^"]+)"/#).map { String($0.1) }
      stories = try listed.filter(zip.has).map(zip.data)
    }
    let words = try stories.map(paragraphs).filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }
    guard !words.isEmpty else { throw ProcessingError.conversionFailed(reason: "There are no words in \(input.lastPathComponent).") }
    try Data("<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(words.joined(separator: "\n<hr>\n"))</body></html>".utf8).write(to: output)
  }

  private static func paragraphs(_ story: Data) throws -> [String] {
    guard let root = try? XMLDocument(data: story, options: [.nodeLoadExternalEntitiesNever]).rootElement() else { throw Zip.Reader.broken }
    var all: [String] = [], now = ""
    func walk(_ element: XMLElement, _ style: String, _ face: String) {
      switch element.localName {
      case "Content":
        var said = DataFormats.escaped(element.stringValue ?? "")
        if face.contains("Bold") { said = "<b>\(said)</b>" }
        if face.contains("Italic") || face.contains("Oblique") { said = "<i>\(said)</i>" }
        now += said
      case "Br": end(style)
      default:
        let style = element.localName == "ParagraphStyleRange" ? element.attribute(forName: "AppliedParagraphStyle")?.stringValue ?? "" : style
        let face = element.localName == "CharacterStyleRange" ? element.attribute(forName: "FontStyle")?.stringValue ?? "" : face
        for child in element.children ?? [] { if let child = child as? XMLElement { walk(child, style, face) } }
      }
    }
    func end(_ style: String) {
      let tag = style.lowercased().contains("title") || style.lowercased().contains("heading") ? "h2" : "p"
      if !now.isEmpty { all.append("<\(tag)>\(now)</\(tag)>") }
      now = ""
    }
    walk(root, "", "")
    end("")
    return all
  }

  // MARK: - Previews

  /// The picture a file carries of itself: the largest, where there are several.
  static func preview(_ input: URL, to output: URL) throws {
    let data = try Data(contentsOf: input, options: .mappedIfSafe)
    var found: [Data] = []
    if data.prefix(4) == Data([0xC5, 0xD0, 0xD3, 0xC6]) {
      let start = data.number(4, at: 20), length = data.number(4, at: 24)
      if length > 0, start + length <= data.count { found.append(data.subdata(in: start..<(start + length))) }
    }
    if let zip = try? Zip.Reader(data) {
      found += zip.names.filter { $0.lowercased().hasSuffix("preview.png") || $0.lowercased().hasSuffix("thumbnail.png") || $0.lowercased().hasSuffix("preview.jpg") }.compactMap { try? zip.data($0) }
    }
    let open = Data("<xmpGImg:image>".utf8), close = Data("</xmpGImg:image>".utf8)
    var at = data.startIndex
    while found.count < 200, let from = data.range(of: open, in: at..<data.endIndex), let to = data.range(of: close, in: from.upperBound..<data.endIndex) {
      let text = String(decoding: data[from.upperBound..<to.lowerBound], as: UTF8.self).replacingOccurrences(of: "&#xA;", with: "").filter { !$0.isWhitespace }
      if let picture = Data(base64Encoded: text) { found.append(picture) }
      at = to.upperBound
    }
    if found.isEmpty, data.prefix(2) == Data("%!".utf8), let drawn = hexPreview(data) { return try write(drawn, to: output) }
    let pictures = found.compactMap { CGImageSourceCreateWithData($0 as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
    guard let best = pictures.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) carries no preview, and only the app that made it can draw it.")
    }
    try write(best, to: output)
  }

  /// The grey picture some PostScript has in its comments, for a printer's screen.
  private static func hexPreview(_ data: Data) -> CGImage? {
    let text = String(decoding: data.prefix(4 << 20), as: UTF8.self)
    guard let head = text.firstMatch(of: #/%%BeginPreview:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/#), let width = Int(head.1), let height = Int(head.2), let depth = Int(head.3),
          depth == 8, (1...8192).contains(width), (1...8192).contains(height), let end = text[head.range.upperBound...].range(of: "%%EndPreview") else { return nil }
    let digits = text[head.range.upperBound..<end.lowerBound].compactMap(\.hexDigitValue)
    guard digits.count >= width * height * 2 else { return nil }
    let pixels = (0..<(width * height)).map { UInt8(255 - (digits[2 * $0] << 4 | digits[2 * $0 + 1])) }
    return CGDataProvider(data: Data(pixels) as CFData).flatMap {
      CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
  }

  static func write(_ image: CGImage, to output: URL) throws {
    guard let sink = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Ole.broken }
    CGImageDestinationAddImage(sink, image, nil)
    guard CGImageDestinationFinalize(sink) else { throw Ole.broken }
  }

  // MARK: - A large Photoshop picture

  /// The picture as it looks, with everything in it: what is at the end of the
  /// file, after all it is made of.
  static func largePicture(_ input: URL, to output: URL) throws {
    let data = try Data(contentsOf: input, options: .mappedIfSafe)
    let channels = data.big(2, at: 12), height = data.big(4, at: 14), width = data.big(4, at: 18), depth = data.big(2, at: 22), mode = data.big(2, at: 24)
    let colours = [1: 1, 3: 3, 4: 4][mode] ?? 0
    guard data.prefix(4) == Data("8BPS".utf8), data.big(2, at: 4) == 2, colours > 0, channels >= colours, depth == 8 || depth == 16,
          width > 0, height > 0, width * height <= 400_000_000 else {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) is in a kind of PSB Forge does not read: 8 or 16 bits, in RGB, CMYK or gray.")
    }
    var at = 26
    for size in [4, 4, 8] {
      let length = data.big(size, at: at)
      at += size
      guard length >= 0, at <= data.count, length <= data.count - at else { throw Ole.broken }
      at += length
    }
    let kind = data.big(2, at: at), wide = depth / 8, used = min(channels, colours + (mode == 3 && channels > 3 ? 1 : 0))
    at += 2
    guard kind == 0 || kind == 1, at < data.count else { throw Ole.broken }
    // A plane at a time, and the top byte of each number is enough to look at.
    var planes = [[UInt8]](repeating: [], count: used)
    let row = width * wide
    var starts = at + (kind == 1 ? channels * height * 4 : 0)
    for channel in 0..<used {
      var plane = [UInt8](repeating: 0, count: width * height)
      for y in 0..<height {
        if y % 256 == 0 { try Task.checkCancellation() }
        if kind == 0 {
          guard starts + row <= data.count else { throw Ole.broken }
          for x in 0..<width { plane[y * width + x] = data[data.startIndex + starts + x * wide] }
          starts += row
          continue
        }
        let length = data.big(4, at: at + (channel * height + y) * 4), end = starts + length
        guard length >= 0, end <= data.count else { throw Ole.broken }
        var from = starts, to = 0
        while from < end, to < row {
          let count = Int(Int8(bitPattern: data[data.startIndex + from]))
          from += 1
          if count >= 0 {
            for _ in 0...count where from < end && to < row {
              if to % wide == 0 { plane[y * width + to / wide] = data[data.startIndex + from] }
              from += 1; to += 1
            }
          } else if count > -128, from < end {
            let value = data[data.startIndex + from]
            from += 1
            for _ in 0..<(1 - count) where to < row { if to % wide == 0 { plane[y * width + to / wide] = value }; to += 1 }
          }
        }
        starts = end
      }
      planes[channel] = plane
    }
    var pixels = [UInt8](repeating: 0, count: width * height * used)
    for (channel, plane) in planes.enumerated() { for index in plane.indices { pixels[index * used + channel] = plane[index] } }
    if mode == 4 { for index in pixels.indices { pixels[index] = 255 - pixels[index] } }
    let space = mode == 1 ? CGColorSpaceCreateDeviceGray() : mode == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpace(name: CGColorSpace.sRGB)!
    let info: CGBitmapInfo = used == colours + 1 ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue) : []
    guard let provider = CGDataProvider(data: Data(pixels) as CFData), let image = CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * used, bytesPerRow: width * used, space: space, bitmapInfo: info,
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ) else { throw Ole.broken }
    if mode != 4 { return try write(image, to: output) }
    // A PNG is red, green and blue.
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Ole.broken }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let seen = context.makeImage() else { throw Ole.broken }
    try write(seen, to: output)
  }
}

enum OldPictures {
  /// PC Paintbrush.
  static func pcx(_ input: URL, to output: URL) throws {
    let data = try Data(contentsOf: input)
    let depth = data.number(1, at: 3), planes = data.number(1, at: 65), line = data.number(2, at: 66)
    let width = data.number(2, at: 8) - data.number(2, at: 4) + 1, height = data.number(2, at: 10) - data.number(2, at: 6) + 1
    guard data.count > 128, data.number(1, at: 0) == 10, (1...16_384).contains(width), (1...16_384).contains(height), line > 0,
          (depth == 8 && (planes == 1 || planes == 3)) || (depth == 1 && (1...4).contains(planes)),
          line >= (depth == 8 ? width : (width + 7) / 8) else { throw Ole.broken }
    var raw: [UInt8] = [], at = 128
    let wanted = line * planes * height
    while raw.count < wanted, at < data.count {
      let byte = data[at]
      at += 1
      if data[2] == 1, byte & 0xC0 == 0xC0, at < data.count {
        raw += [UInt8](repeating: data[at], count: Int(byte & 0x3F))
        at += 1
      } else { raw.append(byte) }
    }
    guard raw.count >= wanted else { throw Ole.broken }
    let table = data.count > 769 && data[data.count - 769] == 12 ? data.count - 768 : 16
    guard planes == 3 || table + (depth == 8 ? 768 : 48) <= data.count else { throw Ole.broken }
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let start = y * line * planes, to = (y * width + x) * 4
        if depth == 8, planes == 3 {
          for part in 0..<3 { pixels[to + part] = raw[start + part * line + x] }
        } else {
          let index = depth == 8 ? Int(raw[start + x]) : (0..<planes).reduce(0) { $0 | Int(raw[start + $1 * line + x / 8] >> UInt8(7 - x % 8) & 1) << $1 }
          let isBlackAndWhite = depth == 1 && planes == 1
          for part in 0..<3 { pixels[to + part] = isBlackAndWhite ? UInt8(index * 255) : data[table + index * 3 + part] }
        }
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData), let image = CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ) else { throw Ole.broken }
    try Adobe.write(image, to: output)
  }
}
