import XCTest
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
@testable import Forge

/// One test per defect the audit found in the conversion engine.
final class ConversionTests: BaseTestCase {

  // MARK: - Video

  /// Converting a video used to abort the process: the bitrate key sat at the
  /// top level of the writer settings, which AVFoundation rejects with an
  /// Objective-C exception Swift cannot catch.
  func test_video_convertsWithoutCrashing() async throws {
    let source = try await Fixture.video(at: path("clip.mp4"))
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .mov, category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(output.pathExtension, "mov")
    XCTAssertGreaterThan(size(of: output), 0)
  }

  /// Audio is written with `AVAudioFile`, which knows nothing about metadata,
  /// so a converted song came out with no title, no artist and no cover. The
  /// tags are now put back by a passthrough copy - measured before the fix on
  /// a real file: `ffprobe` reported title and artist on the source and
  /// nothing at all on the output.
  func test_audio_keepsItsTags() async throws {
    let source = try await Fixture.taggedAudio(
      at: path("song.m4a"), title: "Il Seme", artist: "Eugenio"
    )
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      // `.mpeg4Audio` is public.mpeg-4-audio, which nothing writes; the
      // container an .m4a actually is is com.apple.m4a-audio.
      with: .make(format: try XCTUnwrap(UTType(filenameExtension: "m4a")), category: .audio),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    let carried = try await AVURLAsset(url: output).load(.commonMetadata)
    var values: [String] = []
    for item in carried {
      if let value = try await item.load(.stringValue) { values.append(value) }
    }

    XCTAssertTrue(values.contains("Il Seme"), "the title did not survive: \(values)")
    XCTAssertTrue(values.contains("Eugenio"), "the artist did not survive: \(values)")
  }

