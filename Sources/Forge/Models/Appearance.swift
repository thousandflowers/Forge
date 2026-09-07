import SwiftUI

/// Which appearance the window uses: the Mac's own, or one chosen here.
enum Appearance: String, Codable, CaseIterable, Sendable {
  case system, light, dark

  var title: String {
    switch self {
    case .system: return "Follow the Mac"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  /// `nil` hands the choice back to the system, which is what "follow the
  /// Mac" has to do rather than pinning whichever one it happened to see.
  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}
