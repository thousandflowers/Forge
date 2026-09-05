import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// How much runs at once, and what happens when the Mac says it has had enough.
///
/// The machine is mocked throughout: a test whose result depends on how warm
/// this particular Mac is at this particular moment is not a test.
final class BatchEngineTests: BaseTestCase {

  private static let laptop = BatchEngine.Capability(cores: 10, memoryGB: 16, isAppleSilicon: true)
  private static let modest = BatchEngine.Capability(cores: 2, memoryGB: 4, isAppleSilicon: false)

  private func engine(
    _ capability: BatchEngine.Capability = BatchEngineTests.laptop
  ) -> BatchEngine {
    BatchEngine(capability: capability, watchesTheSystem: false)
  }

  // MARK: - What the machine can take

  /// One media engine, however many cores there are.
  func test_limits_areAboutTheHardwareEachKindOfWorkUses() {
    XCTAssertEqual(Self.laptop.limit(for: .video), 2, "two, so one starts while the other finishes")
    XCTAssertGreaterThan(Self.laptop.limit(for: .image), Self.laptop.limit(for: .video))
    XCTAssertLessThanOrEqual(Self.laptop.limit(for: .text), 3, "the neural engine is shared")
  }

  func test_limits_scaleWithTheMachine() {
    for workload in BatchEngine.Workload.allCases {
      XCTAssertGreaterThanOrEqual(Self.laptop.limit(for: workload), Self.modest.limit(for: workload))
      XCTAssertGreaterThanOrEqual(Self.modest.limit(for: workload), 1, "never nothing at all")
    }
    XCTAssertEqual(Self.modest.limit(for: .video), 1, "an Intel Mac with two cores gets one")
  }

  /// Images are bounded by memory rather than by cores: a decoded photograph is
  /// a quarter of a gigabyte, and eight at once is how a batch takes a Mac
  /// down.
  func test_imageLimit_followsTheMemoryOnTheMachine() {
    let small = BatchEngine.Capability(cores: 16, memoryGB: 4, isAppleSilicon: true)
    let large = BatchEngine.Capability(cores: 16, memoryGB: 64, isAppleSilicon: true)
    XCTAssertLessThan(small.limit(for: .image), large.limit(for: .image))
  }

  /// A preference can ask for less than the machine could manage, never more.
  func test_theUsersCeiling_onlyEverLowersIt() async {
    let engine = engine()
    await engine.acquire(.image, ceiling: 1)
    let limit = await engine.limit(for: .image)
    XCTAssertEqual(limit, 1)
    await engine.release(.image)
  }

  // MARK: - Holding the line

