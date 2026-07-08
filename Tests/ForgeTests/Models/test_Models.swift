import XCTest
@testable import Forge

class ProcessableFileTests: BaseTestCase {
  func test_init_withValidPNG_extractsProperties() throws {
    // This test requires actual test file
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/BlueSquare.icns")
    if FileManager.default.fileExists(atPath: url.path) {
      let file = try ProcessableFile(url: url)
      XCTAssertTrue(file.fileSize > 0)
    }
  }

  func test_init_throwsForNonExistentFile() {
    let url = URL(fileURLWithPath: "/nonexistent/file.jpg")
    XCTAssertThrowsError(try ProcessableFile(url: url))
  }

  func test_init_throwsForUnknownExtension() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let url = tempDir.appendingPathComponent("file.xyz123")
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(try ProcessableFile(url: url))
  }
}

class OperationTests: BaseTestCase {
  func test_convertFormatCodable() throws {
    let op = Operation.convertFormat(to: .jpeg)
    let data = try JSONEncoder().encode(op)
    let decoded = try JSONDecoder().decode(Operation.self, from: data)

    if case .convertFormat(let to) = decoded {
      XCTAssertEqual(to, .jpeg)
    } else {
      XCTFail("Expected convertFormat")
    }
  }

  func test_resizeCodable() throws {
    let op = Operation.resize(width: 1920, height: 1080, fitMode: .cropCenter)
    let data = try JSONEncoder().encode(op)
    let decoded = try JSONDecoder().decode(Operation.self, from: data)

    if case .resize(let w, let h, let mode) = decoded {
      XCTAssertEqual(w, 1920)
      XCTAssertEqual(h, 1080)
      XCTAssertEqual(mode, .cropCenter)
    } else {
      XCTFail("Expected resize")
    }
  }

  func test_qualityCodable() throws {
    let op = Operation.quality(level: 85)
    let data = try JSONEncoder().encode(op)
    let decoded = try JSONDecoder().decode(Operation.self, from: data)

    if case .quality(let level) = decoded {
      XCTAssertEqual(level, 85)
    } else {
      XCTFail("Expected quality")
    }
  }

  func test_operationChainCodable() throws {
    let ops: [Operation] = [
      .convertFormat(to: .jpeg),
      .resize(width: 1080, height: 1080, fitMode: .cropCenter),
      .quality(level: 85),
      .filter(type: .grayscale)
    ]

    let data = try JSONEncoder().encode(ops)
    let decoded = try JSONDecoder().decode([Operation].self, from: data)
    XCTAssertEqual(ops, decoded)
  }
}

class RulePresetTests: BaseTestCase {
  func test_toOperations_producesCorrectChain() {
    let preset = RulePreset(
      name: "Instagram",
      description: "1080×1080 JPEG, 85% quality",
      targetFormat: .jpeg,
      resize: ResizeSpec(width: 1080, height: 1080, fitMode: .cropCenter),
      quality: 85,
      filters: [],
      category: .image
    )

    let ops = preset.toOperations()
    XCTAssertEqual(ops.count, 3)

    XCTAssertTrue(ops.contains {
      if case .convertFormat(let t) = $0 { return t == .jpeg } else { return false }
    })
    XCTAssertTrue(ops.contains {
      if case .resize(let w, let h, let mode) = $0 {
        return w == 1080 && h == 1080 && mode == .cropCenter
      }
      return false
    })
    XCTAssertTrue(ops.contains {
      if case .quality(let q) = $0 { return q == 85 } else { return false }
    })
  }

  func test_toOperations_empty_whenNoProperties() {
    let preset = RulePreset(
      name: "NoOp",
      description: "Does nothing",
      targetFormat: nil,
      resize: nil,
      quality: nil,
      filters: [],
      category: .custom
    )

    let ops = preset.toOperations()
    XCTAssertTrue(ops.isEmpty)
  }

  func test_toOperations_withFilter() {
    let preset = RulePreset(
      name: "B&W",
      description: "Grayscale",
      filters: [.grayscale],
      category: .image
    )

    let ops = preset.toOperations()
    XCTAssertEqual(ops.count, 1)
    if case .filter(let type) = ops[0] {
      XCTAssertEqual(type, .grayscale)
    } else {
      XCTFail("Expected filter operation")
    }
  }
}