  /// A container that cannot hold tags is not a failed conversion: the audio
  /// still has to come out, untagged and correct.
  func test_audio_stillConvertsToAContainerThatHoldsNoTags() async throws {
    let source = try await Fixture.taggedAudio(
      at: path("song.m4a"), title: "Il Seme", artist: "Eugenio"
    )
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: UTType.wav, category: .audio),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    XCTAssertGreaterThan(size(of: try XCTUnwrap(entry.outputURL)), 0)
  }

  /// Title, artist and artwork survive a conversion. Nothing in the code says
  /// so - an export session with no metadata of its own carries the source's
  /// across - which is exactly why this is pinned down: "improving" it by
  /// setting `session.metadata` to the common key space would silently narrow
  /// what crosses to the tags every container shares.
  func test_video_keepsItsTags() async throws {
    let source = try await Fixture.taggedVideo(
      at: path("tagged.mov"), title: "Tiger Grandmother", artist: "Eugenio"
    )
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .mpeg4Movie, category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    let carried = try await AVURLAsset(url: output).load(.commonMetadata)
    let values = try await withThrowingTaskGroup(of: String?.self) { group -> [String] in
      for item in carried {
        group.addTask { try await item.load(.stringValue) }
      }
      return try await group.compactMap { $0 }.reduce(into: []) { $0.append($1) }
    }

    XCTAssertTrue(values.contains("Tiger Grandmother"), "the title did not survive: \(values)")
    XCTAssertTrue(values.contains("Eugenio"), "the artist did not survive: \(values)")
  }

  /// The old pipeline read only the video track, so every converted file came
  /// out silent.
  func test_video_keepsTheAudioTrack() async throws {
    let source = try await Fixture.video(at: path("clip.mp4"), withAudio: true)
    let destination = try folder("out")

    let before = try await AVURLAsset(url: source).trackCounts()
    XCTAssertEqual(before.audio, 1, "the fixture itself must have audio")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .mov, category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let after = try await AVURLAsset(url: try XCTUnwrap(entry.outputURL)).trackCounts()
    XCTAssertEqual(after.video, 1)
    XCTAssertEqual(after.audio, 1, "the conversion dropped the audio track")
  }

  /// Resize used to be applied as a display transform, leaving the pixels at
  /// their original size, so a "720p" preset changed nothing.
  /// A width on its own means that width.
  ///
  /// It used to mean "that width, unless it is larger than the picture", because
  /// the side nobody named was filled in with the original and its ratio of
  /// exactly 1 became the floor. Asking for 1600 wide gave back 800.
  func test_image_resizeToAWidthLargerThanTheOriginal() async throws {
    let source = try Fixture.image(at: path("small.png"), width: 800, height: 600)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(
        format: .png,
        resize: ResizeSpec(width: 1600, height: nil, fitMode: .proportional),
        category: .image
      ),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    let size = try XCTUnwrap(try ProcessableFile(url: output).dimensions)
    XCTAssertEqual(size.width, 1600)
    XCTAssertEqual(size.height, 1200, "and the shape is kept")
  }

  /// The other direction still behaves, which is the case everybody was using.
  func test_image_resizeToAWidthSmallerThanTheOriginal() async throws {
    let source = try Fixture.image(at: path("big.png"), width: 800, height: 600)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(
        format: .png,
        resize: ResizeSpec(width: 400, height: nil, fitMode: .proportional),
        category: .image
      ),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let size = try XCTUnwrap(try ProcessableFile(url: try XCTUnwrap(entry.outputURL)).dimensions)
    XCTAssertEqual(size.width, 400)
    XCTAssertEqual(size.height, 300)
  }

  /// Both sides named is a box to fit inside, and that has not changed.
  func test_image_resizeInsideABoxTakesTheSmallerSide() async throws {
    let source = try Fixture.image(at: path("wide.png"), width: 1000, height: 200)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(
        format: .png,
        resize: ResizeSpec(width: 500, height: 500, fitMode: .proportional),
        category: .image
      ),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let size = try XCTUnwrap(try ProcessableFile(url: try XCTUnwrap(entry.outputURL)).dimensions)
    XCTAssertEqual(size.width, 500, "the wide side is what fits")
    XCTAssertEqual(size.height, 100)
  }

  func test_video_resizeChangesThePixels() async throws {
    let source = try await Fixture.video(
      at: path("big.mp4"),
      size: CGSize(width: 1280, height: 720),
      withAudio: false
    )
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .mov, resize: ResizeSpec(width: 640, height: 480, fitMode: .proportional), category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = AVURLAsset(url: try XCTUnwrap(entry.outputURL))
    let tracks = try await output.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let size = try await track.load(.naturalSize)
    XCTAssertLessThan(size.width, 1280, "the output kept the source width")
  }

  /// The preset is chosen from the names the system offers, not a fixed table.
  func test_videoPreset_picksTheSmallestPresetThatCoversTheRequest() {
    let available = [
      AVAssetExportPreset640x480,
      AVAssetExportPreset1280x720,
      AVAssetExportPreset1920x1080,
      AVAssetExportPresetHighestQuality,
    ]
    let chosen = MediaProcessor.videoPreset(
      for: [.resize(width: 800, height: 600, fitMode: .proportional)],
      available: available
    )
    XCTAssertEqual(chosen, AVAssetExportPreset1280x720)
  }

  func test_videoPreset_readsDimensionsOutOfThePresetName() {
    let parsed = MediaProcessor.dimensions(inPresetNamed: AVAssetExportPreset1920x1080)
    XCTAssertEqual(parsed?.width, 1920)
    XCTAssertEqual(parsed?.height, 1080)
    XCTAssertNil(MediaProcessor.dimensions(inPresetNamed: AVAssetExportPresetHighestQuality))
  }

  // MARK: - Audio

  /// Audio conversion aborted the process twice over: the encoder was hardcoded
  /// to AAC regardless of container, and compressed samples were handed to an
  /// encoding writer.
  func test_audio_convertsToEveryWritableContainer() async throws {
    let source = try Fixture.audio(at: path("tone.wav"), seconds: 2)
    let sourceDuration = CMTimeGetSeconds(AVURLAsset(url: source).duration)

    for type in FormatCatalog.writableAudioTypes.keys {
      let destination = try folder("out-\(type.preferredFilenameExtension ?? "x")")
      let entry = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: type, category: .audio),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }

      XCTAssertEqual(entry.status, .completed, "\(type.identifier) failed")
      let output = try XCTUnwrap(entry.outputURL)
      let duration = CMTimeGetSeconds(AVURLAsset(url: output).duration)
      XCTAssertEqual(duration, sourceDuration, accuracy: 0.2, "\(type.identifier) came out truncated")
    }
  }

  /// The writer was never awaited, so long files were reported complete while
  /// still being written. Two seconds of audio must arrive as two seconds.
  func test_audio_writesTheWholeFile() async throws {
    let source = try Fixture.audio(at: path("long.wav"), seconds: 5)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .m4a, category: .audio),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let duration = CMTimeGetSeconds(AVURLAsset(url: try XCTUnwrap(entry.outputURL)).duration)
    XCTAssertEqual(duration, 5, accuracy: 0.2)
  }

  /// Sample rate and channel count were forced to 44.1 kHz stereo, quietly
  /// resampling every mono recording.
  func test_audio_keepsTheSourceSampleRateAndChannels() async throws {
    let source = try Fixture.audio(at: path("mono.wav"), seconds: 1, sampleRate: 48_000, channels: 1)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .m4a, category: .audio),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let file = try AVAudioFile(forReading: try XCTUnwrap(entry.outputURL))
    XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
    XCTAssertEqual(file.fileFormat.channelCount, 1)
  }

  // MARK: - Images

  /// Re-encoding a JPEG as a JPEG is the commonest thing a converter is asked
  /// to do, and it was rejected outright as "source and destination formats
  /// are the same".
  func test_image_reencodingTheSameFormatIsAllowed() async throws {
    let source = try Fixture.image(at: path("photo.jpg"), width: 800, height: 600)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 20, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertLessThan(size(of: output), size(of: source), "quality 20 should shrink the file")
  }

  /// EXIF and friends were dropped on every conversion, despite a setting that
  /// claimed to preserve them.
  func test_image_keepsMetadata() async throws {
    let source = try Fixture.image(at: path("tagged.jpg"), metadata: [
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "forge-test"] as CFDictionary
    ])
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 90, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
    XCTAssertEqual(exif?[kCGImagePropertyExifUserComment] as? String, "forge-test")
  }

  /// Padding composited the blank canvas over the picture instead of under it,
  /// so the result was neither padded nor the requested size.
  func test_image_padProducesExactlyTheRequestedSize() async throws {
    let source = try Fixture.image(at: path("wide.png"), width: 400, height: 100)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .png, resize: ResizeSpec(width: 300, height: 300, fitMode: .pad), category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let dimensions = try XCTUnwrap(ProcessableFile(url: try XCTUnwrap(entry.outputURL)).dimensions)
    XCTAssertEqual(dimensions.width, 300)
    XCTAssertEqual(dimensions.height, 300)
  }

  func test_image_cropCenterProducesExactlyTheRequestedSize() async throws {
    let source = try Fixture.image(at: path("wide.png"), width: 400, height: 100)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .png, resize: ResizeSpec(width: 200, height: 200, fitMode: .cropCenter), category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let dimensions = try XCTUnwrap(ProcessableFile(url: try XCTUnwrap(entry.outputURL)).dimensions)
    XCTAssertEqual(dimensions.width, 200)
    XCTAssertEqual(dimensions.height, 200)
  }

  /// WebP was offered as an output format although macOS ships no encoder, so
  /// the failure surfaced only at the very last step.
  func test_image_webpIsReadableButNotWritable() throws {
    let webp = try XCTUnwrap(UTType("org.webmproject.webp"))
    XCTAssertTrue(FormatCatalog.isReadableImage(webp), "WebP should still be readable")
    XCTAssertFalse(FormatCatalog.isWritableImage(webp), "macOS has no WebP encoder")
  }

  /// Asking for a format the machine cannot encode has to fail with a message
  /// that names both ends. Saying only "cannot write JPEG" for an MP3 reads as
  /// though JPEG were the problem.
  func test_image_unwritableFormatFailsCleanly() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 64, height: 64)
    let webp = try XCTUnwrap(UTType("org.webmproject.webp"))
    let destination = try folder("out")

    // macOS reads WebP and cannot write it, so Forge uses cwebp when the Mac
    // has one. Which of the two is true here depends on the machine, and the
    // test asserts whichever it is rather than assuming.
    do {
      let history = try await coordinator().processFile(
        try ProcessableFile(url: source),
        with: .make(format: webp, category: .image),
        destinationMode: .copyTo,
        destinationURL: destination
      ) { _ in }

      guard ExternalTools.locate("cwebp") != nil else {
        return XCTFail("writing WebP should fail on a Mac with no cwebp")
      }
      let output = try XCTUnwrap(history.outputURL)
      XCTAssertEqual(output.pathExtension, "webp")
      XCTAssertGreaterThan(size(of: output), 0, "cwebp is installed, so the file has to be real")
    } catch {
      XCTAssertNil(ExternalTools.locate("cwebp"), "cwebp is installed, so this should have worked")
      XCTAssertEqual(
        error.localizedDescription,
        "Forge cannot convert PNG to WEBP.",
        "the message has to name both ends of the conversion"
      )
    }
  }

  // MARK: - Documents

  /// Only the first page was ever rendered, from a preset that promises pages.
  func test_pdf_convertsEveryPage() async throws {
    let source = try Fixture.pdf(at: path("report.pdf"), pages: 3)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    XCTAssertEqual(contents(of: destination).count, 3, "expected one image per page")
  }

  /// Text "conversion" copied the bytes across, so HTML in meant HTML out.
  func test_html_convertsToPlainText() async throws {
    let source = path("page.html")
    try "<html><body><h1>Forge</h1><p>Hello</p></body></html>".write(to: source, atomically: true, encoding: .utf8)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .plainText, category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let text = try String(contentsOf: try XCTUnwrap(entry.outputURL), encoding: .utf8)
    XCTAssertFalse(text.contains("<h1>"), "the markup survived the conversion")
    XCTAssertTrue(text.contains("Forge"))
  }
}

