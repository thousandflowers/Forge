import Foundation
import UserNotifications

/// Tells the user a batch has finished, when they are not watching.
///
/// Permission is asked the first time a batch completes rather than at launch:
/// being asked for something before it is needed is how people learn to say no.
enum Notifier {

  static func batchFinished(converted: Int, failed: Int) async {
    guard await isAllowed() else { return }

    let content = UNMutableNotificationContent()
    content.title = failed == 0 ? "Conversion finished" : "Conversion finished with problems"
    content.body = summary(converted: converted, failed: failed)
    content.sound = failed == 0 ? nil : .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )
    try? await UNUserNotificationCenter.current().add(request)
  }

  static func summary(converted: Int, failed: Int) -> String {
    var parts: [String] = []
    parts.append(converted == 1 ? "1 file converted" : "\(converted) files converted")
    if failed > 0 { parts.append(failed == 1 ? "1 failed" : "\(failed) failed") }
    return parts.joined(separator: ", ") + "."
  }

  private static func isAllowed() async -> Bool {
    let centre = UNUserNotificationCenter.current()
    let settings = await centre.notificationSettings()

    switch settings.authorizationStatus {
    case .authorized, .provisional:
      return true
    case .denied:
      return false
    default:
      return (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
    }
  }
}
