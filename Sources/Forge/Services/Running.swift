import Foundation

/// What is being converted now, wherever it was started from.
@MainActor
final class Running: ObservableObject {
  struct Job: Identifiable, Equatable {
    let id: UUID
    let file: URL
    var fraction: Double
  }

  /// What a conversion says of itself.
  enum Event: Sendable {
    case began(UUID, URL)
    case reached(UUID, Double)
    case ended(UUID, Outcome = .quiet)
  }

  /// What came of it.
  enum Outcome: Sendable, Equatable {
    /// What was done, as it is called.
    case done(String)
    case failed(String)
    case leftAlone(String)
    /// Stopped by hand, or nothing of Forge's.
    case quiet
  }

  @Published private(set) var jobs: [Job] = []
  /// One has ended, and there is a line more in the history.
  var ended: () -> Void = {}
  /// Whoever else wants to know, as it happens.
  var heard: (Event) -> Void = { _ in }

  private var telling: Task<Void, Never>?
  /// A batch ends many times a second, and the history is read once for all of them.
  private static let rest: UInt64 = 300_000_000
  /// A film says where it is many times a second.
  private static let step = 0.01

  /// In the order things happened: one that ended before it began would stay
  /// for good.
  func listen(to coordinator: ProcessingCoordinator) async {
    let (events, said) = AsyncStream.makeStream(of: Event.self)
    await coordinator.tell { said.yield($0) }
    for await event in events { hear(event) }
  }

  func hear(_ event: Event) {
    heard(event)
    switch event {
    case .began(let id, let file):
      guard !jobs.contains(where: { $0.id == id }) else { return }
      jobs.append(Job(id: id, file: file, fraction: 0))
    case .reached(let id, let fraction):
      guard let index = jobs.firstIndex(where: { $0.id == id }), fraction >= jobs[index].fraction + Self.step else { return }
      jobs[index].fraction = min(fraction, 1)
    case .ended(let id, _):
      jobs.removeAll { $0.id == id }
      guard telling == nil else { return }
      telling = Task { [weak self] in
        try? await Task.sleep(nanoseconds: Self.rest)
        self?.telling = nil
        self?.ended()
      }
    }
  }
}
