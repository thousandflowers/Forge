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

  /// The same, as people call them.
  static let languages: [(tag: String, name: String)] = supportedLocales
    .map { ($0.replacingOccurrences(of: "_", with: "-"), Locale.current.localizedString(forIdentifier: $0) ?? $0) }
    .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }

  static func supports(_ locale: String) -> Bool {
    supportedLocales.contains { $0.caseInsensitiveCompare(locale) == .orderedSame }
      || supportedLocales.contains { $0.hasPrefix(locale + "-") || $0.hasPrefix(locale + "_") }
  }

  /// The recogniser's way of saying that nobody spoke. It has no name for it
  /// in the SDK, only this number.
  static func isSilence(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == "kAFAssistantErrorDomain" && error.code == 1110
  }

  /// Ask once, and report what the answer was.
  static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
    let current = SFSpeechRecognizer.authorizationStatus()
    guard current == .notDetermined else { return current }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
  }

  /// A word, and when it was said.
  struct Word: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }
  }

  /// What was said, and when each word was.
  struct Heard: Sendable {
    let text: String
    let words: [Word]
  }

  /// Transcribe `url`, which may be audio or a video with a soundtrack.
  ///
  /// - Parameter locale: BCP-47 tag, or nil for the system's own.
  static func text(
    of url: URL,
    locale: String?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> String {
    try await hear(url, locale: locale, progress: progress).text
  }

  static func hear(
    _ url: URL,
    locale: String?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> Heard {
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

    // One recording at a time. Handed several at once - which is what a batch
    // does - the recogniser answered most of them "No speech detected".
    await Turn.shared.take()
    do {
      let heard = try await recognise(url, locale: locale, progress: progress)
      await Turn.shared.give()
      return heard
    } catch {
      await Turn.shared.give()
      throw error
    }
  }

  private static func recognise(
    _ url: URL,
    locale: String?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> Heard {
    let chosen = locale.map(Locale.init(identifier:)) ?? Locale.current
    guard let recognizer = SFSpeechRecognizer(locale: chosen) else {
      throw ProcessingError.validationFailed(message: "There is no speech recognition for \(chosen.identifier).")
    }
    guard recognizer.isAvailable else {
      throw ProcessingError.conversionFailed(reason: "Speech recognition for \(chosen.identifier) is not available right now.")
    }

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    // Where a sentence ends is where a subtitle wants to.
    request.addsPunctuation = true
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
        gate.finish(.failure(error))
        return
      }
      guard let result else { return }
      progress(0.5)
      stretches.add(result.bestTranscription.formattedString, words: result.bestTranscription.segments.map {
        Word(text: $0.substring, start: $0.timestamp, duration: $0.duration)
      })
      if result.isFinal {
        gate.finish(.success(stretches.heard))
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

/// Whose turn it is with the recogniser: one caller holds it, the rest wait
/// in the order they came.
private actor Turn {
  static let shared = Turn()

  private var taken = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func take() async {
    guard taken else {
      taken = true
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  func give() {
    if waiting.isEmpty {
      taken = false
    } else {
      waiting.removeFirst().resume()
    }
  }
}

/// The transcript so far, a stretch at a time.
///
/// An answer either carries on from the one before - the same words and more -
/// in which case it replaces it, or starts afresh, in which case it follows it.
private final class Stretches: @unchecked Sendable {
  private let lock = NSLock()
  private var parts: [(text: String, words: [Transcription.Word])] = []

  func add(_ text: String, words: [Transcription.Word]) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    // Words said twice are kept twice: a repeat that looks like the start of
    // the stretch before it is still something that was said.
    if let last = parts.last?.text, trimmed.hasPrefix(last), trimmed != last {
      parts[parts.count - 1] = (trimmed, words)
    } else {
      parts.append((trimmed, words))
    }
  }

  var heard: Transcription.Heard {
    lock.lock()
    defer { lock.unlock() }
    return .init(text: parts.map(\.text).joined(separator: " "), words: parts.flatMap(\.words))
  }
}

/// Delivers the recogniser's answer once, from whichever callback arrives.
private final class ResultGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Transcription.Heard, Error>?
  private var pending: Result<Transcription.Heard, Error>?
  private var settled = false

  func finish(_ result: Result<Transcription.Heard, Error>) {
    lock.lock()
    guard !settled else { lock.unlock(); return }
    settled = true
    let waiting = continuation
    continuation = nil
    if waiting == nil { pending = result }
    lock.unlock()
    waiting?.resume(with: result)
  }

  func value() async throws -> Transcription.Heard {
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
