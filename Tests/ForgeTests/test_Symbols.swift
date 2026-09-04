import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Forge

/// Every symbol the app names has to exist.
///
/// A name that does not resolve draws nothing at all - no warning, no
/// placeholder - so the video preset simply had no icon and nobody could tell
/// why. This is the check that would have caught it.
final class SymbolTests: XCTestCase {

  private func assertResolves(_ name: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotNil(
      NSImage(systemSymbolName: name, accessibilityDescription: nil),
      "\(what) names “\(name)”, which is not a symbol on this system",
      file: file,
      line: line
    )
  }

  func test_everyPresetCategoryHasAnIcon() {
    for category in PresetCategory.allCases {
      assertResolves(category.icon, "Category .\(category.rawValue)")
    }
  }

  func test_everyActionHasASymbol() {
    let actions: [Forge.Operation] = [
      .convertFormat(to: .jpeg),
      .resize(width: 1, height: 1, fitMode: .pad),
      .quality(level: 50),
      .filter(type: .sepia),
      .recognizeText(languages: []),
      .encode(codec: .h264),
    ]
    for action in actions {
      assertResolves(action.symbol, "Action \(action.title)")
    }
  }

  func test_everySectionHasAnIcon() {
    for section in AppSection.allCases {
      assertResolves(section.icon, "Section \(section.title)")
    }
  }

  func test_everyStatusHasAnIcon() {
    for status in ProcessingStatus.allCases {
      assertResolves(status.systemImage, "Status \(status.displayName)")
    }
  }

  func test_everyCapabilityHasASymbol() {
    for capability in Capabilities.all {
      assertResolves(capability.symbol, "Capability \(capability.title)")
    }
  }
}
