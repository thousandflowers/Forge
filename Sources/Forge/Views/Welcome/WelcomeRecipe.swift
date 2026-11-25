import AppKit
import CoreImage

/// A sheet of paper on a table, taken from where somebody was standing, with a
/// lamp on one side of it. Drawn, to be made straight again.
enum WelcomeRecipe {
  private static let size = CGSize(width: 1920, height: 1440)
  private static let paper = CGSize(width: 1000, height: 1400)
  /// Where the corners of the sheet are on the table.
  private static let corners = [
    "inputTopLeft": CGPoint(x: 640, y: 1290), "inputTopRight": CGPoint(x: 1400, y: 1190),
    "inputBottomLeft": CGPoint(x: 360, y: 190), "inputBottomRight": CGPoint(x: 1290, y: 90),
  ]
  private static let shadow = CGSize(width: 14, height: -22)
  private static let title = "Tomato soup", under = "for four, in half an hour"
  private static let lines = [
    "1 kg of ripe tomatoes", "1 onion, 2 cloves of garlic", "a handful of basil", "4 spoons of olive oil", "",
    "Soften the onion in the oil, slowly.", "Add the garlic, then the tomatoes,", "cut up, and a pinch of salt.", "Twenty minutes on a low flame.", "Blend, and tear the basil over it.",
  ]

  static func write(to url: URL) throws {
    guard let sheet = bitmap(paper, drawSheet), let table = bitmap(size, drawTable), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw ProcessingError.conversionFailed(reason: "The sample photo could not be drawn.")
    }
    try CIContext().writeJPEGRepresentation(
      of: photo(of: CIImage(cgImage: sheet), on: CIImage(cgImage: table)), to: url, colorSpace: space,
      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
    )
  }

  private static func photo(of sheet: CIImage, on table: CIImage) -> CIImage {
    let frame = CGRect(origin: .zero, size: size)
    let dark = sheet.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.6),
    ])
    let lamp = CIImage.empty().applyingFilter("CIRadialGradient", parameters: [
      "inputCenter": CIVector(x: 620, y: 1100), "inputRadius0": 200, "inputRadius1": 1700,
      "inputColor0": CIColor(red: 1, green: 0.94, blue: 0.82), "inputColor1": CIColor(red: 0.52, green: 0.47, blue: 0.45),
    ])
    return laid(sheet).composited(over: laid(dark, by: shadow).applyingGaussianBlur(sigma: 16)).composited(over: table).cropped(to: frame)
      .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: lamp.cropped(to: frame)])
      // Not quite sharp, as from a hand.
      .clampedToExtent().applyingGaussianBlur(sigma: 0.8).cropped(to: frame)
  }

  private static func laid(_ image: CIImage, by: CGSize = .zero) -> CIImage {
    image.applyingFilter("CIPerspectiveTransform", parameters: corners.mapValues { CIVector(x: $0.x + by.width, y: $0.y + by.height) })
  }

  private static func bitmap(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(context)
    return context.makeImage()
  }

  private static func drawSheet(_ context: CGContext) {
    context.setFillColor(CGColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1))
    context.fill(CGRect(origin: .zero, size: paper))
    func say(_ text: String, y: CGFloat, _ points: CGFloat, _ face: String) {
      let font = NSFont(name: face, size: points) ?? NSFont.systemFont(ofSize: points)
      (text as NSString).draw(at: NSPoint(x: 114, y: y), withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.16, alpha: 1)])
    }
    say(title, y: 1210, 92, "Baskerville-Bold")
    say(under, y: 1150, 40, "Baskerville-Italic")
    for (index, line) in lines.enumerated() { say(line, y: 1020 - CGFloat(index) * 76, 44, "Baskerville") }
    context.setFillColor(CGColor(gray: 0.2, alpha: 0.5))
    context.fill(CGRect(x: 114, y: 1114, width: 772, height: 3))
  }

  private static func drawTable(_ context: CGContext) {
    let wood = [CGColor(red: 0.42, green: 0.27, blue: 0.17, alpha: 1), CGColor(red: 0.28, green: 0.17, blue: 0.11, alpha: 1)]
    if let gradient = CGGradient(colorsSpace: context.colorSpace, colors: wood as CFArray, locations: [0, 1]) {
      context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
    }
    var chance = WelcomeSamples.Chance(state: 99)
    for _ in 0..<900 {
      let y = size.height * chance.next()
      func near() -> CGFloat { y + 40 * (chance.next() - 0.5) }
      context.setStrokeColor(CGColor(red: 0.1, green: 0.05, blue: 0.02, alpha: 0.04 + 0.12 * chance.next()))
      context.setLineWidth(0.5 + 2 * chance.next())
      context.move(to: CGPoint(x: -20, y: y))
      context.addCurve(to: CGPoint(x: size.width + 20, y: near()), control1: CGPoint(x: size.width * 0.3, y: near()), control2: CGPoint(x: size.width * 0.7, y: near()))
      context.strokePath()
    }
  }
}
