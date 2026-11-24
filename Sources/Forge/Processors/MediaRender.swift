import AVFoundation
import Foundation

/// A recording made ready: cut, sped up, turned round and evened out, as
/// something the rest of the path can treat like the file it came from.
struct PreparedMedia {
  let asset: AVAsset
  /// Holds what had to be written down on the way. Removed by whoever made it.
  let folder: URL
}

enum MediaRender {
  static func prepare(_ source: AVURLAsset, _ edit: MediaEdit, in folder: URL) async throws -> PreparedMedia {
    let played = try await edit.applied(to: source)
    guard edit.isReversed || edit.isEvened else { return PreparedMedia(asset: played, folder: folder) }

    // What cannot be played that way is written that way, and played.
    let written = AVMutableComposition()
    for track in try await played.loadTracks(withMediaType: .video) {
      let from: (asset: AVAsset, track: AVAssetTrack)
      if edit.isReversed {
        let url = folder.appendingPathComponent("\(UUID().uuidString).mov")
        try await reversePicture(of: track, in: played, to: url)
        let asset = AVURLAsset(url: url)
        guard let turned = try await asset.loadTracks(withMediaType: .video).first else { continue }
        from = (asset, turned)
      } else {
        from = (played, track)
      }
      guard let copy = written.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
      copy.preferredTransform = try await track.load(.preferredTransform)
      try copy.insertTimeRange(try await from.track.load(.timeRange), of: from.track, at: .zero)
    }
    for track in try await played.loadTracks(withMediaType: .audio) {
      let url = folder.appendingPathComponent("\(UUID().uuidString).caf")
      try await sound(of: track, in: played, like: source.url, to: url, reversed: edit.isReversed, evened: edit.isEvened)
      let asset = AVURLAsset(url: url)
      guard let turned = try await asset.loadTracks(withMediaType: .audio).first,
            let copy = written.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
      copy.languageCode = try await track.load(.languageCode)
      try copy.insertTimeRange(try await turned.load(.timeRange), of: turned, at: .zero)
    }
    // Its subtitles have nothing to be in time with once it runs backwards.
    for kind in [AVMediaType.subtitle, .closedCaption] where !edit.isReversed {
      for track in try await played.loadTracks(withMediaType: kind) {
        guard let copy = written.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
        try copy.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
      }
    }
    return PreparedMedia(asset: written, folder: folder)
  }

  /// The first soundtrack, written out as samples.
  static func firstSound(of asset: AVAsset, like source: URL, in folder: URL) async throws -> URL? {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
    let url = folder.appendingPathComponent("\(UUID().uuidString).caf")
    try await sound(of: track, in: asset, like: source, to: url, reversed: false, evened: false)
    return url
  }

  // MARK: - Sound

  /// - Parameter source: whose depth the samples are written at.
  private static func sound(
    of track: AVAssetTrack, in asset: AVAsset, like source: URL, to output: URL, reversed: Bool, evened: Bool
  ) async throws {
    let described = try await track.load(.formatDescriptions).first
    guard let described, let layoutAndRate = AVAudioFormat(cmAudioFormatDescription: described) as AVAudioFormat? else {
      throw ProcessingError.conversionFailed(reason: "The sound cannot be read")
    }
    var size = 0
    let layout = CMAudioFormatDescriptionGetChannelLayout(described, sizeOut: &size)
    let layoutData = layout.map { Data(bytes: $0, count: size) }
    let channels = layoutAndRate.channelCount, rate = layoutAndRate.sampleRate

    var read: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: Int(channels),
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: true,
    ]
    if channels > 2, let layoutData { read[AVChannelLayoutKey] = layoutData }

