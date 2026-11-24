import AudioToolbox
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Music written down, played on the instruments every Mac has.
final class MidiProcessor: FileProcessor, @unchecked Sendable {
  let name = "MIDI Processor"

  static let readable: Set<String> = ["mid", "midi", "kar"]
  private static let rate = 44_100.0
  /// What is still ringing when the last note is let go.
  private static let tail = 2.0
  private static let longest = 3 * 3600.0

  private let media = MediaProcessor()

  func canProcess(_ file: ProcessableFile) -> Bool { Self.readable.contains(file.url.pathExtension.lowercased()) }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool { FormatCatalog.audioFormatID(for: target) != nil }

  func process(
    _ input: URL, to output: URL, with operations: [Operation], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    let played = FileManager.default.temporaryDirectory.appendingPathComponent("forge-midi-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: played) }
    try Self.play(input, into: played) { progress($0 * 0.6) }
    let made = try await media.process(played, to: output, with: operations) { progress(0.6 + $0 * 0.4) }
    return ProcessingResult(
      outputURL: made.outputURL, outputSize: made.outputSize, outputDimensions: nil, duration: Date().timeIntervalSince(start),
      additionalOutputs: made.additionalOutputs
    )
  }

  private static func play(_ input: URL, into output: URL, progress: (Double) -> Void) throws {
    let unreadable = ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) is not a MIDI file macOS can read.")
    let engine = AVAudioEngine()
    // The Mac's own instruments, all of them: a sampler would play one.
    let synth = AVAudioUnitMIDIInstrument(audioComponentDescription: AudioComponentDescription(
      componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
    ))
    engine.attach(synth)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw unreadable }
    engine.connect(synth, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    let sequencer = AVAudioSequencer(audioEngine: engine)
    do { try sequencer.load(from: input, options: []) } catch { throw unreadable }
    let length = sequencer.tracks.map { $0.offsetTime + $0.lengthInSeconds }.max() ?? 0
    guard length > 0 else { throw ProcessingError.conversionFailed(reason: "There are no notes in \(input.lastPathComponent).") }
    guard length < longest else { throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) is longer than three hours.") }
    try engine.start()
    sequencer.prepareToPlay()
    try sequencer.start()
    defer { sequencer.stop(); engine.stop() }

    let file = try AVAudioFile(forWriting: output, settings: format.settings)
    let frames = AVAudioFramePosition((length + tail) * rate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { throw unreadable }
    while engine.manualRenderingSampleTime < frames {
      try Task.checkCancellation()
      let wanted = AVAudioFrameCount(min(4096, frames - engine.manualRenderingSampleTime))
      switch try engine.renderOffline(wanted, to: buffer) {
      case .success: try file.write(from: buffer)
      case .cannotDoInCurrentContext: Thread.sleep(forTimeInterval: 0.005)
      default: throw unreadable
      }
      progress(Double(engine.manualRenderingSampleTime) / Double(frames))
    }
  }
}
