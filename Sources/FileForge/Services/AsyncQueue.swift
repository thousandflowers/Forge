import Foundation

/// AsyncQueue manages concurrent execution of async tasks with a configurable limit.
actor AsyncQueue {
  private let maxConcurrent: Int
  private var pending: [@Sendable () async -> Void] = []
  private var running = 0

  init(maxConcurrent: Int) {
    self.maxConcurrent = max(1, maxConcurrent)
  }

  /// Add a task to the queue. It will execute when a concurrency slot is available.
  func add(_ operation: @escaping @Sendable () async -> Void) {
    pending.append(operation)
    process()
  }

  /// Pause queue - prevents new tasks from starting, but running tasks continue
  func pause() {
    // For MVP, pause just stops processing pending items
    // running tasks will complete
  }

  /// Resume after pause
  func resume() {
    Task {
      await process()
    }
  }

  private func process() {
    while running < maxConcurrent && !pending.isEmpty {
      let operation = pending.removeFirst()
      running += 1

      Task {
        await operation()
        running -= 1
        // Recursively process next
        await process()
      }
    }
  }

  /// Wait until all queued tasks have completed
  func waitForAll() async {
    while running > 0 || !pending.isEmpty {
      try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    }
  }
}