/// Files that hold more than one image.
///
/// Forge used to read frame zero and throw the rest away, so an animated GIF
/// converted to a single still and a multi-page TIFF lost every page but one.
final class MultiFrameTests: BaseTestCase {

  func test_animationSurvivesAConversionToAnotherAnimatedFormat() async throws {
    let source = try Fixture.animatedGIF(at: path("loop.gif"), frames: 5)
    XCTAssertEqual(Self.frameCount(of: source), 5, "the fixture itself must animate")
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .gif, resize: ResizeSpec(width: 24, height: 24, fitMode: .stretch), category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(Self.frameCount(of: output), 5, "frames were dropped")
    XCTAssertEqual(try ProcessableFile(url: output).dimensions?.width, 24, "the resize skipped the frames")
  }

  /// A still format cannot hold an animation, so every frame becomes a file,
  /// the way PDF pages already do.
  func test_animationBecomesOneFilePerFrameInAStillFormat() async throws {
    let source = try Fixture.animatedGIF(at: path("loop.gif"), frames: 4)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 80, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    XCTAssertEqual(contents(of: destination), ["loop-002.jpeg", "loop-003.jpeg", "loop-004.jpeg", "loop.jpeg"])
  }

  func test_frameDelaysAreCarriedAcross() async throws {
    let source = try Fixture.animatedGIF(at: path("loop.gif"), frames: 3, delay: 0.25)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .gif, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let delay = try XCTUnwrap(Self.firstDelay(of: try XCTUnwrap(entry.outputURL)))
    XCTAssertEqual(delay, 0.25, accuracy: 0.02, "the timing was lost")
  }

