import Foundation

/// Runs a set of conversions with a bound on how many happen at once.
///
/// The window and the command line both need this, and they need it to behave
/// the same way, so the awkward part - starting a new file the moment a slot
/// frees up, and stopping cleanly when asked - lives here once.
enum Batch {

  /// What happened to one file, as it happens.
  enum Event: Sendable {
    case started(id: UUID)
    case progress(id: UUID, fraction: Double)
    case finished(id: UUID, status: ProcessingStatus, output: URL?, error: String?)
  }

  struct Report: Sendable {
    var converted = 0
    var failed = 0
    var cancelled = 0
  }

  /// Convert `files`, reporting each step through `onEvent`.
  ///
  /// - Parameter shouldContinue: asked before each new file starts, so a cancel
  ///   stops the queue instead of only the work already running.
  static func run(
    _ files: [ProcessableFile],
    preset: RulePreset,
    mode: DestinationMode,
    destination: URL?,
    limit: Int,
    coordinator: ProcessingCoordinator,
    shouldContinue: @escaping @Sendable () -> Bool = { true },
    onEvent: @escaping @Sendable (Event) -> Void
  ) async -> Report {
    var report = Report()
    let slots = max(1, limit)

    await withTaskGroup(of: Event.self) { group in
      var next = 0

      func spawn() -> Bool {
        guard shouldContinue(), next < files.count else { return false }
        let file = files[next]
        next += 1

        onEvent(.started(id: file.id))
        group.addTask {
          do {
            let entry = try await coordinator.processFile(
              file,
              with: preset,
              destinationMode: mode,
              destinationURL: destination
            ) { fraction in
              onEvent(.progress(id: file.id, fraction: fraction))
            }
            return .finished(id: file.id, status: entry.status, output: entry.outputURL, error: entry.errorMessage)
          } catch is CancellationError {
            return .finished(id: file.id, status: .cancelled, output: nil, error: nil)
          } catch {
            return .finished(id: file.id, status: .failed, output: nil, error: error.localizedDescription)
          }
        }
        return true
      }

      for _ in 0..<slots where spawn() {}

      while let event = await group.next() {
        onEvent(event)
        if case .finished(_, let status, _, _) = event {
          switch status {
          case .completed: report.converted += 1
          case .cancelled: report.cancelled += 1
          default: report.failed += 1
          }
        }
        _ = spawn()
      }
    }

    return report
  }
}
