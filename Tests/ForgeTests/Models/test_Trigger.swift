import Foundation
import XCTest
import os
@testable import Forge

final class TriggerTests: BaseTestCase {
  func testARenamedFileAsksForThePresetByItsWord() {
    var preset = RulePreset(name: "Web", description: "", category: .image, actions: [.quality(level: 70)])
    preset.nameTrigger = "web"

    XCTAssertTrue(preset.isTriggered(by: URL(fileURLWithPath: "/tmp/foto_web.jpg")))
    XCTAssertTrue(preset.isTriggered(by: URL(fileURLWithPath: "/tmp/foto_10MB_WEB.jpg")))
    XCTAssertFalse(preset.isTriggered(by: URL(fileURLWithPath: "/tmp/web_foto.jpg")), "the first piece is the name, not an instruction")
    XCTAssertFalse(preset.isTriggered(by: URL(fileURLWithPath: "/tmp/foto.jpg")))
    XCTAssertEqual(preset.untriggered(stem: "foto_10MB_web"), "foto_10MB")
    XCTAssertEqual(preset.untriggered(stem: "foto"), "foto")
  }

  func testAGateLeavesAFileAloneAndSaysSo() async throws {
    let small = try Fixture.image(at: path("small.png"), width: 300, height: 200)
    let out = try folder("out")
    var preset = RulePreset(name: "Big only", description: "", category: .image, actions: [.quality(level: 70)])
    var gate = Condition()
    gate.subject = .longestSide
    gate.comparison = .greaterThan
    gate.value = 1000
    preset.gate = gate

    do {
      _ = try await coordinator().processFile(try ProcessableFile(url: small), with: preset, destinationMode: .copyTo, destinationURL: out) { _ in }
      XCTFail("a file that fails the gate must not be converted")
    } catch ProcessingError.leftAlone(let reason) {
      XCTAssertTrue(reason.contains("Only if"), reason)
    }
    XCTAssertEqual(contents(of: out), [])
  }

  /// A file the "Only if" leaves alone is the preset working: counted as
  /// skipped, with the reason, and never as a failure.
  func testAFileLeftAloneIsSkippedNotFailed() async throws {
    let small = try ProcessableFile(url: try Fixture.image(at: path("small.png"), width: 300, height: 200))
    let big = try ProcessableFile(url: try Fixture.image(at: path("big.png"), width: 1600, height: 900))
    var preset = RulePreset(name: "Big only", description: "", category: .image, actions: [.quality(level: 70)])
    var gate = Condition()
    gate.subject = .longestSide
    gate.comparison = .greaterThan
    gate.value = 1000
    preset.gate = gate

    let seen = OSAllocatedUnfairLock(initialState: [UUID: (ProcessingStatus, String?)]())
    let report = await Batch.run(
      [small, big], preset: preset, mode: .copyTo, destination: try folder("out"),
      limit: 2, coordinator: coordinator()
    ) { event in
      if case .finished(let id, let status, _, _, let error) = event { seen.withLock { $0[id] = (status, error) } }
    }

    XCTAssertEqual(report.converted, 1)
    XCTAssertEqual(report.skipped, 1)
    XCTAssertEqual(report.failed, 0)
    let smallOne = seen.withLock { $0[small.id] }
    XCTAssertEqual(smallOne?.0, .skipped)
    XCTAssertEqual(smallOne?.1, "Longest side is 300 px. Only if: longest side is more than 1000 px.")
    XCTAssertEqual(Reporter.summary(report), "1 converted, 1 skipped.")
  }

  func testTriggerAndGateSurviveJSON() throws {
    var preset = RulePreset(name: "p", description: "", category: .image, actions: [.quality(level: 70)])
    preset.nameTrigger = "web"
    preset.gate = Condition()

    let back = try JSONDecoder().decode(RulePreset.self, from: JSONEncoder().encode(preset))

    XCTAssertEqual(back.nameTrigger, "web")
    XCTAssertEqual(back.gate, Condition())
  }
}
