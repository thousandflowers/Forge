import CoreImage
import Foundation
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers
import Vision

/// Looks for what somebody might want covered, and claims nothing about having
/// found all of it.
///
/// On device, with the frameworks already here: Vision reads faces and text,
/// Natural Language reads that text for names, places and organisations.
/// Nothing leaves the machine and no model is downloaded.
actor RedactionScout {

  /// What might be worth covering in this image.
  ///
  /// Ordered the way a person reads down a list: faces first, then text that
  /// looks like somebody's name, then the rest of the text.
  func candidates(in url: URL) async throws -> [RedactionCandidate] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot read \(url.lastPathComponent)")
    }

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let faces = VNDetectFaceRectanglesRequest()
    let words = VNRecognizeTextRequest()
    words.recognitionLevel = .accurate
    words.usesLanguageCorrection = true

    try handler.perform([faces, words])

    var found: [RedactionCandidate] = (faces.results ?? []).map {
      RedactionCandidate(rect: $0.boundingBox, kind: .face, confidence: $0.confidence)
    }

    var named: [RedactionCandidate] = []
    var plain: [RedactionCandidate] = []
    for observation in words.results ?? [] {
      guard let reading = observation.topCandidates(1).first else { continue }
      let candidate = RedactionCandidate(
        rect: observation.boundingBox,
        kind: Self.entity(in: reading.string).map { RedactionCandidate.Kind.name($0) } ?? .text,
        confidence: reading.confidence,
        text: reading.string
      )
      if case .name = candidate.kind { named.append(candidate) } else { plain.append(candidate) }
    }

    found.append(contentsOf: named)
    found.append(contentsOf: plain)
    return found
  }

  /// What Natural Language makes of a line of text, if it makes anything of it.
  ///
  /// A name, a place or an organisation is worth putting near the top of the
  /// list. Everything else is text, which is worth listing and not worth
  /// calling private.
  nonisolated static func entity(in text: String) -> String? {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text

    var found: String?
    tagger.enumerateTags(
      in: text.startIndex..<text.endIndex,
      unit: .word,
      scheme: .nameType,
      options: [.omitWhitespace, .omitPunctuation, .joinNames]
    ) { tag, _ in
      switch tag {
      case .personalName: found = "Name"
      case .placeName: found = "Place"
      case .organizationName: found = "Organisation"
      default: return true
      }
      return false
    }
    return found
  }
}

/// Covers what a person confirmed, permanently, in a new file.
///
/// Takes regions rather than a session on purpose: there is no argument this
/// type can be handed that means "whatever the detector thought". What gets
/// covered is what somebody ticked.
enum Redactor {

  /// Burn the regions into a copy.
  ///
  /// - Parameters:
  ///   - regions: normalised, bottom-left origin, as Vision reports them.
  ///   - output: written through a scratch file beside it and moved into place,
  ///     so a failure leaves nothing half-written and the source is untouched.
  static func apply(
    _ regions: [CGRect],
    style: RedactionStyle,
    to input: URL,
    writing output: URL
  ) throws {
    guard !regions.isEmpty else {
      throw ProcessingError.validationFailed(
        message: "Nothing has been confirmed to cover, so nothing was written."
      )
    }
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ProcessingError.conversionFailed(reason: "Cannot read \(input.lastPathComponent)")
    }

    let width = image.width
    let height = image.height
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw ProcessingError.conversionFailed(reason: "Cannot draw \(input.lastPathComponent)")
    }

    let whole = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(image, in: whole)

    let pixels = regions.map { region in
      CGRect(
        x: region.origin.x * CGFloat(width),
        y: region.origin.y * CGFloat(height),
        width: region.width * CGFloat(width),
        height: region.height * CGFloat(height)
      ).integral.intersection(whole)
    }.filter { !$0.isEmpty }

    switch style {
    case .blackout:
      context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      context.fill(pixels)

    case .pixellate:
      let ci = CIContext(options: [.cacheIntermediates: false])
      let full = CIImage(cgImage: image)
      for region in pixels {
        guard let coarse = pixellate(full, in: region, using: ci) else {
          // A region Core Image will not pixellate is covered instead of left
          // showing: failing closed is the only safe direction here.
          context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
          context.fill(region)
          continue
        }
        context.draw(coarse, in: region)
      }
    }

    guard let redacted = context.makeImage() else {
      throw ProcessingError.conversionFailed(reason: "Cannot finish \(input.lastPathComponent)")
    }

    // The same discipline as every other write in Forge: scratch first, then
    // one move.
    let type = UTType(filenameExtension: output.pathExtension) ?? .png
    let scratch = output.deletingLastPathComponent()
      .appendingPathComponent(".forge-\(UUID().uuidString).\(output.pathExtension)")
    var wrote = false
    defer { if !wrote { try? FileManager.default.removeItem(at: scratch) } }

    guard let destination = CGImageDestinationCreateWithURL(
      scratch as CFURL, type.identifier as CFString, 1, nil
    ) else {
      throw ProcessingError.conversionFailed(reason: "Cannot write \(output.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, redacted, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ProcessingError.conversionFailed(reason: "Cannot write \(output.lastPathComponent)")
    }

    if FileManager.default.fileExists(atPath: output.path) {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: scratch)
    } else {
      try FileManager.default.moveItem(at: scratch, to: output)
    }
    wrote = true
  }

  /// One region, made coarse enough that what was in it is gone.
  private static func pixellate(_ image: CIImage, in region: CGRect, using ci: CIContext) -> CGImage? {
    let scale = max(region.width, region.height) / 12
    let filter = CIFilter(name: "CIPixellate", parameters: [
      kCIInputImageKey: image,
      kCIInputScaleKey: max(scale, 4),
      kCIInputCenterKey: CIVector(x: region.midX, y: region.midY),
    ])
    guard let output = filter?.outputImage else { return nil }
    return ci.createCGImage(output, from: region)
  }
}
