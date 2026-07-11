import XCTest
import UniformTypeIdentifiers

/// Shared base class for Forge unit tests.
class BaseTestCase: XCTestCase {}

/// Convenience aliases for the UTTypes the test suite refers to by short name.
extension UTType {
  static var mp4: UTType { .mpeg4Movie }
  static var mov: UTType { .quickTimeMovie }
  // Match the codebase's canonical m4a identifier (see AudioProcessor).
  static var m4a: UTType { UTType("com.apple.m4a-audio")! }
}
