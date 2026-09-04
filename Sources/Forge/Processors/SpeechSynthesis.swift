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
    let gate = ResumeOnce()

    // Wait with a limit. The synthesiser is a callback with no failure path: on
    // a machine with no audio stack it simply never calls back, and waiting on
    // that forever hangs whatever asked - a batch, or a test runner.
    let budget = timeout(for: trimmed)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      gate.arm(continuation)

      let deadline = Task {
        try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
        gate.resume()
      }

      synthesizer.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        // A zero-length buffer is how the synthesiser says it has finished.
        guard pcm.frameLength > 0 else {
          deadline.cancel()
          gate.resume()
          return
        }
        writer.append(pcm)
        progress(0.5)
      }
    }

    guard writer.wroteAnything else {
      throw ProcessingError.conversionFailed(
        reason: "No speech was produced within \(Int(budget)) seconds. This Mac may have no speech voices available."
      )
    }

    try writer.finish()
    progress(1.0)
  }

  /// Long enough for the text, with a floor for short ones. Speech runs far
  /// faster than real time when it is writing to a file rather than a speaker.
  private static func timeout(for text: String) -> Double {
    let seconds = Double(text.count) / 10
    return min(max(seconds, 20), 300)
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

  var wroteAnything: Bool {
    lock.lock()
    defer { lock.unlock() }
    return file != nil
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

/// Resumes a continuation exactly once, from whichever of the synthesiser and
/// the deadline gets there first.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var resumed = false

  func arm(_ continuation: CheckedContinuation<Void, Never>) {
    lock.lock()
    defer { lock.unlock() }
    self.continuation = continuation
  }

  func resume() {
    lock.lock()
    let pending = resumed ? nil : continuation
    resumed = true
    continuation = nil
    lock.unlock()
    pending?.resume()
  }
}