  func test_aStillImageIsStillOneFile() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 64, height: 64)
    let destination = try folder("out")

    _ = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .jpeg, quality: 80, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(contents(of: destination), ["photo.jpeg"])
  }

  private static func frameCount(of url: URL) -> Int {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
    return CGImageSourceGetCount(source)
  }

  private static func firstDelay(of url: URL) -> Double? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return nil }
    return gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
      ?? gif[kCGImagePropertyGIFDelayTime] as? Double
  }
}

/// A video asked to become an image is a frame export.
final class VideoToImagesTests: BaseTestCase {

  func test_videoBecomesAnAnimatedGIF() async throws {
    let source = try await Fixture.video(
      at: path("clip.mp4"),
      seconds: 1,
      size: CGSize(width: 320, height: 240),
      withAudio: false
    )
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .gif, category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(output.pathExtension, "gif")

    let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
    // One second at twelve frames a second, give or take the final sample.
    XCTAssertGreaterThan(CGImageSourceGetCount(gif), 8)
    XCTAssertEqual(contents(of: destination), ["clip.gif"], "an animation is one file")
  }

  func test_videoBecomesOneImagePerFrameInAStillFormat() async throws {
    let source = try await Fixture.video(
      at: path("clip.mp4"),
      seconds: 1,
      size: CGSize(width: 160, height: 120),
      withAudio: false
    )
    let destination = try folder("out")

    _ = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .png, category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    // A video taken apart is a set, not a sequel: the frames go into a folder
    // named after the clip rather than loose in the destination.
    XCTAssertEqual(contents(of: destination), ["clip"])
    let frames = contents(of: destination.appendingPathComponent("clip"))
    XCTAssertGreaterThan(frames.count, 8)
    XCTAssertTrue(frames.contains("clip.png"))
    XCTAssertTrue(frames.contains("clip-002.png"))
  }

