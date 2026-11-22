import XCTest
import AVFoundation
@testable import Forge

/// A video comes out at the size that was asked for, not at the nearest
/// export preset: 320 × 180 used to stay 640 × 360, and a width on its own
/// did nothing at all.
final class VideoResizeTests: BaseTestCase {

  private func resized(_ spec: ResizeSpec, from size: CGSize = CGSize(width: 640, height: 360)) async throws -> CGSize {
    let source = try await Fixture.video(at: path("clip-\(UUID().uuidString).mp4"), size: size, withAudio: false)
    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .mp4, resize: spec, category: .video),
      destinationMode: .copyTo,
      destinationURL: try folder("out-\(UUID().uuidString)")
    ) { _ in }
    let output = AVURLAsset(url: try XCTUnwrap(entry.outputURL))
    let tracks = try await output.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let natural = try await track.load(.naturalSize)
    return CGSize(width: abs(natural.width), height: abs(natural.height))
  }

  func test_aBoxSmallerThanEveryPresetIsHonoured() async throws {
    let size = try await resized(ResizeSpec(width: 320, height: 180, fitMode: .proportional))
    XCTAssertEqual(size, CGSize(width: 320, height: 180))
  }

  func test_aWidthOnItsOwnKeepsTheShape() async throws {
    let size = try await resized(ResizeSpec(width: 320, height: nil, fitMode: .proportional))
    XCTAssertEqual(size, CGSize(width: 320, height: 180))
  }

  func test_cropCenterFillsTheBoxExactly() async throws {
    let size = try await resized(ResizeSpec(width: 200, height: 200, fitMode: .cropCenter))
    XCTAssertEqual(size, CGSize(width: 200, height: 200))
  }

  func test_geometryMatchesWhatImagesDo() {
    let natural = CGSize(width: 640, height: 360)
    XCTAssertEqual(MediaProcessor.renderSize(natural: natural, width: 320, height: nil, mode: .proportional), CGSize(width: 320, height: 180))
    XCTAssertEqual(MediaProcessor.renderSize(natural: natural, width: nil, height: 90, mode: .proportional), CGSize(width: 160, height: 90))
    XCTAssertEqual(MediaProcessor.renderSize(natural: natural, width: 500, height: 500, mode: .proportional), CGSize(width: 500, height: 282))
    XCTAssertEqual(MediaProcessor.renderSize(natural: natural, width: 500, height: 500, mode: .pad), CGSize(width: 500, height: 500))
    XCTAssertEqual(MediaProcessor.renderSize(natural: natural, width: 301, height: 301, mode: .stretch), CGSize(width: 302, height: 302), "encoders want even sides")
    XCTAssertNil(MediaProcessor.renderSize(natural: natural, width: nil, height: nil, mode: .proportional))
  }
}

/// Cancelling the caller stops the conversion: the CLI's Ctrl-C and the
/// editor's Preview both cancel from outside, and the export used to carry on
/// to the end regardless, leaving its scratch and its empty name behind.
final class CancellationReachesTheExportTests: BaseTestCase {
  func test_cancellingTheCallerStopsAndClearsUp() async throws {
    let source = try await Fixture.video(at: path("long.mp4"), seconds: 20, size: CGSize(width: 1920, height: 1080), withAudio: false)
    let out = try folder("out")
    let coordinator = coordinator()
    let file = try ProcessableFile(url: source)
    let run = Task {
      try await coordinator.processFile(
        file,
        with: .make(format: .mov, resize: ResizeSpec(width: 1280, height: nil, fitMode: .proportional), category: .video),
        destinationMode: .copyTo,
        destinationURL: out
      ) { _ in }
    }
    try await Task.sleep(nanoseconds: 600_000_000)
    let cancelledAt = Date()
    run.cancel()
    _ = try? await run.value
    XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 3, "the export ran on after the cancel")
    XCTAssertEqual(contents(of: out), [], "nothing is left behind")
  }
}
