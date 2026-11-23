import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// The editor's Preview: the sample file after each step, measured, written
/// only to scratch.
final class PreviewRunnerTests: BaseTestCase {

  private func preset(_ actions: [Forge.Operation]) -> RulePreset {
    RulePreset(name: "Preview", description: "", category: .image, actions: actions)
  }

  func test_oneStagePerStepWithTheFormatOnEvery() {
    let stages = PreviewRunner.stages(of: preset([
      .convertFormat(to: .jpeg),
      .resize(width: 200, height: nil, fitMode: .proportional),
      .quality(level: 40),
    ]))
    XCTAssertEqual(stages.map(\.title), ["Resize", "Quality"])
    // Each stage writes the format, so the weights compare like with like.
    XCTAssertEqual(stages[0].preset.actions, [.convertFormat(to: .jpeg), .resize(width: 200, height: nil, fitMode: .proportional)])
    XCTAssertEqual(stages[1].preset.actions.count, 3)
  }

  func test_aChainWithForksIsShownWhole() {
    let whole = preset([.split([]), .quality(level: 50)])
    let stages = PreviewRunner.stages(of: whole)
    XCTAssertEqual(stages.count, 1)
    XCTAssertEqual(stages[0].title, "Result")
    XCTAssertEqual(stages[0].preset.actions, whole.actions)
  }

  func test_aPresetThatOnlyConvertsHasOneStage() {
    XCTAssertEqual(PreviewRunner.stages(of: preset([.convertFormat(to: .png)])).map(\.title), ["Result"])
  }

  func test_runningItMeasuresEveryStep() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 800, height: 600)
    let steps = try await PreviewRunner.run(
      sample: try ProcessableFile(url: source),
      preset: preset([.convertFormat(to: .jpeg), .resize(width: 200, height: nil, fitMode: .proportional), .quality(level: 40)]),
      coordinator: coordinator(),
      scratch: try folder("scratch")
    )

    XCTAssertEqual(steps.map(\.title), ["Original", "Resize", "Quality"])
    XCTAssertEqual(steps[0].url, source.standardizedFileURL)
    XCTAssertEqual(steps[1].width, 200)
    XCTAssertEqual(steps[1].height, 150)
    XCTAssertEqual(steps[2].url.pathExtension, "jpeg")
    XCTAssertTrue(steps.allSatisfy { $0.bytes > 0 })
    // Nothing lands beside the original.
    XCTAssertEqual(contents(of: source.deletingLastPathComponent()).filter { $0.hasPrefix("photo") }, ["photo.png"])
  }
}