  /// A GIF at the source resolution is unusable at any length, so frames are
  /// capped unless the preset says otherwise.
  func test_framesAreCappedUnlessAskedOtherwise() async throws {
    let source = try await Fixture.video(
      at: path("big.mp4"),
      seconds: 1,
      size: CGSize(width: 1920, height: 1080),
      withAudio: false
    )
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .gif, category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let width = try XCTUnwrap(ProcessableFile(url: try XCTUnwrap(entry.outputURL)).dimensions?.width)
    XCTAssertLessThanOrEqual(width, 640)
    XCTAssertGreaterThan(width, 320, "capping should not shrink it to nothing")
  }

  func test_aRequestedSizeWins() async throws {
    let source = try await Fixture.video(
      at: path("big.mp4"),
      seconds: 1,
      size: CGSize(width: 1920, height: 1080),
      withAudio: false
    )
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .gif, resize: ResizeSpec(width: 200, height: 200, fitMode: .proportional), category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let width = try XCTUnwrap(ProcessableFile(url: try XCTUnwrap(entry.outputURL)).dimensions?.width)
    XCTAssertLessThanOrEqual(width, 200)
  }
}

/// The other direction: an animation becomes a movie.
final class ImagesToVideoTests: BaseTestCase {

  func test_animatedGIFBecomesAVideo() async throws {
    let source = try Fixture.animatedGIF(at: path("loop.gif"), frames: 12, size: 64, delay: 0.1)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .mpeg4Movie, category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let output = try XCTUnwrap(entry.outputURL)
    XCTAssertEqual(output.pathExtension, "mp4")

    let asset = AVURLAsset(url: output)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 1)

    // Twelve frames at a tenth of a second each.
    let duration = try await asset.load(.duration).seconds
    XCTAssertEqual(duration, 1.2, accuracy: 0.3)
  }

  /// A round trip has to keep the motion: video to GIF and back again.
  func test_videoToGIFAndBackKeepsTheFrames() async throws {
    let source = try await Fixture.video(
      at: path("clip.mp4"),
      seconds: 1,
      size: CGSize(width: 160, height: 120),
      withAudio: false
    )
    let gifFolder = try folder("gif")
    let backFolder = try folder("back")
    let coordinator = coordinator()

    let toGIF = try await coordinator.processFile(
      try ProcessableFile(url: source),
      with: .make(format: .gif, category: .video),
      destinationMode: .copyTo,
      destinationURL: gifFolder
    ) { _ in }

    let backToVideo = try await coordinator.processFile(
      try ProcessableFile(url: try XCTUnwrap(toGIF.outputURL)),
      with: .make(format: .mpeg4Movie, category: .video),
      destinationMode: .copyTo,
      destinationURL: backFolder
    ) { _ in }

    XCTAssertEqual(backToVideo.status, .completed, backToVideo.errorMessage ?? "")
    let asset = AVURLAsset(url: try XCTUnwrap(backToVideo.outputURL))
    let duration = try await asset.load(.duration).seconds
    XCTAssertEqual(duration, 1.0, accuracy: 0.4)
  }

  func test_aStillImageBecomesAOneFrameVideo() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 128, height: 96)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .quickTimeMovie, category: .video),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(entry.status, .completed, entry.errorMessage ?? "")
    let tracks = try await AVURLAsset(url: try XCTUnwrap(entry.outputURL))
      .loadTracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 1)
  }
}

/// Images and PDF, in both directions.
final class ImagePDFTests: BaseTestCase {

  func test_imageBecomesPDF() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 300, height: 200)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .pdf, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    let pdf = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(entry.outputURL)))
    XCTAssertEqual(pdf.pageCount, 1)
  }

  /// PDF holds many images, so an animation becomes one document rather than a
  /// pile of files.
  func test_ananimationBecomesAMultiPagePDF() async throws {
    let source = try Fixture.animatedGIF(at: path("loop.gif"), frames: 5)
    let destination = try folder("out")

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .pdf, category: .image),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(contents(of: destination), ["loop.pdf"], "one document, not one file per frame")
    let pdf = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(entry.outputURL)))
    XCTAssertEqual(pdf.pageCount, 5)
  }

  func test_pdfBecomesImages() async throws {
    let source = try Fixture.pdf(at: path("report.pdf"), pages: 3)
    let destination = try folder("out")

    _ = try await coordinator().processFile(
      try ProcessableFile(url: source),
      with: .make(format: .png, category: .document),
      destinationMode: .copyTo,
      destinationURL: destination
    ) { _ in }

    XCTAssertEqual(contents(of: destination).count, 3)
  }
}
