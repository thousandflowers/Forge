import AppKit
import AVFoundation
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Several files made into one, in the order they are given.
enum Joiner {
  enum Kind: String, CaseIterable, Sendable {
    case pdf, film, sound

    var title: String {
      switch self {
      case .pdf: return "One PDF"
      case .film: return "One film"
      case .sound: return "One recording"
      }
    }
  }

  /// How long each picture stays up in a film of pictures.
  static let secondsAPicture = 3.0
  private static let largestSide: CGFloat = 3840

  /// What these can be made into together. Nothing, for one file alone.
  static func kinds(for files: [ProcessableFile]) -> [Kind] {
    guard files.count > 1 else { return [] }
    let kinds = Set(files.compactMap { ConvertKind(fileType: $0.fileType) })
    let arePages = files.allSatisfy { $0.fileType.conforms(to: .pdf) || ConvertKind(fileType: $0.fileType) == .image }
    if arePages { return kinds == [.image] ? [.pdf, .film] : [.pdf] }
    if kinds == [.video] { return [.film, .sound] }
    if kinds == [.audio] { return [.sound] }
    return []
  }

  /// What the joined file is written as: what the first one is, where that is
  /// something the system writes.
  static func type(of kind: Kind, from first: UTType) -> UTType {
    switch kind {
    case .pdf: return .pdf
    case .film: return first == .quickTimeMovie ? .quickTimeMovie : .mpeg4Movie
    case .sound: return FormatCatalog.audioFormatID(for: first) != nil ? first : UTType("com.apple.m4a-audio") ?? .mpeg4Audio
    }
  }

  static func join(_ files: [ProcessableFile], as kind: Kind, to output: URL) async throws {
    switch kind {
    case .pdf:
      for file in files {
        if let pdf = PDFDocument(url: file.url) { try SimpleDocProcessor.refuseIfLocked(pdf, named: file.fileName) }
      }
      try Merger.pdf(from: files.map(\.url), to: output)
    case .film:
      let isPictures = files.allSatisfy { ConvertKind(fileType: $0.fileType) == .image }
      try await isPictures ? slides(files, to: output) : film(files, to: output)
    case .sound: try await sound(files, to: output)
    }
  }

  // MARK: - Pictures

