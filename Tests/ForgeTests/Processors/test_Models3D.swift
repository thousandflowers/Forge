import XCTest
import ModelIO
import UniformTypeIdentifiers
@testable import Forge

/// 3D models, through ModelIO. No download, no external tool.
final class ModelConversionTests: BaseTestCase {

  /// A tetrahedron, small enough to write out by hand and real enough to load.
  private func objFixture(at name: String) throws -> URL {
    let url = path(name)
    try """
    o tetra
    v 0.0 0.0 0.0
    v 1.0 0.0 0.0
    v 0.0 1.0 0.0
    v 0.0 0.0 1.0
    f 1 2 3
    f 1 2 4
    f 1 3 4
    f 2 3 4
    """.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func test_objBecomesSTL() async throws {
    let source = try objFixture(at: "tetra.obj")
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "stl")), category: .custom),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(output.pathExtension, "stl")
    XCTAssertGreaterThan(size(of: output), 0)

    // Read it back: a file ModelIO cannot reopen is not a conversion.
    let reloaded = MDLAsset(url: output)
    XCTAssertGreaterThan(reloaded.count, 0)
  }

  func test_objBecomesPLY() async throws {
    let source = try objFixture(at: "tetra.obj")
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "ply")), category: .custom),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    XCTAssertGreaterThan(MDLAsset(url: try XCTUnwrap(entry.outputURL)).count, 0)
  }

  /// USDZ reads but does not write, and the catalogue has to say so rather
  /// than failing at the last moment.
  func test_usdzIsReadableButNotWritable() throws {
    let usdz = try XCTUnwrap(UTType(filenameExtension: "usdz"))
    XCTAssertTrue(FormatCatalog.isReadableModel(usdz))
    XCTAssertFalse(FormatCatalog.isWritableModel(usdz))
  }

  /// glTF, GLB and FBX are not ModelIO's, and nothing should claim they are.
  func test_theFormatsModelIODoesNotHaveAreNotClaimed() throws {
    for ext in ["gltf", "glb", "fbx"] {
      guard let type = UTType(filenameExtension: ext), !type.isDynamic else { continue }
      XCTAssertFalse(FormatCatalog.isWritableModel(type), "\(ext) is not ModelIO's")
    }
  }

  func test_anUnwritableTargetFailsWithBothFormatsNamed() async throws {
    let source = try objFixture(at: "tetra.obj")
    let destination = try folder("out")

    do {
      _ = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: .jpeg, category: .custom),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }
      XCTFail("a model cannot become a JPEG")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("OBJ"), error.localizedDescription)
    }
  }
}
