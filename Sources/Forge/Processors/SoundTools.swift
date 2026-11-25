import AVFoundation
import AudioToolbox
import Foundation

/// What is done to a recording's samples, by the units macOS plays sound with.
enum SoundTools {
  private static let chunk: AVAudioFrameCount = 4096

  /// - Returns: where the changed sound is: beside the one it was handed, or
  ///   that one where nothing here was asked.
  static func apply(_ edit: MediaEdit, to url: URL) throws -> URL {
    var current = url
    func next(_ make: (URL, URL) throws -> Void) throws {
      let made = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).caf")
      try make(current, made)
      if current != url { try? FileManager.default.removeItem(at: current) }
      current = made
    }
    if edit.keepsVoice { try next { try render($0, through: try voiceUnit(), to: $1) } }
    if edit.pitch != 0 {
      try next { from, to in
        let unit = AVAudioUnitTimePitch()
        unit.pitch = Float(edit.pitch) * 100
        unit.overlap = 32
        try render(from, through: unit, to: to)
      }
    }
    if edit.isMono { try next(mixDown) }
    return current
  }

  private static func voiceUnit() throws -> AVAudioUnit {
    let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
      componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
    ))
    AudioUnitSetParameter(unit.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent), kAudioUnitScope_Global, 0, 100, 0)
    AudioUnitSetParameter(
      unit.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate), kAudioUnitScope_Global, 0,
      AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice), 0
    )
    return unit
  }

  /// As long as it was: what a unit holds back at first is waited for, and
  /// left off.
  private static func render(_ input: URL, through unit: AVAudioUnit, to output: URL) throws {
    let file = try AVAudioFile(forReading: input)
    let format = file.processingFormat
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    engine.attach(player)
    engine.attach(unit)
    engine.connect(player, to: unit, format: format)
    engine.connect(unit, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
    try engine.start()
    defer { engine.stop() }
    player.scheduleFile(file, at: nil)
    player.play()

    guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
      throw ProcessingError.conversionFailed(reason: "Cannot allocate an audio buffer")
    }
    let written = try AVAudioFile(forWriting: output, settings: file.fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var held = AVAudioFramePosition((unit.auAudioUnit.latency * format.sampleRate).rounded())
    var left = file.length
    while left > 0 {
      try Task.checkCancellation()
      guard try engine.renderOffline(chunk, to: buffer) == .success, buffer.frameLength > 0 else {
        throw ProcessingError.conversionFailed(reason: "The sound cannot be worked on")
      }
      let skipped = min(held, AVAudioFramePosition(buffer.frameLength))
      held -= skipped
      let kept = min(AVAudioFramePosition(buffer.frameLength) - skipped, left)
      guard kept > 0 else { continue }
      if skipped > 0, let data = buffer.floatChannelData {
        for channel in 0..<Int(format.channelCount) {
          memmove(data[channel], data[channel] + Int(skipped), Int(kept) * MemoryLayout<Float>.size)
        }
      }
      buffer.frameLength = AVAudioFrameCount(kept)
      try written.write(from: buffer)
      left -= kept
    }
  }

  /// All the channels, each as loud as the next.
  private static func mixDown(_ input: URL, to output: URL) throws {
    let file = try AVAudioFile(forReading: input)
    let format = file.processingFormat
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
          let from = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk), let to = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk) else {
      throw ProcessingError.conversionFailed(reason: "Cannot allocate an audio buffer")
    }
    let written = try AVAudioFile(forWriting: output, settings: mono.settings)
    let channels = Int(format.channelCount)
    while file.framePosition < file.length {
      try Task.checkCancellation()
      try file.read(into: from, frameCount: AVAudioFrameCount(min(Int64(chunk), file.length - file.framePosition)))
      guard from.frameLength > 0, let data = from.floatChannelData, let mixed = to.floatChannelData?[0] else { break }
      for index in 0..<Int(from.frameLength) {
        var sum: Float = 0
        for channel in 0..<channels { sum += data[channel][index] }
        mixed[index] = sum / Float(channels)
      }
      to.frameLength = from.frameLength
      try written.write(from: to)
    }
  }
}

/// The stretches of a recording with something in them.
enum Silence {
  /// Heard every fiftieth of a second.
  private static let window = 0.02
  /// Shorter than this is somebody breathing.
  private static let longEnough = 0.6
  /// Left on either side, so that no word is cut into.
  private static let margin = 0.15
  /// Below what is loud in it by this much, and below a whisper, is silence.
  private static let below = 35.0
  private static let quietest = -60.0

  static func loudParts(of asset: AVAsset, within kept: ClosedRange<Double>) async throws -> [ClosedRange<Double>] {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw ProcessingError.conversionFailed(reason: "There is no sound in it to find silences in.")
    }
    let levels = try levels(of: track, in: asset)
    let heard = levels.filter { $0.isFinite }.sorted()
    guard let loud = heard.isEmpty ? nil : heard[Int(Double(heard.count - 1) * 0.95)] else {
      throw ProcessingError.conversionFailed(reason: "There is nothing but silence in it.")
    }
    let bar = max(loud - below, quietest)
    let parts = parts(levels.map { $0 > bar }, within: kept)
    guard !parts.isEmpty else { throw ProcessingError.conversionFailed(reason: "There is nothing but silence in it.") }
    let length = parts.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    guard kept.upperBound - kept.lowerBound - length > longEnough / 2 else {
      throw ProcessingError.leftAlone(reason: "There are no long silences in it.")
    }
    return parts
  }

  /// - Parameter isLoud: window by window, from the beginning.
  static func parts(_ isLoud: [Bool], within kept: ClosedRange<Double>) -> [ClosedRange<Double>] {
    var found: [ClosedRange<Double>] = []
    for (index, loud) in isLoud.enumerated() where loud {
      let from = max(kept.lowerBound, Double(index) * window - margin), to = min(kept.upperBound, Double(index + 1) * window + margin)
      guard to > from else { continue }
      if let last = found.last, from - last.upperBound < longEnough - 2 * margin {
        found[found.count - 1] = last.lowerBound...max(last.upperBound, to)
      } else {
        found.append(from...to)
      }
    }
    return found
  }

  /// In decibels under full.
  private static func levels(of track: AVAssetTrack, in asset: AVAsset) throws -> [Double] {
    let rate = 16_000
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? ProcessingError.conversionFailed(reason: "The sound cannot be read") }
    let size = Int(Double(rate) * window)
    var found: [Double] = [], sum = 0.0, count = 0
    while let sample = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
      CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * MemoryLayout<Float>.size, destination: &samples)
      for value in samples {
        sum += Double(value * value)
        count += 1
        if count == size { found.append(10 * log10(sum / Double(count))); sum = 0; count = 0 }
      }
    }
    if count > 0 { found.append(10 * log10(sum / Double(count))) }
    return found
  }
}
