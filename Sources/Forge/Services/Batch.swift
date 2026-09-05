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
  /// Every file is started at once and then waits its turn: how many actually
  /// run is `BatchEngine`'s business, per kind of work and per how the Mac is
  /// coping. A suspended task costs almost nothing, and the alternative - this
  /// counting its own slots - could only ever count one kind of thing.
  ///
  /// - Parameter shouldContinue: asked before each file starts, so a cancel
  ///   stops the queue instead of only the work already running.
  /// - Parameter limit: what the user asked for in Settings. A ceiling on the
  ///   engine's own answer, never a way to ask for more.
  static func run(
    _ files: [ProcessableFile],
    preset: RulePreset,
    mode: DestinationMode,
    destination: URL?,
    limit: Int,
    coordinator: ProcessingCoordinator,
    engine: BatchEngine = .shared,
    shouldContinue: @escaping @Sendable () -> Bool = { true },
    onEvent: @escaping @Sendable (Event) -> Void
  ) async -> Report {
    var report = Report()
    let ceiling = max(1, limit)

    await withTaskGroup(of: Event?.self) { group in
      for (index, file) in files.enumerated() {
        let workload = BatchEngine.Workload.of(file, writing: preset.targetFormat)
        group.addTask {
          await engine.acquire(workload, ceiling: ceiling)
          defer { Task { await engine.release(workload) } }

          // Asked after waiting rather than before: a batch cancelled while
          // this was in the queue must not start now.
          guard shouldContinue() else {
            return .finished(id: file.id, status: .cancelled, output: nil, outputs: [], error: nil)
          }

          onEvent(.started(id: file.id))
          do {
            let entry = try await coordinator.processFile(
              file,
              with: preset,
              destinationMode: mode,
              destinationURL: destination,
              // Its place in the batch, counting from one, for a name template
              // that numbers them.
              counter: index + 1
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
      }

      for await event in group {
        guard let event else { continue }
        onEvent(event)
        if case .finished(_, let status, _, _, _) = event {
          switch status {
          case .completed: report.converted += 1
          case .cancelled: report.cancelled += 1
          default: report.failed += 1
          }
        }
      }
    }

    return report
  }
}
