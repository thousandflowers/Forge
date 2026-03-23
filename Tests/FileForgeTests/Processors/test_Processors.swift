import XCTest
@testable import FileForge

class ImageProcessorTests: BaseTestCase {
  func test_canProcess_PNG() throws {
    let processor = ImageProcessor()
    // Create a mock file (we'd need actual test image)
    // For now, test type conformance
    let pngType = UTType.png
    XCTAssertTrue(processor.supportedTypes.contains(where: { pngType.conforms(to: $0) }))
  }

  func test_cannotProcess_Video() throws {
    let processor = ImageProcessor()
    let mp4Type = UTType.mp4
    XCTAssertFalse(processor.supportedTypes.contains(where: { mp4Type.conforms(to: $0) }))
  }
}

class VideoProcessorTests: BaseTestCase {
  func test_supportsMP4() {
    let processor = VideoProcessor()
    XCTAssertTrue(processor.supportedTypes.contains(.mp4))
  }

  func test_outputTypes_includeMP4() {
    let processor = VideoProcessor()
    let outputs = processor.supportedOutputTypes(for: .mov)
    XCTAssertTrue(outputs.contains(.mp4))
  }
}

class AudioProcessorTests: BaseTestCase {
  func test_supportsMP3() {
    let processor = AudioProcessor()
    XCTAssertTrue(processor.supportedTypes.contains(.mp3))
  }

  func test_outputTypes_includeM4A() {
    let processor = AudioProcessor()
    let outputs = processor.supportedOutputTypes(for: .wav)
    XCTAssertTrue(outputs.contains(.m4a))
  }
}

class SimpleDocProcessorTests: BaseTestCase {
  func test_supportsPDF() {
    let processor = SimpleDocProcessor()
    XCTAssertTrue(processor.supportedTypes.contains(.pdf))
  }

  func test_outputTypes_forPDF_includeJPEG() {
    let processor = SimpleDocProcessor()
    let outputs = processor.supportedOutputTypes(for: .pdf)
    XCTAssertTrue(outputs.contains(.jpeg))
  }
}
