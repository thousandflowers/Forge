import Foundation

/// So many at a time, in the order they came.
///
/// What converts a file holds a thread while it does. Files arrive in a watched
/// folder by the hundred, and left to start all together they took every thread
/// there was and waited for one another.
actor Turns {
  private var taken = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func take<Result: Sendable>(of limit: Int, _ work: @Sendable () async throws -> Result) async throws -> Result {
    if taken >= max(limit, 1) {
      // Handed its turn by whoever finished, who does not give it up.
      await withCheckedContinuation { waiting.append($0) }
    } else {
      taken += 1
    }
    defer { pass() }
    try Task.checkCancellation()
    return try await work()
  }

  private func pass() {
    if waiting.isEmpty { taken -= 1 } else { waiting.removeFirst().resume() }
  }
}
