import Foundation

/// Turns batch events into terminal output.
///
/// Progress goes to stderr and results to stdout, so `forge convert … > list.txt`
/// captures the files without the chatter.
final class Reporter: @unchecked Sendable {
  private let names: [UUID: String]
  private let quiet: Bool
  private let lock = NSLock()

  init(names files: [ProcessableFile], quiet: Bool) {
    self.names = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.fileName) })
    self.quiet = quiet
  }

  func report(_ event: Batch.Event) {
    guard case .finished(let id, let status, let output, _, let error) = event else { return }
    let name = names[id] ?? "?"

    lock.lock()
    defer { lock.unlock() }

    switch status {
    case .completed:
      guard !quiet else { return }
      print(output?.path ?? name)
    case .cancelled:
      write(stderr: "cancelled  \(name)")
    default:
      write(stderr: "failed     \(name): \(error ?? "unknown error")")
    }
  }

  static func summary(_ report: Batch.Report) -> String {
    var parts = ["\(report.converted) converted"]
    if report.failed > 0 { parts.append("\(report.failed) failed") }
    if report.cancelled > 0 { parts.append("\(report.cancelled) cancelled") }
    return parts.joined(separator: ", ") + "."
  }

  private func write(stderr line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }
}
