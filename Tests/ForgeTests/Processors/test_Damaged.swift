import XCTest
import UniformTypeIdentifiers
@testable import Forge

/// Files that say of themselves what cannot be. Each of these took the whole
/// app down with it; a file that is wrong is a file that is refused.
final class DamagedFileTests: BaseTestCase {
  private func refused(_ name: String, _ bytes: Data, as target: String, line: UInt = #line) async throws {
    let file = path(name)
    try bytes.write(to: file)
    let preset = RulePreset(name: "x", description: "", category: .custom, actions: [.convertFormat(to: try XCTUnwrap(UTType(filenameExtension: target)))])
    do {
      _ = try await coordinator().processFile(try ProcessableFile(url: file), with: preset, destinationMode: .copyTo, destinationURL: try folder("out")) { _ in }
      XCTFail("\(name) was taken for a file", line: line)
    } catch {}
  }

  private func bytes(_ count: Int, _ parts: [Int: [UInt8]]) -> Data {
    var made = Data(count: count)
    for (at, part) in parts { for (index, byte) in part.enumerated() { made[at + index] = byte } }
    return made
  }

  /// A table that begins after the file has ended.
  func test_dBaseThatBeginsAfterTheEnd() {
    let table = bytes(200, [0: [0x03], 4: [0xFF, 0xFF, 0, 0], 8: [0xFF, 0xFF], 10: [20, 0]])
    XCTAssertThrowsError(try Dbf.read(table))
  }

  /// A length that is further than a number goes.
  func test_aLargePhotoshopPictureWithALengthThatIsNot() async throws {
    let head: [Int: [UInt8]] = [0: Array("8BPS".utf8), 5: [2], 13: [3], 17: [8], 21: [8], 23: [8], 25: [3]]
    var negative = head, huge = head
    negative[34] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    huge[34] = [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    for parts in [negative, huge] {
      let file = path("a.psb")
      try bytes(400, parts).write(to: file)
      XCTAssertThrowsError(try Adobe.largePicture(file, to: path("a.png")))
    }
  }

  /// Wider than its own lines.
  func test_aPaintbrushPictureWiderThanItsLines() throws {
    let file = path("a.pcx")
    // 256 across, 4 down, 8 bits, one plane; four bytes to the line.
    try bytes(1200, [0: [10, 5, 0, 8], 8: [255, 0, 3, 0], 65: [1, 4, 0]]).write(to: file)
    XCTAssertThrowsError(try OldPictures.pcx(file, to: path("a.png")))
    // And with no table of colors.
    try bytes(160, [0: [10, 5, 0, 8], 8: [3, 0, 3, 0], 65: [1, 4, 0], 128: [UInt8](repeating: 250, count: 32)]).write(to: file)
    XCTAssertThrowsError(try OldPictures.pcx(file, to: path("a.png")))
  }

  /// A message that says it is longer than anything.
  func test_aMailThatSaysItIsLongerThanAnything() async throws {
    try await refused("a.emlx", Data("\(Int.max)\nFrom: x\n\nhi".utf8), as: "txt")
  }

  /// glTF is text, and text can say anything.
  func test_glTFWithNumbersThatAreNot() async throws {
    func glTF(_ view: String, _ index: String) -> Data {
      Data("""
      {"asset":{"version":"2.0"},"buffers":[{"byteLength":36,"uri":"data:;base64,\(Data(repeating: 0xFF, count: 72).base64EncodedString())"}],
      "bufferViews":[\(view)],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},\(index)],
      "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}
      """.utf8)
    }
    let index = #"{"bufferView":0,"componentType":5123,"count":3,"type":"SCALAR"}"#
    try await refused("offset.gltf", glTF(#"{"buffer":0,"byteOffset":9223372036854775807}"#, index.replacingOccurrences(of: "{", with: #"{"byteOffset":9223372036854775807,"#)), as: "stl")
    try await refused("stride.gltf", glTF(#"{"buffer":0,"byteStride":9223372036854775807}"#, index), as: "stl")
    try await refused("index.gltf", glTF(#"{"buffer":0}"#, #"{"bufferView":0,"componentType":5126,"count":3,"type":"SCALAR"}"#), as: "stl")
  }

  /// A drawing that says it is larger than a number goes, or no size at all.
  func test_aDrawingAsLargeAsCannotBe() async throws {
    for (width, height) in [("640", "99999999999999999999999"), ("100", "1e999"), ("inf", "nan")] {
      let file = path("a.svg")
      try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="\#(width)" height="\#(height)" viewBox="0 0 9 1e400"><rect width="9" height="9"/></svg>"#.utf8).write(to: file)
      XCTAssertLessThanOrEqual(VectorProcessor.side(for: [], drawing: file), 16_384)
    }
  }

  /// A corner that is not a number, or not one there is.
  func test_x3dWithCornersThatAreNot() async throws {
    for corner in ["99999999999999999999", "nan", "-7", "inf"] {
      try await refused("a.x3d", Data(#"<X3D><Scene><Shape><IndexedFaceSet coordIndex="0 1 \#(corner) -1"><Coordinate point="0 0 0 1 0 0 0 1 0"/></IndexedFaceSet></Shape></Scene></X3D>"#.utf8), as: "obj")
    }
  }

  /// A number is looked for where there is nothing.
  func test_numbersAreLookedForOnlyWhereThereIsSomething() {
    let data = Data([1, 2, 3, 4])
    XCTAssertEqual(data.number(4, at: Int.max - 1), 0)
    XCTAssertEqual(data.big(4, at: Int.max - 1), 0)
    XCTAssertEqual(data.big(2, at: 2), 0x0304)
  }

  /// A layer said to be larger than the Mac.
  func test_aLayerTooLargeToBe() {
    XCTAssertThrowsError(try PSDLayers.unpacked(Data([0x81, 0]), to: Int.max / 2))
  }
}
