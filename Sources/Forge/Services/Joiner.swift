import AppKit
import AVFoundation
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Several files made into one, in the order they are given.
enum Joiner {
  enum Kind: String, CaseIterable, Sendable {
    case pdf, film, sound
    /// A film with another file's sound, or with its subtitles.
    case dubbed, subtitled

    var title: String {
      switch self {
      case .pdf: return "One PDF"
      case .film: return "One film"
      case .sound: return "One recording"
      case .dubbed: return "Film with this sound"
      case .subtitled: return "Film with these subtitles"
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
    if files.count == 2, kinds == [.video, .audio] { return [.dubbed] }
    if files.count == 2, kinds == [.video, .subtitle] { return [.subtitled] }
    return []
  }

  /// What the joined file is written as: what the first one is, where that is
  /// something the system writes.
  static func type(of kind: Kind, from first: UTType) -> UTType {
    switch kind {
    case .pdf: return .pdf
    case .film, .dubbed: return first == .quickTimeMovie ? .quickTimeMovie : .mpeg4Movie
    case .subtitled: return first == .quickTimeMovie || first.preferredFilenameExtension == "mkv" ? first : .mpeg4Movie
    case .sound: return FormatCatalog.audioFormatID(for: first) != nil ? first : UTType("com.apple.m4a-audio") ?? .mpeg4Audio
    }
  }

  static func join(_ files: [ProcessableFile], as kind: Kind, to output: URL, privacy: PrivacyPolicy = .keepAll) async throws {
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
    case .dubbed: try await dub(files[0].url, with: files[1].url, to: output, privacy: privacy)
    case .subtitled: try subtitle(files[0], with: files[1], to: output, privacy: privacy)
    }
    try PrivacyFilter.applyAfterWriting(privacy, to: [output])
  }

  // MARK: - A film and something else

  /// The film's picture as it is, and the other's sound for as long as it lasts.
  private static func dub(_ film: URL, with sound: URL, to output: URL, privacy: PrivacyPolicy) async throws {
    let picture = AVURLAsset(url: film), heard = AVURLAsset(url: sound)
    let composition = AVMutableComposition()
    guard let shown = try? await picture.loadTracks(withMediaType: .video).first,
          let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw ProcessingError.conversionFailed(reason: "\(film.lastPathComponent) cannot be opened by macOS. Convert it to MP4 first.")
    }
    guard let voice = try? await heard.loadTracks(withMediaType: .audio).first,
          let second = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw ProcessingError.conversionFailed(reason: "\(sound.lastPathComponent) has no sound that macOS can read.")
    }
    let range = try await shown.load(.timeRange)
    try track.insertTimeRange(range, of: shown, at: .zero)
    track.preferredTransform = try await shown.load(.preferredTransform)
    let there = try await voice.load(.timeRange)
    try second.insertTimeRange(CMTimeRange(start: there.start, duration: min(there.duration, range.duration)), of: voice, at: .zero)
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
      throw ProcessingError.conversionFailed(reason: "The film cannot be written")
    }
    session.outputURL = output
    session.outputFileType = AVFileType((UTType(filenameExtension: output.pathExtension) ?? .mpeg4Movie).identifier)
    session.metadata = PrivacyFilter.metadata((try? await picture.load(.metadata)) ?? [], to: privacy)
    if let filter = PrivacyFilter.filter(for: privacy) { session.metadataItemFilter = filter }
    try await export(session)
  }

  /// A track that can be turned on and off, in a film otherwise as it is.
  private static func subtitle(_ film: ProcessableFile, with words: ProcessableFile, to output: URL, privacy: PrivacyPolicy) throws {
    guard let ffmpeg = ExternalTools.locate("ffmpeg") else {
      throw ProcessingError.conversionFailed(reason: "Subtitles are put into a film by ffmpeg: brew install ffmpeg")
    }
    let codec = output.pathExtension.lowercased() == "mkv" ? "srt" : "mov_text"
    do {
      try ExternalTools.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error", "-y", "-i", film.url.path, "-i", words.url.path,
        "-map", "0:v", "-map", "0:a?", "-map", "1:s:0", "-c", "copy", "-c:s", codec, "-movflags", "+faststart",
      ] + ExternalBridge.privacyArguments(privacy) + [output.path])
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ProcessingError.conversionFailed(
        reason: "\(words.fileName) could not be put into \(film.fileName). Convert the film to MP4 and the subtitles to SRT, and try again."
      )
    }
  }

  // MARK: - Pictures

  private static func slides(_ files: [ProcessableFile], to output: URL) async throws {
    // One at a time: a hundred photographs at once are sixteen gigabytes.
    func picture(_ file: ProcessableFile) throws -> CGImage {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: largestSide, kCGImageSourceShouldCache: false,
      ]
      guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw ProcessingError.conversionFailed(reason: "Cannot read \(file.fileName)")
      }
      return image
    }
    /// As it is seen, and no larger than it will be drawn.
    func seen(_ file: ProcessableFile) -> CGSize {
      let source = CGImageSourceCreateWithURL(file.url as CFURL, nil)
      let isOnItsSide = source.map { ImageProcessor.orientation(of: $0).rawValue >= 5 } ?? false
      let width = CGFloat(file.dimensions?.width ?? 0), height = CGFloat(file.dimensions?.height ?? 0)
      let scale = min(1, largestSide / max(width, height, 1))
      return isOnItsSide ? CGSize(width: height * scale, height: width * scale) : CGSize(width: width * scale, height: height * scale)
    }
    // Room for the largest of them, and none of them stretched.
    let sizes = files.map(seen)
    let size = CGSize(
      width: CGFloat(Int(sizes.map(\.width).max() ?? 0) / 2 * 2), height: CGFloat(Int(sizes.map(\.height).max() ?? 0) / 2 * 2)
    )
    guard let context = CGContext(
      data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw ProcessingError.conversionFailed(reason: "Cannot draw a picture") }
    context.interpolationQuality = .high
    let type = UTType(filenameExtension: output.pathExtension) ?? .mpeg4Movie
    try await MovieWriter.write(files.count, of: size, to: output, as: type, frame: { index in
      try autoreleasepool {
        let drawn = try picture(files[index])
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(drawn, in: AVMakeRect(aspectRatio: CGSize(width: drawn.width, height: drawn.height), insideRect: CGRect(origin: .zero, size: size)))
        guard let made = context.makeImage() else { throw ProcessingError.conversionFailed(reason: "Cannot draw a picture") }
        return ImageFrame(image: made, duration: secondsAPicture)
      }
    }) { _ in }
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
  func join(_ given: [ProcessableFile], as kind: Joiner.Kind, into folder: URL? = nil, named name: String? = nil) async throws -> URL {
    // The film first, whichever of the two was picked up first.
    let files = kind == .dubbed || kind == .subtitled
      ? given.sorted { ConvertKind(fileType: $0.fileType) == .video && ConvertKind(fileType: $1.fileType) != .video } : given
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
    try await Joiner.join(files, as: kind, to: scratch, privacy: privacyPolicy)
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
