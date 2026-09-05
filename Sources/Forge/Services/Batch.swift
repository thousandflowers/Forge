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
    /// `outputs` is every file the conversion wrote, not only the first: a
    /// preset asking for two formats writes two, and a watched folder that
    /// hears about one of them converts the other again.
    case finished(id: UUID, status: ProcessingStatus, output: URL?, outputs: [URL], error: String?)
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
        // Its place in the batch, counting from one, for a name template that
        // numbers them. Taken here rather than in the coordinator: the batch is
        // the only thing that knows there is a sequence.
        let position = next + 1
        next += 1

        onEvent(.started(id: file.id))
        group.addTask {
          do {
            let entry = try await coordinator.processFile(
              file,
              with: preset,
              destinationMode: mode,
              destinationURL: destination,
              counter: position
            ) { fraction in
              onEvent(.progress(id: file.id, fraction: fraction))
            }
            return .finished(
              id: file.id,
              status: entry.status,
              output: entry.outputURL,
              outputs: entry.outputs,
              error: entry.errorMessage
            )
          } catch is CancellationError {
            return .finished(id: file.id, status: .cancelled, output: nil, outputs: [], error: nil)
          } catch {
            return .finished(
              id: file.id, status: .failed, output: nil, outputs: [], error: error.localizedDescription
            )
          }
        }
        return true
      }

      for _ in 0..<slots where spawn() {}

      while let event = await group.next() {
        onEvent(event)
        if case .finished(_, let status, _, _, _) = event {
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