  private static func slides(_ files: [ProcessableFile], to output: URL) async throws {
    let pictures = try files.map { file -> CGImage in
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: largestSide,
      ]
      guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw ProcessingError.conversionFailed(reason: "Cannot read \(file.fileName)")
      }
      return image
    }
    // Room for the largest of them, and none of them stretched.
    let size = CGSize(
      width: (pictures.map(\.width).max() ?? 0) / 2 * 2, height: (pictures.map(\.height).max() ?? 0) / 2 * 2
    )
    let frames = try pictures.map { picture -> ImageFrame in
      guard let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { throw ProcessingError.conversionFailed(reason: "Cannot draw a picture") }
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fill(CGRect(origin: .zero, size: size))
      context.interpolationQuality = .high
      context.draw(picture, in: AVMakeRect(aspectRatio: CGSize(width: picture.width, height: picture.height), insideRect: CGRect(origin: .zero, size: size)))
      guard let drawn = context.makeImage() else { throw ProcessingError.conversionFailed(reason: "Cannot draw a picture") }
      return ImageFrame(image: drawn, duration: secondsAPicture)
    }
    let type = UTType(filenameExtension: output.pathExtension) ?? .mpeg4Movie
    try await MovieWriter.write(frames, to: output, as: type) { _ in }
  }

  // MARK: - Films

  private static func film(_ files: [ProcessableFile], to output: URL) async throws {
    let composition = AVMutableComposition()
    guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw ProcessingError.conversionFailed(reason: "The films cannot be joined")
    }
    var at = CMTime.zero
    var frame: CGSize?
    var instructions: [AVMutableVideoCompositionInstruction] = []
    var rate: Float = 0
    var hasSound = false

    for file in files {
      let asset = AVURLAsset(url: file.url)
      guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
        throw ProcessingError.conversionFailed(
          reason: "\(file.fileName) cannot be opened by macOS. Convert it to MP4 first, and then join it."
        )
      }
      let range = try await track.load(.timeRange)
      try picture.insertTimeRange(range, of: track, at: at)
      if let heard = try await asset.loadTracks(withMediaType: .audio).first {
        let there = try await heard.load(.timeRange).intersection(range)
        if there.duration > .zero {
          try sound.insertTimeRange(there, of: heard, at: at + (there.start - range.start))
          hasSound = true
        }
      }
      rate = max(rate, try await track.load(.nominalFrameRate))

      let turned = try await track.load(.preferredTransform)
      let shown = CGRect(origin: .zero, size: try await track.load(.naturalSize)).applying(turned)
      let upright = CGSize(width: abs(shown.width), height: abs(shown.height))
      // The first says what shape the film is; the rest are shown whole in it.
      let render = frame ?? CGSize(width: floor(upright.width / 2) * 2, height: floor(upright.height / 2) * 2)
      frame = render
      let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: picture)
      layer.setTransform(
        turned.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
          .concatenating(MediaProcessor.placement(of: upright, in: render, mode: .pad)),
        at: at
      )
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: at, duration: range.duration)
      instruction.layerInstructions = [layer]
      instructions.append(instruction)
      at = at + range.duration
    }
    if !hasSound { composition.removeTrack(sound) }

    let drawn = AVMutableVideoComposition()
    drawn.renderSize = frame ?? .zero
    drawn.frameDuration = CMTime(seconds: 1 / Double(rate > 0 ? min(rate, 120) : 30), preferredTimescale: 60_000)
    drawn.instructions = instructions
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
      throw ProcessingError.conversionFailed(reason: "The films cannot be joined")
    }
    session.videoComposition = drawn
    session.outputURL = output
    session.outputFileType = AVFileType((UTType(filenameExtension: output.pathExtension) ?? .mpeg4Movie).identifier)
    session.shouldOptimizeForNetworkUse = true
    try await export(session)
  }

  // MARK: - Recordings

  private static func sound(_ files: [ProcessableFile], to output: URL) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("forge-join-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // Every one as the first is, so that what comes out is one recording and
    // not several at different speeds.
    let whole = folder.appendingPathComponent("joined.caf")
    var target: AVAudioFile?
    for file in files {
      let source = try await samples(of: file, in: folder)
      let input = try AVAudioFile(forReading: source)
      let written = try target ?? AVAudioFile(forWriting: whole, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: input.processingFormat.sampleRate,
        AVNumberOfChannelsKey: min(2, Int(input.processingFormat.channelCount)), AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
      ])
      target = written
      try append(input, named: file.fileName, to: written)
    }
    target = nil
    _ = try await MediaProcessor().process(whole, to: output, with: []) { _ in }
  }

  private static func samples(of file: ProcessableFile, in folder: URL) async throws -> URL {
    if (try? AVAudioFile(forReading: file.url)) != nil { return file.url }
    guard let url = try? await MediaRender.firstSound(of: AVURLAsset(url: file.url), like: file.url, in: folder) else {
      throw ProcessingError.conversionFailed(reason: "\(file.fileName) has no sound that macOS can read.")
    }
    return url
  }

  private static func append(_ input: AVAudioFile, named name: String, to output: AVAudioFile) throws {
    let from = input.processingFormat, to = output.processingFormat
    guard let converter = AVAudioConverter(from: from, to: to),
          let read = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: 32 * 1024) else {
      throw ProcessingError.conversionFailed(reason: "\(name) cannot be joined to the rest.")
    }
    let room = AVAudioFrameCount(Double(32 * 1024) * max(1, to.sampleRate / from.sampleRate)) + 1024
    while true {
      try Task.checkCancellation()
      guard let made = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: room) else { break }
      var failure: Error?
      var problem: NSError?
      let status = converter.convert(to: made, error: &problem) { wanted, state in
        guard input.framePosition < input.length else { state.pointee = .endOfStream; return nil }
        do {
          try input.read(into: read, frameCount: min(wanted, read.frameCapacity, AVAudioFrameCount(min(Int64(UInt32.max), input.length - input.framePosition))))
        } catch { failure = error; state.pointee = .endOfStream; return nil }
        state.pointee = .haveData
        return read
      }
      if let error = failure ?? problem { throw error }
      if made.frameLength > 0 { try output.write(from: made) }
      if status == .endOfStream || status == .error || (status == .inputRanDry && made.frameLength == 0) { break }
    }
  }

  private static func export(_ session: AVAssetExportSession) async throws {
    let box = SessionBox(session)
    await withTaskCancellationHandler { await box.session.export() } onCancel: { box.session.cancelExport() }
    if session.status == .cancelled { throw CancellationError() }
    guard session.status == .completed else {
      throw session.error ?? ProcessingError.conversionFailed(reason: "The films could not be joined")
    }
  }

  private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
  }
}

extension ProcessingCoordinator {
  /// Several files into one, beside the first or in a folder. Written out of
  /// sight and put where it goes once it is whole, as everything else is.
  func join(_ files: [ProcessableFile], as kind: Joiner.Kind, into folder: URL? = nil, named name: String? = nil) async throws -> URL {
    guard let first = files.first, Joiner.kinds(for: files).contains(kind) else {
      throw ProcessingError.conversionFailed(reason: "These files cannot be made into \(kind.title.lowercased()) together.")
    }
    let started = Date()
    let type = Joiner.type(of: kind, from: first.fileType)
    let home = folder ?? first.url.deletingLastPathComponent()
    let stem = name ?? "\((first.fileName as NSString).deletingPathExtension) joined"
    let ext = FormatCatalog.fileExtension(for: type) ?? "pdf"
    let scratch = home.appendingPathComponent(".forge-\(UUID().uuidString).\(ext)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try await Joiner.join(files, as: kind, to: scratch)
    let output = try claim(home.appendingPathComponent("\(stem).\(ext)"))
    do {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: scratch)
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error
    }
    await record(ProcessingHistory(
      fileURL: first.url, ruleId: nil, timestamp: Date(), status: .completed, duration: Date().timeIntervalSince(started),
      outputURL: output, destinationFolder: home, presetName: "\(kind.title), of \(files.count) files"
    ))
    return output
  }
}
