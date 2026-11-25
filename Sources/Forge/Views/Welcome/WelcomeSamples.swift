import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Files to try Forge on, made on the spot: a picture nobody took and a tune
/// nobody wrote, in a folder of their own.
enum WelcomeSamples {
  struct Files: Sendable {
    let folder: URL
    let picture: URL
    let sound: URL
    let letter: URL
  }

  struct Sample: Sendable {
    let kind: PresetCategory
    let name: String
    let from: String
  }

  /// What the three of them are, in the order they are fanned.
  static let each = [
    Sample(kind: .image, name: "First light", from: "png"),
    Sample(kind: .document, name: letter, from: "md"),
    Sample(kind: .audio, name: "Ember", from: "wav"),
  ]

  /// What each can be made into on this Mac, the usual things first: what
  /// Forge would offer for it, asked of Forge.
  static func formats() -> [[String]] {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ForgeTiles-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return each.map { _ in [] } }
    return each.map { sample in
      let url = folder.appendingPathComponent("\(sample.name).\(sample.from)")
      guard FileManager.default.createFile(atPath: url.path, contents: nil), let file = try? ProcessableFile(url: url) else { return [] }
      return AskOptions.choices(for: .format, files: [file]).map { $0.label.lowercased() }
    }
  }

  static let width = 1920, height = 1200
  static let letter = "Letter"

  /// What was there from the last time goes to the Trash: somebody may have put
  /// something of theirs in it.
  static func make(in parent: URL) throws -> Files {
    let folder = parent.appendingPathComponent("Try Forge", isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    let files = Files(folder: folder, picture: file("First light.png"), sound: file("Ember.wav"), letter: file("\(letter).md"))
    try write(picture(), to: files.picture)
    try writeSound(to: files.sound)
    try Data(words.utf8).write(to: files.letter)
    return files
  }

  private static let words = """
    # Hello

    This letter was written in **Markdown**, a plain text anybody can read and \
    few people can print.

    Give it another extension, and it is *really* something else:

    - `.pdf` to send it
    - `.docx` to let somebody change it
    - `.epub` to read it on the sofa

    """

  // MARK: - The picture

  struct Chance {
    var state: UInt64
    mutating func next() -> Double {
      state ^= state << 13; state ^= state >> 7; state ^= state << 17
      return Double(state & 0xFFFFFF) / Double(0xFFFFFF)
    }
  }

  static func picture() throws -> CGImage {
    let w = CGFloat(width), h = CGFloat(height), shore = h * 0.34
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw ProcessingError.conversionFailed(reason: "The sample picture could not be drawn.")
    }
    func color(_ hue: Double, _ saturation: Double, _ brightness: Double, _ alpha: Double = 1) -> CGColor {
      NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: alpha).cgColor
    }
    func gradient(_ colors: [CGColor], _ places: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: places)! }
    var chance = Chance(state: 4_101_842_887_655_102_017)

    let sky = gradient([color(0.07, 0.62, 1), color(0.02, 0.62, 0.92), color(0.88, 0.48, 0.62), color(0.69, 0.55, 0.36), color(0.65, 0.7, 0.16)], [0, 0.18, 0.42, 0.7, 1])
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: shore), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation])
    for _ in 0..<420 {
      let y = h * (0.62 + 0.38 * chance.next()), size = 0.6 + 1.8 * pow(chance.next(), 4)
      context.setFillColor(CGColor(gray: 1, alpha: (0.25 + 0.6 * chance.next()) * (y / h - 0.5) * 2))
      context.fillEllipse(in: CGRect(x: w * chance.next(), y: y, width: size, height: size))
    }
    let sun = CGPoint(x: w * 0.6, y: shore + h * 0.085)
    context.saveGState()
    context.setBlendMode(.plusLighter)
    context.drawRadialGradient(gradient([color(0.1, 0.5, 1, 0.75), color(0.06, 0.8, 1, 0.22), color(0.03, 0.9, 0.8, 0)], [0, 0.3, 1]), startCenter: sun, startRadius: 0, endCenter: sun, endRadius: w * 0.42, options: [])
    context.restoreGState()
    context.setFillColor(color(0.12, 0.2, 1))
    context.fillEllipse(in: CGRect(x: sun.x - 46, y: sun.y - 46, width: 92, height: 92))

    // One range behind another, each nearer and darker.
    for layer in 0..<5 {
      let near = Double(layer) / 4
      let base = shore + h * CGFloat(0.16 - 0.15 * near), rough = h * CGFloat(0.15 - 0.05 * near)
      let phases = (0..<7).map { _ in chance.next() * 100 }
      let path = CGMutablePath()
      path.move(to: CGPoint(x: 0, y: shore - 2))
      for x in stride(from: CGFloat(0), through: w, by: 3) {
        var up = 0.0
        for (octave, phase) in phases.enumerated() {
          let wave = pow(2, Double(octave)) * (1.3 + near)
          up += (1 - abs(sin(Double(x / w) * wave * 2.1 + phase))) * pow(0.5, Double(octave) + 1)
        }
        path.addLine(to: CGPoint(x: x, y: base + rough * CGFloat(up - 0.45)))
      }
      path.addLine(to: CGPoint(x: w, y: shore - 2))
      path.closeSubpath()
      context.saveGState()
      context.addPath(path)
      context.clip()
      context.drawLinearGradient(
        gradient([color(0.97 - 0.28 * near, 0.4 + 0.15 * near, 0.62 - 0.5 * near), color(0.78 - 0.1 * near, 0.5, 0.42 - 0.34 * near)], [0, 1]),
        start: CGPoint(x: 0, y: base - rough * 0.4), end: CGPoint(x: 0, y: base + rough), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
      )
      context.restoreGState()
      context.drawLinearGradient(gradient([color(0.05, 0.5, 1, 0.16 * (1 - near)), color(0.05, 0.5, 1, 0)], [0, 1]), start: CGPoint(x: 0, y: shore), end: CGPoint(x: 0, y: base + rough * 0.4), options: [])
    }
    for _ in 0..<9 {
      let at = CGPoint(x: w * (0.22 + 0.26 * chance.next()), y: h * (0.66 + 0.12 * chance.next())), span = 9 + 9 * chance.next()
      context.setStrokeColor(color(0.7, 0.5, 0.12, 0.85))
      context.setLineWidth(2.2)
      context.setLineCap(.round)
      context.move(to: CGPoint(x: at.x - span, y: at.y + span * 0.4))
      context.addQuadCurve(to: at, control: CGPoint(x: at.x - span * 0.4, y: at.y + span * 0.55))
      context.addQuadCurve(to: CGPoint(x: at.x + span, y: at.y + span * 0.4), control: CGPoint(x: at.x + span * 0.4, y: at.y + span * 0.55))
      context.strokePath()
    }

    // The water: what is above it, upside down, rippled and darker, and the
    // grain every camera leaves.
    guard let data = context.data else { throw ProcessingError.conversionFailed(reason: "The sample picture could not be drawn.") }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    let line = height - Int(shore)
    var seed: UInt32 = 2_463_534_242
    for y in 0..<height {
      let depth = y - line
      for x in 0..<width {
        let here = (y * width + x) * 4
        if depth >= 0 {
          let far = Double(depth)
          let sway = sin(far * 0.42 + sin(Double(x) * 0.012) * 2.2) * (1 + far * 0.028)
          let fromX = min(max(x + Int(sway * 2.4), 0), width - 1)
          let fromY = max(0, line - 1 - Int(far * 1.18 + sin(far * 0.9 + Double(x) * 0.02) * 2))
          let source = (fromY * width + fromX) * 4
          let dim = max(0.34, 0.86 - far / 620)
          pixels[here] = UInt8(Double(pixels[source]) * dim)
          pixels[here + 1] = UInt8(Double(pixels[source + 1]) * dim * 0.97)
          pixels[here + 2] = UInt8(min(255, Double(pixels[source + 2]) * dim + 10))
        }
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        let grain = Int(seed % 13) - 6
        for channel in 0..<3 { pixels[here + channel] = UInt8(min(255, max(0, Int(pixels[here + channel]) + grain))) }
      }
    }
    guard let image = context.makeImage() else { throw ProcessingError.conversionFailed(reason: "The sample picture could not be drawn.") }
    return image
  }

  private static func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw ProcessingError.conversionFailed(reason: "The sample picture could not be written.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ProcessingError.conversionFailed(reason: "The sample picture could not be written.") }
  }

  // MARK: - The tune

  static func writeSound(to url: URL) throws {
    let rate = WelcomeScore.rate
    let buffer = WelcomeScore.buffer(seconds: WelcomeTune.seconds) { count, left, right in
      WelcomeTune.play(into: left, right, count: count, rate: rate)
    }
    guard let buffer else { throw ProcessingError.conversionFailed(reason: "The sample sound could not be made.") }
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ])
    try file.write(from: buffer)
  }

  static func seconds(of url: URL) -> Double {
    (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
  }

  /// How loud it is from end to end, to be drawn.
  static func shape(of url: URL, bars: Int) -> [Double] {
    guard let file = try? AVAudioFile(forReading: url), file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else { return [] }
    let count = Int(buffer.frameLength), each = max(1, count / bars)
    let levels = (0..<bars).map { bar -> Double in
      let from = bar * each
      guard from < count else { return 0 }
      var most: Float = 0
      for index in stride(from: from, to: min(count, from + each), by: 4) { most = max(most, abs(samples[index])) }
      return Double(most)
    }
    let top = max(levels.max() ?? 1, 0.0001)
    return levels.map { $0 / top }
  }
}
