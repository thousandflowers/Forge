import AppKit
import AVFoundation
import CoreImage

/// Words drawn into the picture, where nobody can turn them off and every
/// player shows them.
///
/// Drawn onto each picture as it goes by. Core Animation is the shorter way of
/// saying it, and what came out of that was white from beginning to end.
enum BurnedSubtitles {
  static func write(_ cues: [Subtitles.Cue], over film: URL, to output: URL, privacy: PrivacyPolicy) async throws {
    let asset = AVURLAsset(url: film)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
      throw ProcessingError.conversionFailed(reason: "\(film.lastPathComponent) cannot be opened by macOS. Convert it to MP4 first.")
    }
    let shown = CGRect(origin: .zero, size: try await track.load(.naturalSize)).applying(try await track.load(.preferredTransform))
    let words = Words(cues, in: CGSize(width: abs(shown.width), height: abs(shown.height)))
    let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
      let picture = request.sourceImage
      let said = words.said(at: request.compositionTime.seconds)
      let made = said.reduce(picture) { $1.composited(over: $0) }.cropped(to: picture.extent)
      request.finish(with: made, context: nil)
    }
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
      throw ProcessingError.conversionFailed(reason: "The film cannot be written")
    }
    session.videoComposition = composition
    session.outputURL = output
    session.outputFileType = output.pathExtension.lowercased() == "mov" ? .mov : .mp4
    session.metadata = PrivacyFilter.metadata((try? await asset.load(.metadata)) ?? [], to: privacy)
    if let filter = PrivacyFilter.filter(for: privacy) { session.metadataItemFilter = filter }
    try await Joiner.export(session)
  }

  /// Each cue drawn once, when it is first said. Asked from whatever thread the
  /// pictures come on.
  private final class Words: @unchecked Sendable {
    private let cues: [Subtitles.Cue]
    private let size: CGSize
    private let lock = NSLock()
    private var drawn: [Int: CIImage] = [:]

    init(_ cues: [Subtitles.Cue], in size: CGSize) {
      self.cues = cues
      self.size = size
    }

    func said(at time: Double) -> [CIImage] {
      lock.lock()
      defer { lock.unlock() }
      let now = cues.indices.filter { cues[$0].start <= time && time < cues[$0].end }
      // What has been said is not kept: a long film has thousands of lines.
      drawn = drawn.filter { now.contains($0.key) }
      var bottom = size.height * 0.06
      return now.compactMap { index in
        guard let image = drawn[index] ?? draw(cues[index].text) else { return nil }
        drawn[index] = image
        defer { bottom += image.extent.height }
        return image.transformed(by: CGAffineTransform(translationX: ((size.width - image.extent.width) / 2).rounded(), y: bottom.rounded()))
      }
    }

    private func draw(_ text: String) -> CIImage? {
      let height = max(12, size.height * 0.05)
      let style = NSMutableParagraphStyle()
      style.alignment = .center
      func letters(_ more: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: height, weight: .semibold), .paragraphStyle: style].merging(more) { $1 })
      }
      let edge = height * 0.12
      let room = CGSize(width: size.width * 0.9, height: size.height * 0.6)
      let needed = letters([:]).boundingRect(with: room, options: [.usesLineFragmentOrigin])
      let box = CGSize(width: ceil(needed.width + edge * 4), height: ceil(needed.height + edge * 4))
      guard let context = CGContext(
        data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return nil }
      let before = NSGraphicsContext.current
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      defer { NSGraphicsContext.current = before }
      let place = CGRect(x: edge * 2, y: edge * 2, width: needed.width, height: needed.height)
      // Round the letters first and the letters over it, or the edge eats them.
      context.setLineJoin(.round)
      letters([.strokeColor: NSColor.black, .strokeWidth: 22, .foregroundColor: NSColor.black]).draw(with: place, options: [.usesLineFragmentOrigin])
      letters([.foregroundColor: NSColor.white]).draw(with: place, options: [.usesLineFragmentOrigin])
      return context.makeImage().map { CIImage(cgImage: $0) }
    }
  }
}
