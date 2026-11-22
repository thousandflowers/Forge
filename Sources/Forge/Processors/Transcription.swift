import AVFoundation
import Foundation
import Speech

/// Turns a recording into text, on device.
///
/// The Speech framework asks for permission the first time, and refuses to run
/// without it. It also declines to work off-device here on purpose: a file the
/// user asked Forge to convert should not be uploaded to anyone.
enum Transcription {

  /// Locales the recogniser offers, as BCP-47 tags.
  static var supportedLocales: [String] {
    SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
  }

  static func supports(_ locale: String) -> Bool {
    supportedLocales.contains { $0.caseInsensitiveCompare(locale) == .orderedSame }
      || supportedLocales.contains { $0.hasPrefix(locale + "-") || $0.hasPrefix(locale + "_") }
  }

  /// Ask once, and report what the answer was.
  static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
    let current = SFSpeechRecognizer.authorizationStatus()
    guard current == .notDetermined else { return current }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
  }

  /// Transcribe `url`, which may be audio or a video with a soundtrack.
  ///
  /// - Parameter locale: BCP-47 tag, or nil for the system's own.
  static func text(
    of url: URL,
    locale: String?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> String {
    // Check the language first: it costs nothing and does not need permission,
    // so a typo is answered immediately rather than after a prompt.
    if let locale, !supports(locale) {
      throw ProcessingError.validationFailed(
        message: "Speech recognition does not have \(locale). It has: \(supportedLocales.prefix(20).joined(separator: ", "))…"
      )
    }

    switch await authorize() {
    case .authorized:
      break
    case .denied, .restricted:
      throw ProcessingError.validationFailed(
        message: "Forge is not allowed to use speech recognition. Turn it on in System Settings, under Privacy & Security."
      )
    default:
      throw ProcessingError.validationFailed(message: "Speech recognition was not granted.")
    }

    let chosen = locale.map(Locale.init(identifier:)) ?? Locale.current
    guard let recognizer = SFSpeechRecognizer(locale: chosen) else {
      throw ProcessingError.validationFailed(message: "No recogniser for \(chosen.identifier).")
    }
    guard recognizer.isAvailable else {
      throw ProcessingError.conversionFailed(reason: "The recogniser for \(chosen.identifier) is not available right now.")
    }

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    // Keep the recording on the machine. A conversion is not a reason to send
    // someone's audio to a server.
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

    let gate = ResultGate()

    // Recognition has no upper bound of its own: on a recording with no speech
    // in it, it sat for ninety seconds before saying so. Twice the length of
    // the audio, with a floor and a ceiling, is enough for real speech and
    // bounded for everything else.
    let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    let budget = min(max(seconds * 2, 30), 600)

    // A long recording is recognised a stretch at a time, and each answer
    // holds only its own stretch. Keeping just the final one returned the last
    // minute of a three-minute recording and called it the transcript.
    let stretches = Stretches()
    let task = recognizer.recognitionTask(with: request) { result, error in
      if let error {
        // What was heard before the error is still what was said.
        let heard = stretches.text
        gate.finish(heard.isEmpty ? .failure(error) : .success(heard))
        return
      }
      guard let result else { return }
      progress(0.5)
      stretches.add(result.bestTranscription.formattedString)
      if result.isFinal {
        gate.finish(.success(stretches.text))
      }
    }
    let deadline = Task {
      try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
      gate.finish(.failure(ProcessingError.conversionFailed(
        reason: "Nothing was transcribed within \(Int(budget)) seconds."
      )))
    }
    defer {
      deadline.cancel()
      task.cancel()
    }

    return try await gate.value()
  }
}

/// The transcript so far, a stretch at a time.
///
/// An answer either carries on from the one before - the same words and more -
/// in which case it replaces it, or starts afresh, in which case it follows it.
private final class Stretches: @unchecked Sendable {
  private let lock = NSLock()
  private var parts: [String] = []

  func add(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    if let last = parts.last, trimmed.hasPrefix(last) {
      parts[parts.count - 1] = trimmed
    } else if let last = parts.last, last.hasPrefix(trimmed) {
      return
    } else {
      parts.append(trimmed)
    }
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return parts.joined(separator: " ")
  }
}

/// Delivers the recogniser's answer once, from whichever callback arrives.
private final class ResultGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var pending: Result<String, Error>?
  private var settled = false

  func finish(_ result: Result<String, Error>) {
    lock.lock()
    guard !settled else { lock.unlock(); return }
    settled = true
    let waiting = continuation
    continuation = nil
    if waiting == nil { pending = result }
    lock.unlock()
    waiting?.resume(with: result)
  }

  func value() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let pending {
        lock.unlock()
        continuation.resume(with: pending)
        return
      }
      self.continuation = continuation
      lock.unlock()
    }
  }
}
