import UniformTypeIdentifiers
import XCTest
@testable import Forge

/// A scan is read for as long as it takes, and the window goes on being drawn.
@MainActor
final class ReadingAsideTests: BaseTestCase {
  private func longestWait(while work: @escaping @Sendable () async throws -> Void) async throws -> TimeInterval {
    let task = Task.detached { try await work() }
    var last = Date(), longest: TimeInterval = 0, isOver = false
    Task { _ = try? await task.value; isOver = true }
    while !isOver {
      try await Task.sleep(nanoseconds: 5_000_000)
      longest = max(longest, Date().timeIntervalSince(last))
      last = Date()
    }
    try await task.value
    return longest
  }

  func test_aScanBecomingADocumentDoesNotStopTheWindow() async throws {
    let scan = try Fixture.scannedPDF(at: path("scan.pdf"), pages: (1...8).map { "Page number \($0) of some words to read" })
    let out = try folder("out"), coordinator = ProcessingCoordinator(settings: AppSettings(), persistence: store)
    for type in [UTType.rtf, .html] {
      let began = Date()
      let wait = try await longestWait {
        _ = try await coordinator.processFile(
          try ProcessableFile(url: scan), with: RulePreset(name: "t", description: "", category: .custom, actions: [.convertFormat(to: type)]),
          destinationMode: .copyTo, destinationURL: out
        ) { _ in }
      }
      XCTAssertGreaterThan(Date().timeIntervalSince(began), 0.4, "too quick to tell anything")
      XCTAssertLessThan(wait, 0.25, "\(type)")
    }
  }
}
