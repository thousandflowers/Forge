import Foundation

/// How far into a film ffmpeg is, from the notes it keeps as it goes.
///
/// A film with every setting turned up takes an hour, and a bar that stands
/// still for an hour is a program that has stopped.
final class FilmProgress: @unchecked Sendable {
  private static let interval = 0.5
  /// Where the bar was before ffmpeg began, and where it leaves off for the
  /// rest to finish.
  private static let range = 0.1...0.98

  private let notes = FileManager.default.temporaryDirectory.appendingPathComponent("forge-progress-\(UUID().uuidString)")
  private let timer: DispatchSourceTimer
  private var furthest = range.lowerBound

  var arguments: [String] { ["-progress", notes.path] }

  init(length: Double, report: @escaping @Sendable (Double) -> Void) {
    timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "forge.film-progress"))
    timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
    timer.setEventHandler { [weak self] in
      guard let self, length > 0, let text = try? String(contentsOf: self.notes, encoding: .utf8),
            let seconds = Self.seconds(in: text) else { return }
      let share = min(max(seconds / length, 0), 1)
      let now = Self.range.lowerBound + (Self.range.upperBound - Self.range.lowerBound) * share
      guard now > self.furthest else { return }
      self.furthest = now
      report(now)
    }
    timer.resume()
  }

  func finish() {
    timer.cancel()
    try? FileManager.default.removeItem(at: notes)
  }

  static func seconds(in notes: String) -> Double? {
    notes.split(separator: "\n").last { $0.hasPrefix("out_time_us=") }
      .flatMap { Double($0.dropFirst("out_time_us=".count)) }.map { $0 / 1_000_000 }
  }
}
