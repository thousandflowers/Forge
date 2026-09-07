import Foundation
import XCTest
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
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Left alone"), error.localizedDescription)
    }
    XCTAssertEqual(contents(of: out), [])
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
