import XCTest
@testable import Forge

final class TurnsTests: XCTestCase {
  private actor Count {
    var now = 0, most = 0, done: [Int] = []
    func begin() { now += 1; most = max(most, now) }
    func end(_ index: Int) { now -= 1; done.append(index) }
  }

  func test_soManyAtATime_andAllOfThem() async throws {
    let turns = Turns(), count = Count()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<60 {
        group.addTask {
          try? await turns.take(of: 3) {
            await count.begin()
            try? await Task.sleep(nanoseconds: 3_000_000)
            await count.end(index)
          }
        }
      }
    }
    let most = await count.most, done = await count.done
    XCTAssertEqual(done.sorted(), Array(0..<60))
    XCTAssertLessThanOrEqual(most, 3)
    XCTAssertGreaterThan(most, 1)
  }

  func test_oneThatFailsOrIsStoppedGivesItsTurnUp() async throws {
    let turns = Turns()
    struct Failed: Error {}
    do { try await turns.take(of: 1) { throw Failed() } } catch {}
    let stopped = Task { try await turns.take(of: 1) { try await Task.sleep(nanoseconds: 5_000_000_000) } }
    try await Task.sleep(nanoseconds: 50_000_000)
    stopped.cancel()
    _ = try? await stopped.value
    let ran = try await turns.take(of: 1) { true }
    XCTAssertTrue(ran)
  }
}
