import Foundation
import SwiftUI
import XCTest
@testable import Forge

final class SettingsTests: XCTestCase {
  func testOlderSettingsWithoutAppearanceStillDecodeWhole() throws {
    var older = AppSettings()
    older.maxConcurrentNative = 4
    older.defaultQuality = 70
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any])
    json.removeValue(forKey: "appearance")
    let data = try JSONSerialization.data(withJSONObject: json)

    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

    XCTAssertEqual(decoded.maxConcurrentNative, 4)
    XCTAssertEqual(decoded.defaultQuality, 70)
    XCTAssertEqual(decoded.appearance, .system)
  }

  func testAppearanceRoundTripsAndMapsToColorScheme() throws {
    var settings = AppSettings()
    settings.appearance = .light

    let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

    XCTAssertEqual(back.appearance, .light)
    XCTAssertNil(Appearance.system.colorScheme)
    XCTAssertEqual(Appearance.light.colorScheme, .light)
    XCTAssertEqual(Appearance.dark.colorScheme, .dark)
  }
}
