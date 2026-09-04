import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Turns text into spoken audio, with the voices already on the Mac.
///
/// `AVSpeechSynthesizer` hands back PCM buffers rather than writing a file, so
/// they are collected and written here. Nothing is downloaded and nothing is
/// sent anywhere.
enum SpeechSynthesis {

  /// Voices installed on this machine.
  static var voices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices() }

  /// Languages there is at least one voice for.
  static var languages: [String] {
    Set(voices.map(\.language)).sorted()
  }

  static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
    guard let language else { return AVSpeechSynthesisVoice(language: nil) }
    if let exact = voices.first(where: { $0.language.caseInsensitiveCompare(language) == .orderedSame }) {
      return exact
    }
    // "it" should find "it-IT" rather than failing on the region.
    return voices.first { $0.language.hasPrefix(language + "-") }
      ?? AVSpeechSynthesisVoice(language: language)
  }

  /// Speak `text` into an audio file.
  ///
  /// - Parameter language: BCP-47 tag, or nil for the system voice.
  static func write(
    _ text: String,
    to output: URL,
    as type: UTType,
    language: String?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProcessingError.conversionFailed(reason: "There is no text to speak")
    }
    guard let formatID = FormatCatalog.audioFormatID(for: type) else {
      throw ProcessingError.unsupportedConversion(from: .plainText, to: type)
    }

    let utterance = AVSpeechUtterance(string: trimmed)
    if let voice = voice(for: language) { utterance.voice = voice }

    let writer = BufferWriter(output: output, formatID: formatID, type: type)
    let synthesizer = AVSpeechSynthesizer()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let done = OnceFlag()
      synthesizer.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        // A zero-length buffer is how the synthesiser says it has finished.
        guard pcm.frameLength > 0 else {
          if done.claim() { continuation.resume() }
          return
        }
        writer.append(pcm)
        progress(0.5)
      }
    }

    try writer.finish()
    progress(1.0)
  }
}

/// Collects the synthesiser's buffers and writes them out once the format is
/// known, since the first buffer is what tells us the format.
private final class BufferWriter: @unchecked Sendable {
  private let output: URL
  private let formatID: AudioFormatID
  private let type: UTType
  private let lock = NSLock()
  private var file: AVAudioFile?
  private var failure: Error?

  init(output: URL, formatID: AudioFormatID, type: UTType) {
    self.output = output
    self.formatID = formatID
    self.type = type
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard failure == nil else { return }

    do {
      if file == nil {
        var settings: [String: Any] = [
          AVFormatIDKey: formatID,
          AVSampleRateKey: buffer.format.sampleRate,
          AVNumberOfChannelsKey: Int(buffer.format.channelCount),
        ]
        if formatID == kAudioFormatLinearPCM {
          settings[AVLinearPCMBitDepthKey] = 16
          settings[AVLinearPCMIsFloatKey] = false
          settings[AVLinearPCMIsBigEndianKey] = FormatCatalog.usesBigEndianPCM(type)
        }
        file = try AVAudioFile(forWriting: output, settings: settings)
      }
      try file?.write(from: buffer)
    } catch {
      failure = error
    }
  }

  func finish() throws {
    lock.lock()
    defer { lock.unlock() }
    if let failure { throw failure }
    guard file != nil else {
      throw ProcessingError.conversionFailed(reason: "The synthesiser produced no audio")
    }
    file = nil
  }
}

/// Resumes a continuation exactly once, from whichever thread gets there first.
private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !claimed else { return false }
    claimed = true
    return true
  }
}