    // Held on to: what describes it goes when it goes.
    let own = (try? AVAudioFile(forReading: source))?.fileFormat
    let pcm = own.map { $0.streamDescription.pointee }.flatMap { $0.mFormatID == kAudioFormatLinearPCM ? $0 : nil }
    let isFloat = pcm.map { $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 } ?? false
    var write: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: Int(channels),
      AVLinearPCMBitDepthKey: isFloat ? 32 : Int(pcm?.mBitsPerChannel ?? 16), AVLinearPCMIsFloatKey: isFloat, AVLinearPCMIsBigEndianKey: false,
    ]
    if channels > 2, let layoutData { write[AVChannelLayoutKey] = layoutData }

    // Float until the last: a gain worked out on rounded samples is rounded twice.
    let needsAnother = reversed || evened
    let first = needsAnother ? output.deletingPathExtension().appendingPathExtension("first.caf") : output
    defer { if needsAnother { try? FileManager.default.removeItem(at: first) } }
    var firstSettings = write
    if needsAnother { firstSettings[AVLinearPCMBitDepthKey] = 32; firstSettings[AVLinearPCMIsFloatKey] = true }
    try copySamples(of: track, in: asset, reading: read, to: first, writing: firstSettings)
    guard needsAnother else { return }
    let input = try AVAudioFile(forReading: first)
    let gain = evened ? try Loudness.gain(for: input) : 1
    try rewrite(input, to: output, writing: write, reversed: reversed, gain: gain)
  }

  private static func copySamples(
    of track: AVAssetTrack, in asset: AVAsset, reading: [String: Any], to url: URL, writing: [String: Any]
  ) throws {
    let reader = try AVAssetReader(asset: asset)
    // Faster is not higher. And not where nothing is faster: the same thing
    // done to sound that keeps its time loses the last of it.
    let isScaled = (track as? AVCompositionTrack)?.segments.contains { !$0.isEmpty && $0.timeMapping.source.duration != $0.timeMapping.target.duration } ?? false
    let output: AVAssetReaderOutput
    if isScaled {
      let mixed = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: reading)
      mixed.audioTimePitchAlgorithm = .spectral
      output = mixed
    } else {
      output = AVAssetReaderTrackOutput(track: track, outputSettings: reading)
    }
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? ProcessingError.conversionFailed(reason: "The sound cannot be read")
    }
    let file = try AVAudioFile(forWriting: url, settings: writing)
    while let sample = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
      guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { continue }
      buffer.frameLength = frames
      let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
      )
      guard status == noErr else { throw ProcessingError.conversionFailed(reason: "The sound cannot be read") }
      try file.write(from: buffer)
    }
    guard reader.status == .completed else {
      throw reader.error ?? ProcessingError.conversionFailed(reason: "The sound cannot be read")
    }
  }

  private static func rewrite(_ input: AVAudioFile, to url: URL, writing: [String: Any], reversed: Bool, gain: Float) throws {
    let chunk: AVAudioFramePosition = 64 * 1024
    let format = input.processingFormat
    let output = try AVAudioFile(forWriting: url, settings: writing)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
      throw ProcessingError.conversionFailed(reason: "Cannot allocate an audio buffer")
    }
    // A read gives what it has, which may be less than was asked: forwards
    // that is made up by the next one, and backwards it would be a gap.
    let starts = Array(stride(from: AVAudioFramePosition(0), to: input.length, by: Int(chunk)))
    for start in reversed ? starts.reversed() : starts {
      let end = min(start + chunk, input.length)
      var pieces: [[[Float]]] = []
      input.framePosition = start
      while input.framePosition < end {
        try Task.checkCancellation()
        try input.read(into: buffer, frameCount: AVAudioFrameCount(end - input.framePosition))
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { break }
        pieces.append((0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) })
      }
      for piece in reversed ? pieces.reversed() : pieces {
        guard let data = buffer.floatChannelData, let frames = piece.first?.count else { continue }
        for (channel, samples) in piece.enumerated() {
          for (index, sample) in (reversed ? Array(samples.reversed()) : samples).enumerated() { data[channel][index] = sample * gain }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try output.write(from: buffer)
      }
    }
  }

  // MARK: - Picture

  /// A second of it at a time, from the end: the whole of it would not fit.
  ///
  /// ProRes, because it is encoded again on the way out and what is lost twice
  /// shows.
  private static func reversePicture(of track: AVAssetTrack, in asset: AVAsset, to url: URL) async throws {
    let size = try await track.load(.naturalSize)
    let range = try await track.load(.timeRange)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
    ])
    input.expectsMediaDataInRealTime = false
    let pixels: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pixels)
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? ProcessingError.conversionFailed(reason: "Cannot write the film backwards") }
    writer.startSession(atSourceTime: .zero)

    let second = CMTime(value: 1, timescale: 1)
    var end = range.end
    while end > range.start {
      try Task.checkCancellation()
      let start = max(range.start, end - second)
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: pixels)
      output.alwaysCopiesSampleData = false
      reader.timeRange = CMTimeRange(start: start, end: end)
      reader.add(output)
      guard reader.startReading() else { throw reader.error ?? ProcessingError.conversionFailed(reason: "Cannot read the film backwards") }
      var frames: [(buffer: CVPixelBuffer, ends: CMTime)] = []
      while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        // The frame that was on when this second began belongs to the one before.
        guard time >= start, time < end else { continue }
        frames.append((buffer, time))
      }
      guard reader.status == .completed else { throw reader.error ?? ProcessingError.conversionFailed(reason: "Cannot read the film backwards") }
      for (index, frame) in frames.enumerated().reversed() {
        // It is shown from when the one after it used to come.
        let until = index + 1 < frames.count ? frames[index + 1].ends : end
        try await waitUntilReady(input, writer)
        adaptor.append(frame.buffer, withPresentationTime: range.end - until)
      }
      end = start
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: range.duration)
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? ProcessingError.conversionFailed(reason: "Cannot write the film backwards") }
  }

  private static func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) async throws {
    while !input.isReadyForMoreMediaData {
      try Task.checkCancellation()
      guard writer.status == .writing else { throw writer.error ?? ProcessingError.conversionFailed(reason: "Cannot write the film backwards") }
      try await Task.sleep(nanoseconds: 2_000_000)
    }
  }
}