  func test_acquire_neverLetsMoreThroughThanTheLimit() async {
    let engine = engine()
    let limit = await engine.limit(for: .video)
    let watcher = HighWaterMark()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask {
          await engine.acquire(.video)
          watcher.entered()
          try? await Task.sleep(nanoseconds: 20_000_000)
          watcher.left()
          await engine.release(.video)
        }
      }
    }

    XCTAssertEqual(watcher.highest, limit, "the limit is a limit, not a suggestion")
    let running = await engine.running(.video)
    XCTAssertEqual(running, 0, "and everything that took a slot gave it back")
  }

  /// Two kinds of work do not queue behind each other: a video and a photograph
  /// use different hardware.
  func test_oneKindOfWorkDoesNotBlockAnother() async {
    let engine = engine()
    let videoLimit = await engine.limit(for: .video)
    for _ in 0..<videoLimit { await engine.acquire(.video) }

    let started = expectation(description: "the image goes ahead anyway")
    Task {
      await engine.acquire(.image)
      started.fulfill()
    }
    await fulfillment(of: [started], timeout: 2)
  }

  // MARK: - Backing off

  func test_pressure_shrinksTheLimitAndLetsItBackAfterwards() async {
    let engine = engine()
    let ordinary = await engine.limit(for: .image)

    await engine.pressureChanged(to: .thermal)
    let warm = await engine.limit(for: .image)
    XCTAssertLessThan(warm, ordinary, "a warm Mac is asked for less")

    await engine.pressureChanged(to: .memory)
    let tight = await engine.limit(for: .image)
    XCTAssertEqual(tight, 1, "memory pressure ends in a Mac nobody can use, so it goes to one")

    await engine.pressureChanged(to: .none)
    let recovered = await engine.limit(for: .image)
    XCTAssertEqual(recovered, ordinary, "and it comes back when the pressure does not")
  }

  /// Pressure lifting has to reach work that is already waiting.
  func test_pressureLifting_releasesWhatWasHeldBack() async {
    let engine = engine()
    await engine.pressureChanged(to: .memory)
    await engine.acquire(.image)  // the only slot there is

    let second = expectation(description: "the next one gets in once the pressure lifts")
    Task {
      await engine.acquire(.image)
      second.fulfill()
    }

    await Task.yield()
    await engine.pressureChanged(to: .none)
    await fulfillment(of: [second], timeout: 2)
  }

  // MARK: - Pause

  func test_pause_stopsNewStartsAndResumeLetsThemGo() async {
    let engine = engine()
    await engine.pause()

    let started = expectation(description: "held until resumed")
    Task {
      await engine.acquire(.image)
      started.fulfill()
    }

    await Task.yield()
    let paused = await engine.isPaused
    XCTAssertTrue(paused)

    await engine.resume()
    await fulfillment(of: [started], timeout: 2)
  }

  // MARK: - Cancelling

  /// The invariant that matters: a cancelled conversion leaves the original
  /// alone and takes its scratch file with it.
  func test_cancel_leavesTheOriginalAloneAndNoScratchBehind() async throws {
    let source = try Fixture.image(at: path("holiday.png"), width: 1200, height: 900)
    let before = size(of: source)
    let destination = try folder("out")
    let coordinator = coordinator()

    let file = try ProcessableFile(url: source)
    let task = Task {
      try await coordinator.processFile(
        file,
        with: .make(format: .jpeg, category: .image),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
    }
    await coordinator.cancel(file.id)
    _ = try? await task.value

    XCTAssertEqual(size(of: source), before, "the file the user has is untouched")
    let left = try FileManager.default.contentsOfDirectory(
      at: destination, includingPropertiesForKeys: nil
    )
    XCTAssertTrue(
      left.allSatisfy { !$0.lastPathComponent.hasPrefix(".forge-") },
      "no scratch file outlives a cancellation"
    )
  }

  /// Stopping one file is stopping one file.
  func test_cancellingOneFile_leavesItsSiblingsAlone() async throws {
    let sources = try (1...3).map { try Fixture.image(at: path("shot-\($0).png")) }
    let destination = try folder("out")
    let coordinator = coordinator()
    let files = try sources.map { try ProcessableFile(url: $0) }

    let report = await Batch.run(
      files,
      preset: .make(format: .jpeg, category: .image),
      mode: .copyTo,
      destination: destination,
      limit: 1,
      coordinator: coordinator,
      engine: engine()
    ) { event in
      // Stop the first one the moment it starts; the other two are not its
      // business.
      if case .started(let id) = event, id == files[0].id {
        Task { await coordinator.cancel(id) }
      }
    }

    XCTAssertEqual(report.converted + report.cancelled, 3)
    XCTAssertEqual(report.failed, 0, "cancelling one is not failing the others")
    XCTAssertGreaterThanOrEqual(report.converted, 2, "its siblings finished")
  }

  // MARK: - Which hardware a file is for

  func test_workload_isReadFromWhatTheFileIs() throws {
    let image = try ProcessableFile(url: try Fixture.image(at: path("holiday.png")))
    XCTAssertEqual(BatchEngine.Workload.of(image, writing: .jpeg), .image)
    XCTAssertEqual(
      BatchEngine.Workload.of(image, writing: .plainText), .text,
      "an image asked for words is a Vision job, not an ImageIO one"
    )
  }

  /// Counts how many were inside at once.
  private final class HighWaterMark: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0

    func entered() {
      lock.lock()
      current += 1
      peak = max(peak, current)
      lock.unlock()
    }

    func left() {
      lock.lock()
      current -= 1
      lock.unlock()
    }

    var highest: Int {
      lock.lock()
      defer { lock.unlock() }
      return peak
    }
  }
}
