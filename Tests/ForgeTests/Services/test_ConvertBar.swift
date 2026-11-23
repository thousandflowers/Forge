import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// The button under the list of files: one place, and the words say whether
/// these files have been converted yet.
@MainActor
final class ConvertBarTests: BaseTestCase {

  /// Notifications need a bundled app; a test run is not one.
  private func quietModel() -> AppModel {
    let model = AppModel(persistence: store)
    model.settings.notifyWhenFinished = false
    return model
  }

  func test_theButtonSaysAgainOnlyAfterARun() async throws {
    let source = try Fixture.image(at: path("a.png"))
    let model = quietModel()
    let vm = BatchViewModel()
    vm.add([source])
    XCTAssertEqual(vm.convertTitle, "Convert…")
    XCTAssertTrue(vm.statusMap.isEmpty, "nothing is said about a file nobody has converted")

    await vm.convert(
      model: model,
      preset: RulePreset(name: "t", description: "", category: .image, actions: [.convertFormat(to: .jpeg)]),
      mode: .copyTo,
      destination: try folder("out")
    )
    XCTAssertEqual(vm.convertTitle, "Convert Again…")

    // A batch with a new file in it is one that has not been converted.
    vm.add([try Fixture.image(at: path("b.png"))])
    XCTAssertEqual(vm.convertTitle, "Convert…")
  }

  /// Dropping what is already listed changes nothing, so it is still "again".
  func test_droppingTheSameFileAgainIsNotANewBatch() async throws {
    let source = try Fixture.image(at: path("a.png"))
    let vm = BatchViewModel()
    vm.add([source])
    await vm.convert(
      model: quietModel(),
      preset: RulePreset(name: "t", description: "", category: .image, actions: [.convertFormat(to: .jpeg)]),
      mode: .copyTo,
      destination: try folder("out")
    )
    vm.add([source])
    XCTAssertEqual(vm.convertTitle, "Convert Again…")
  }

  func test_clearingStartsOver() async throws {
    let vm = BatchViewModel()
    vm.add([try Fixture.image(at: path("a.png"))])
    await vm.convert(
      model: quietModel(),
      preset: RulePreset(name: "t", description: "", category: .image, actions: [.convertFormat(to: .jpeg)]),
      mode: .copyTo,
      destination: try folder("out")
    )
    vm.clear()
    XCTAssertEqual(vm.convertTitle, "Convert…")
  }
}
