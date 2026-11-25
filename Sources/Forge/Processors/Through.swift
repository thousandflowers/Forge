import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The files that are opened by being made into something else first: what is
/// in a slide show is pages, and what is in an Illustrator file is a PDF.
final class ThroughProcessor: FileProcessor, @unchecked Sendable {
  let name = "Through"

  struct Way: Sendable {
    let extensions: Set<String>
    let kind: ConvertKind
    /// What it is made into, by extension, and how.
    let middle: String
    let make: @Sendable (_ input: URL, _ output: URL) async throws -> Void
  }

  static let ways: [Way] = [
    Way(extensions: ["ppt", "pps", "pot", "pptx", "pptm", "ppsx", "ppsm", "potx", "potm"], kind: .document, middle: "pdf") { try await Drawn.office($0, to: $1) },
    Way(extensions: ["xls", "xlt", "xlsx", "xlsm", "xltx", "xltm"], kind: .data, middle: "pdf") { try await Drawn.office($0, to: $1) },
    Way(extensions: ["ai"], kind: .document, middle: "pdf") { try Adobe.illustrator($0, to: $1) },
    Way(extensions: ["idml", "icml"], kind: .document, middle: "html") { try Adobe.story($0, to: $1) },
    Way(extensions: ["eps", "epsf", "ps"], kind: .document, middle: "pdf") { try Adobe.postScript($0, to: $1) },
    Way(extensions: ["indd", "indt", "xd"], kind: .image, middle: "png") { try Adobe.preview($0, to: $1) },
    Way(extensions: ["psb"], kind: .image, middle: "png") { try Adobe.largePicture($0, to: $1) },
    Way(extensions: ["pcx"], kind: .image, middle: "png") { try OldPictures.pcx($0, to: $1) },
    Way(extensions: ["msg"], kind: .document, middle: "txt") { try Msg.text(of: $0).write(to: $1, atomically: true, encoding: .utf8) },
    Way(extensions: ["emlx"], kind: .document, middle: "eml") { input, output in
      // The length of the message on a line of its own, and what Mail notes after it.
      let data = try Data(contentsOf: input)
      guard let line = data.firstIndex(of: 0x0A), let length = Int(String(decoding: data[..<line], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
            length >= 0, length <= data.count - line - 1 else { throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) is not a message") }
      try data.subdata(in: (line + 1)..<(line + 1 + length)).write(to: output)
    },
    Way(extensions: ["dxf"], kind: .image, middle: "pdf") { try Dxf.read($0).pdf(to: $1) },
  ]

  static let extensions = ways.reduce(into: Set<String>()) { $0.formUnion($1.extensions) }

  static func way(for type: UTType) -> Way? { ways.first { type.goes(by: $0.extensions) } }
  private static func way(for url: URL) -> Way? { ways.first { $0.extensions.contains(url.pathExtension.lowercased()) } }

  private let after: [FileProcessor] = [ImageProcessor(), SlidesProcessor(), SimpleDocProcessor(), ExternalProcessor()]

  func canProcess(_ file: ProcessableFile) -> Bool { Self.way(for: file.url) != nil }

  private static func stand(in middle: String) -> ProcessableFile {
    ProcessableFile(url: URL(fileURLWithPath: "/a.\(middle)"), fileType: UTType(filenameExtension: middle) ?? .data, fileName: "a.\(middle)", fileSize: 1, dimensions: nil)
  }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    guard let way = Self.way(for: file.url) else { return false }
    let wanted = Conversions.fileExtension(of: target), source = file.url.pathExtension.lowercased()
    if source == "dxf", wanted == "svg" { return true }
    // A slide show as a slide show of pictures of itself is nothing anybody wants.
    if wanted == source || (wanted == "pptx" && way.extensions.contains("pptx")) { return false }
    // Pictures of a preview: not words out of it.
    if way.kind == .data, wanted != "pdf", !FormatCatalog.isWritableImage(target) { return false }
    if wanted == way.middle { return true }
    let stand = Self.stand(in: way.middle)
    return after.contains { $0.canProcess(stand) && $0.takes(stand, to: target) }
  }

  func process(
    _ input: URL, to output: URL, with operations: [Operation], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    guard let way = Self.way(for: input) else { throw ProcessingError.unknownType }
    let wanted = output.pathExtension.lowercased()
    if input.pathExtension.lowercased() == "dxf", wanted == "svg" {
      try Dxf.read(input).svg().write(to: output, atomically: true, encoding: .utf8)
      return try Self.result(output, start)
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("forge-through-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let middle = folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(way.middle)
    try await way.make(input, middle)
    progress(0.5)
    let stand = Self.stand(in: way.middle)
    let target = FormatCatalog.type(named: wanted) ?? UTType(filenameExtension: wanted) ?? .data
    // A processor that hands a pair on says so by refusing it, as elsewhere.
    var refusal: Error = ProcessingError.unsupportedConversion(from: UTType(filenameExtension: input.pathExtension) ?? .data, to: target)
    for processor in after where processor.canProcess(stand) && (processor.takes(stand, to: target)) {
      do {
        let made = try await processor.process(middle, to: output, with: operations) { progress(0.5 + $0 / 2) }
        return ProcessingResult(
          outputURL: made.outputURL, outputSize: made.outputSize, outputDimensions: made.outputDimensions,
          duration: Date().timeIntervalSince(start), additionalOutputs: made.additionalOutputs, appliedQuality: made.appliedQuality
        )
      } catch let error as ProcessingError {
        guard case .unsupportedConversion = error else { throw error }
        refusal = error
      }
    }
    if wanted == way.middle {
      try FileManager.default.copyItem(at: middle, to: output)
      return try Self.result(output, start)
    }
    throw refusal
  }

  private static func result(_ output: URL, _ start: Date) throws -> ProcessingResult {
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    return ProcessingResult(outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start))
  }
}

/// Pages as slides: each the picture of itself, at its own shape.
final class SlidesProcessor: FileProcessor, @unchecked Sendable {
  let name = "Slides Processor"

  func canProcess(_ file: ProcessableFile) -> Bool { file.fileType.conforms(to: .pdf) || FormatCatalog.isReadableImage(file.fileType) }
  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    // A drawing is not decoded, it is drawn: that is not done here.
    Conversions.fileExtension(of: target) == "pptx" && file.fileType != .svg
  }

  private static let longest: CGFloat = 2400

  func process(
    _ input: URL, to output: URL, with operations: [Operation], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    // A processor that reads a file is asked for any format, and hands on what is not its own.
    guard output.pathExtension.lowercased() == "pptx" else {
      throw ProcessingError.unsupportedConversion(from: UTType(filenameExtension: input.pathExtension) ?? .data, to: UTType(filenameExtension: output.pathExtension) ?? .data)
    }
    let start = Date()
    var pictures: [(data: Data, size: CGSize)] = []
    if input.pathExtension.lowercased() == "pdf" {
      guard let pdf = PDFDocument(url: input) else { throw ProcessingError.conversionFailed(reason: "Cannot open \(input.lastPathComponent)") }
      try SimpleDocProcessor.refuseIfLocked(pdf, named: input.lastPathComponent)
      for index in 0..<pdf.pageCount {
        try Task.checkCancellation()
        guard let page = pdf.page(at: index) else { continue }
        let box = page.bounds(for: .cropBox), turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = Self.longest / max(size.width, size.height, 1)
        let drawn = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        guard let tiff = drawn.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { continue }
        pictures.append((data, size))
        progress(Double(index + 1) / Double(pdf.pageCount) * 0.9)
      }
    } else {
      guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: Self.longest,
      ] as CFDictionary), let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
        throw ProcessingError.conversionFailed(reason: "Cannot read \(input.lastPathComponent)")
      }
      pictures = [(data, CGSize(width: image.width, height: image.height))]
    }
    guard let first = pictures.first else { throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no pages") }
    try Self.deck(pictures.map(\.data), sizes: pictures.map(\.size), like: first.size).write(to: output, options: .atomic)
    progress(1)
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    return ProcessingResult(outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start))
  }

  private static func deck(_ pictures: [Data], sizes: [CGSize], like size: CGSize) -> Data {
    let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n", main = "http://schemas.openxmlformats.org/"
    let spaces = #"xmlns:a="\#(main)drawingml/2006/main" xmlns:r="\#(main)officeDocument/2006/relationships" xmlns:p="\#(main)presentationml/2006/main""#
    // Ten inches along its longer side.
    let unit = 9_144_000 / max(size.width, size.height), width = Int(size.width * unit), height = Int(size.height * unit)
    func links(_ all: [(String, String, String)]) -> String {
      head + #"<Relationships xmlns="\#(main)package/2006/relationships">"# + all.map { #"<Relationship Id="\#($0.0)" Type="\#(main)officeDocument/2006/relationships/\#($0.1)" Target="\#($0.2)"/>"# }.joined() + "</Relationships>"
    }
    let empty = #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#
    let kind = "application/vnd.openxmlformats-officedocument.", numbers = pictures.indices.map { $0 + 1 }
    let slides = numbers.map { number -> String in
      // Within the slide, whole, in the middle.
      let own = sizes[number - 1], scale = min(CGFloat(width) / own.width, CGFloat(height) / own.height)
      let w = Int(own.width * scale), h = Int(own.height * scale)
      return head + #"<p:sld \#(spaces)><p:cSld><p:spTree>\#(empty)<p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \#(number)"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\#((width - w) / 2)" y="\#((height - h) / 2)"/><a:ext cx="\#(w)" cy="\#(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#
    }
    let colours = ["dk1": "000000", "lt1": "FFFFFF", "dk2": "1F1F1F", "lt2": "EEEEEE", "accent1": "4472C4", "accent2": "ED7D31", "accent3": "A5A5A5", "accent4": "FFC000", "accent5": "5B9BD5", "accent6": "70AD47", "hlink": "0563C1", "folHlink": "954F72"]
    let order = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]
    let fill = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#, font = #"<a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/>"#
    let theme = head + #"<a:theme xmlns:a="\#(main)drawingml/2006/main" name="Forge"><a:themeElements><a:clrScheme name="Forge">"#
      + order.map { #"<a:\#($0)><a:srgbClr val="\#(colours[$0]!)"/></a:\#($0)>"# }.joined()
      + #"</a:clrScheme><a:fontScheme name="Forge"><a:majorFont>\#(font)</a:majorFont><a:minorFont>\#(font)</a:minorFont></a:fontScheme><a:fmtScheme name="Forge"><a:fillStyleLst>\#(fill)\#(fill)\#(fill)</a:fillStyleLst><a:lnStyleLst>"#
      + String(repeating: "<a:ln>\(fill)</a:ln>", count: 3) + "</a:lnStyleLst><a:effectStyleLst>" + String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3)
      + "</a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
    let map = #"<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>"#
    var files: [(String, String)] = [
      ("[Content_Types].xml", head + #"<Types xmlns="\#(main)package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/ppt/presentation.xml" ContentType="\#(kind)presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="\#(kind)presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="\#(kind)presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="\#(kind)theme+xml"/>"#
        + numbers.map { #"<Override PartName="/ppt/slides/slide\#($0).xml" ContentType="\#(kind)presentationml.slide+xml"/>"# }.joined() + "</Types>"),
      ("_rels/.rels", links([("rId1", "officeDocument", "ppt/presentation.xml")])),
      ("ppt/presentation.xml", head + #"<p:presentation \#(spaces)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>"#
        + numbers.map { #"<p:sldId id="\#(255 + $0)" r:id="rId\#($0 + 1)"/>"# }.joined() + #"</p:sldIdLst><p:sldSz cx="\#(width)" cy="\#(height)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#),
      ("ppt/_rels/presentation.xml.rels", links([("rId1", "slideMaster", "slideMasters/slideMaster1.xml")] + numbers.map { ("rId\($0 + 1)", "slide", "slides/slide\($0).xml") })),
      ("ppt/slideMasters/slideMaster1.xml", head + #"<p:sldMaster \#(spaces)><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\#(empty)</p:spTree></p:cSld>\#(map)<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>"#),
      ("ppt/slideMasters/_rels/slideMaster1.xml.rels", links([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")])),
      ("ppt/slideLayouts/slideLayout1.xml", head + #"<p:sldLayout \#(spaces) type="blank"><p:cSld name="Blank"><p:spTree>\#(empty)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#),
      ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", links([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")])),
      ("ppt/theme/theme1.xml", theme),
    ]
    for number in numbers {
      files.append(("ppt/slides/slide\(number).xml", slides[number - 1]))
      files.append(("ppt/slides/_rels/slide\(number).xml.rels", links([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "image", "../media/image\(number).jpg")])))
    }
    return Zip.data(files.map { Zip.Entry(name: $0.0, data: Data($0.1.utf8)) } + numbers.map { Zip.Entry(name: "ppt/media/image\($0).jpg", data: pictures[$0 - 1], isStored: true) })
  }
}
