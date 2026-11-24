import Foundation
import AppKit
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers

/// Audio and video conversion, both handled through AVFoundation's own
/// pipelines.
///
/// Audio and video live together because the distinction is a property of the
/// file, not of its extension: a `.mov` carrying only an audio track is an
/// audio file, and deciding from the extension is how every `.wav` ended up
/// routed to a processor that had never really supported it.
///
/// Both paths delegate encoding to AVFoundation rather than pumping sample
/// buffers by hand. The hand-rolled version dropped audio tracks, ignored
/// resize requests, reported success on unfinished files, and crashed the
/// process outright on malformed writer settings.
final class MediaProcessor: FileProcessor, @unchecked Sendable {
  let name = "Media Processor"

  func canProcess(_ file: ProcessableFile) -> Bool {
    FormatCatalog.isReadableMedia(file.fileType)
  }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    // A subtitle is the track inside the film where there is one, and what is
    // said in it where there is not.
    let name = Conversions.fileExtension(of: target)
    if Subtitles.carriesCues(name) { return Subtitles.writes(name) }
    // Words are a transcript; sound and film containers are what this writes.
    if Self.isWords(target) { return true }
    if FormatCatalog.audioFormatID(for: target) != nil || FormatCatalog.isWritableVideo(target) { return true }
    // Frames, of something that has a picture.
    return !file.fileType.conforms(to: .audio) && FormatCatalog.isWritableImage(target)
  }

  func process(
    _ input: URL,
    to output: URL,
    with operations: [Operation],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let start = Date()
    let asset = AVURLAsset(url: input)

    let videoTracks: [AVAssetTrack]
    let audioTracks: [AVAssetTrack]
    do {
      videoTracks = try await asset.loadTracks(withMediaType: .video)
      audioTracks = try await asset.loadTracks(withMediaType: .audio)
    } catch is CancellationError {
      // A stopped batch is a cancelled row, not a damaged file.
      throw CancellationError()
    } catch {
      // AVFoundation's own words are "Cannot Open", in the system language,
      // which say neither what nor why. It lists AVI and MPEG among the files
      // it reads and opens few of them, so "damaged" was said of files that
      // play: a tool that can do the pair is asked before anything is said.
      throw Self.handedOn(input, to: output) ?? ProcessingError.conversionFailed(
        reason: "\(input.lastPathComponent) cannot be opened by macOS: it may use a codec macOS has no reader for, "
          + "or be damaged or still arriving.\(Self.whatWouldRead)"
      )
    }

    guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
      throw ProcessingError.conversionFailed(
        reason: "\(input.lastPathComponent) contains no audio or video tracks"
      )
    }

    // What is done to it before it becomes anything else: cut, sped up, muted.
    let edit = MediaEdit(operations)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("forge-edit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    func edited() async throws -> AVAsset {
      guard !edit.isNothing else { return asset }
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      return try await MediaRender.prepare(asset, edit, in: scratch).asset
    }
    /// The sound to listen to, or to write: the file itself while nothing in
    /// it is changed.
    func heard(_ input: URL) async throws -> URL {
      guard edit.changesSound else { return input }
      return try await MediaRender.firstSound(of: try await edited(), like: input, in: scratch) ?? input
    }

    // Media asked for text is transcribed, whether the words are in a
    // recording or in the soundtrack of a video.
    let wanted = Self.outputType(for: output, operations: operations, fallback: .mpeg4Movie)
    if edit.isMuted, Self.isSoundOnly(wanted) || Self.isWords(wanted) || Subtitles.carriesCues(output.pathExtension) {
      throw ProcessingError.conversionFailed(reason: Self.nothingLeft(of: input))
    }
    // Anything with a soundtrack asked for words becomes words. Which words
    // file it becomes is up to the extension: a recording renamed .rtf comes
    // out as RTF, .docx as DOCX, .pdf as a PDF of the transcript.
    // A subtitle asked of a video is the track that is already in it. Nothing
    // here reads subtitle samples, so that goes to the tools, which is what
    // declining it arranges. With no track in it - a recording, a clip straight
    // from the phone - it is what is said, with the times it was said at.
    if Subtitles.carriesCues(output.pathExtension) {
      let hasATrack = try await Self.carriesSubtitles(asset)
      // Its own subtitles are what was asked for. Somebody else's hearing of
      // it, in their place and under the same name, is not.
      if hasATrack, ExternalTools.locate("ffmpeg") == nil {
        throw ProcessingError.conversionFailed(
          reason: "\(input.lastPathComponent) has subtitles in it, and taking them out needs ffmpeg.\(Self.whatWouldRead)"
        )
      }
      // ffmpeg takes the track out, and writes fewer kinds of subtitle than Forge.
      if hasATrack, Subtitles.writes(output.pathExtension), let ffmpeg = ExternalTools.locate("ffmpeg"),
         !ExternalBridge.couldPlan(from: input.pathExtension.lowercased(), to: output.pathExtension.lowercased()) {
        let words = FileManager.default.temporaryDirectory.appendingPathComponent("forge-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: words) }
        try ExternalTools.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + MediaEdit(operations).ffmpegInput + ["-i", input.path, "-map", "0:s:0", words.path])
        return try await SubtitleProcessor().process(words, to: output, with: operations, progress: progress)
      }
      guard !hasATrack, Subtitles.writes(output.pathExtension) else {
        throw ProcessingError.unsupportedConversion(
          from: UTType(filenameExtension: input.pathExtension) ?? .movie,
          to: wanted
        )
      }
      guard !audioTracks.isEmpty else {
        throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no sound to turn into subtitles")
      }
      return try await transcribeCues(try await heard(input), of: input, to: output, operations: operations, start: start, progress: progress)
    }

    if Self.isWords(wanted), !audioTracks.isEmpty {
      return try await transcribe(
        try await heard(input), of: input, to: output, as: wanted, operations: operations, start: start, progress: progress
      )
    }
    // Words asked of a film with no soundtrack: there is nothing to write down,
    // which is not the same as these two formats being impossible.
    if Self.isWords(wanted) {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no sound to turn into words")
    }

    // Settings macOS has no way to honour are ffmpeg's. Written here they would
    // be dropped, and the film come out looking as if nothing had been said.
    if !videoTracks.isEmpty, operations.film != nil, wanted.conforms(to: .movie) || wanted.conforms(to: .video) {
      guard ExternalTools.locate("ffmpeg") != nil else {
        throw ProcessingError.conversionFailed(reason: "Film settings need ffmpeg: brew install ffmpeg")
      }
      throw ProcessingError.unsupportedConversion(
        from: UTType(filenameExtension: input.pathExtension) ?? .movie, to: wanted
      )
    }

    if edit.isEvened, audioTracks.isEmpty {
      throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no sound to even out")
    }

    if videoTracks.isEmpty {
      // Audio asked for a movie container is wrapped rather than converted:
      // the export writes the track into the container as it stands.
      let requestedType = Self.outputType(for: output, operations: operations, fallback: .mpeg4Audio)
      if FormatCatalog.isWritableVideo(requestedType) {
        return try await handingOn(input, to: output) { try await exportVideoWithinItsCeiling(try await edited(), of: asset, to: output, operations: operations, start: start, progress: progress) }
      }
      return try await handingOn(input, to: output) { try await convertAudio(try await heard(input), of: input, to: output, operations: operations, start: start, progress: progress) }
    }

    // A video asked to become an image is a frame export, not a re-encode:
    // this is what turns a clip into an animated GIF, or into a folder of
    // stills.
    let requested = Self.outputType(for: output, operations: operations, fallback: .mpeg4Movie)
    if FormatCatalog.isWritableImage(requested) {
      return try await exportFrames(
        try await edited(), to: output, as: requested, operations: operations, start: start, progress: progress
      )
    }

    // A film asked for a sound format gives up its soundtrack. An export
    // session would happily put the picture in an .m4a as well, because M4A is
    // MPEG-4 underneath; nothing that opens an .m4a expects one.
    if Self.isSoundOnly(requested) {
      guard !audioTracks.isEmpty else {
        throw ProcessingError.conversionFailed(reason: "\(input.lastPathComponent) has no sound to keep")
      }
      return try await handingOn(input, to: output) { try await convertAudio(try await heard(input), of: input, to: output, operations: operations, start: start, progress: progress) }
    }

    return try await handingOn(input, to: output) { try await exportVideoWithinItsCeiling(try await edited(), of: asset, to: output, operations: operations, start: start, progress: progress) }
  }

  /// A ceiling is a promise about the file, and an export session treats it as
  /// an aim: asked for 500 kB it wrote 554. So it is asked again for less, in
  /// proportion to how far over it went, until what it writes fits.
  private func exportVideoWithinItsCeiling(
    _ edited: AVAsset,
    of asset: AVURLAsset,
    to output: URL,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    guard let ceiling = ImageProcessor.sizeCeiling(from: operations) else {
      let result = try await exportVideo(edited, of: asset, to: output, operations: operations, start: start, progress: progress)
      try await Self.checkNothingWasLeftBehind(from: asset, in: output, edit: MediaEdit(operations))
      return result
    }
    var aim = ceiling
    var smallest = Int64.max
    for _ in 0..<4 {
      let aimed = operations.map { operation -> Operation in
        if case .limitSize = operation { return .limitSize(bytes: aim) }
        return operation
      }
      try? FileManager.default.removeItem(at: output)
      let result = try await exportVideo(edited, of: asset, to: output, operations: aimed, start: start, progress: progress)
      if result.outputSize <= Int64(ceiling) {
        try await Self.checkNothingWasLeftBehind(from: asset, in: output, edit: MediaEdit(operations))
        return result
      }
      smallest = min(smallest, result.outputSize)
      aim = max(1, Int(Double(aim) * Double(ceiling) / Double(result.outputSize) * 0.95))
    }
    try? FileManager.default.removeItem(at: output)
    throw ProcessingError.tooBig(
      reason: "\(asset.url.lastPathComponent) cannot be made to fit in "
        + "\(Int64(ceiling).formatted(.byteCount(style: .file))): the smallest it came out was "
        + "\(smallest.formatted(.byteCount(style: .file))). A smaller picture would fit; so would a shorter film."
    )
  }

  /// The tracks a film had that the export did not carry. An export session
  /// keeps one soundtrack, drops sound it cannot put in the container (MP3 in
  /// an MP4) and drops subtitles - all without a word, so a film with a
  /// commentary track or with subtitles came back without them, "converted".
  /// What it left behind is said, and a tool that keeps every track is asked
  /// instead where there is one.
  private static func checkNothingWasLeftBehind(from asset: AVURLAsset, in output: URL, edit: MediaEdit) async throws {
    func count(_ asset: AVAsset, _ kinds: [AVMediaType]) async -> Int {
      var total = 0
      for kind in kinds { total += ((try? await asset.loadTracks(withMediaType: kind)) ?? []).count }
      return total
    }
    let written = AVURLAsset(url: output)
    let captions: [AVMediaType] = [.subtitle, .closedCaption, .text]
    var lost: [String] = []
    // ffprobe sees tracks macOS does not: an MP4's MP3 soundtrack is not there
    // at all as far as AVFoundation is concerned, so its loss was invisible.
    let soundBefore = max(await count(asset, [.audio]), streams(of: asset.url, kind: "audio"))
    let soundAfter = max(await count(written, [.audio]), streams(of: output, kind: "audio"))
    if !edit.isMuted, soundAfter < soundBefore {
      lost.append(soundAfter == 0 ? "its sound" : "\(soundBefore - soundAfter) of its \(soundBefore) soundtracks")
    }
    if edit.keepsSubtitles, await count(asset, captions) > 0, await count(written, captions) == 0 { lost.append("its subtitles") }
    guard !lost.isEmpty else { return }

    try? FileManager.default.removeItem(at: output)
    if let handOn = handedOn(asset.url, to: output) { throw handOn }
    throw ProcessingError.conversionFailed(
      reason: "macOS would leave out \(lost.joined(separator: " and ")) of \(asset.url.lastPathComponent), "
        + "so it was not converted. ffmpeg keeps every track: brew install ffmpeg"
    )
  }

  /// The cover picture and the chapters, which the tags do not include: a
  /// song's cover was lost into FLAC and M4B, and an audiobook's chapters into
  /// anything at all. Copied across by ffmpeg where it is installed, without
  /// touching the sound already written.
  /// - Parameter chapters: not where the time they are in is another.
  private static func carryCoverAndChapters(from input: URL, to output: URL, chapters carriesChapters: Bool) {
    guard let ffmpeg = ExternalTools.locate("ffmpeg"), let ffprobe = ExternalTools.locate("ffprobe") else { return }
    func probe(_ url: URL, _ arguments: [String]) -> String {
      ExternalTools.answer(of: ffprobe, ["-v", "error"] + arguments + ["-of", "csv=p=0", url.path])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func cover(_ url: URL) -> Bool {
      probe(url, ["-select_streams", "v", "-show_entries", "stream_disposition=attached_pic"]).contains("1")
    }
    func chapters(_ url: URL) -> Int {
      probe(url, ["-show_chapters"]).split(whereSeparator: \.isNewline).count
    }
    let wantsCover = cover(input) && !cover(output) && !["wav", "aiff", "aif", "caf"].contains(output.pathExtension.lowercased())
    let wantsChapters = carriesChapters && chapters(input) > 0 && chapters(output) == 0
    guard wantsCover || wantsChapters else { return }

    let together = output.deletingLastPathComponent()
      .appendingPathComponent(".forge-extras-\(UUID().uuidString).\(output.pathExtension)")
    defer { try? FileManager.default.removeItem(at: together) }
    var arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", output.path, "-i", input.path,
                     "-map", "0", "-map_metadata", "0"]
    if wantsCover { arguments += ["-map", "1:v:0", "-disposition:v:0", "attached_pic"] }
    arguments += ["-map_chapters", wantsChapters ? "1" : "0", "-c", "copy", together.path]
    // Worth having and not worth failing a finished conversion over.
    guard (try? ExternalTools.run(ffmpeg, arguments)) != nil,
          FileManager.default.fileExists(atPath: together.path) else { return }
    _ = try? FileManager.default.replaceItemAt(output, withItemAt: together)
  }

  /// How many streams of a kind ffprobe finds, or zero without ffprobe.
  static func streams(of url: URL, kind: String) -> Int {
    guard let ffprobe = ExternalTools.locate("ffprobe") else { return 0 }
    return ExternalTools.answer(of: ffprobe, [
      "-v", "error", "-select_streams", kind == "audio" ? "a" : "s", "-show_entries", "stream=index", "-of", "csv=p=0", url.path,
    ]).split(whereSeparator: \.isNewline).count
  }

  // MARK: - What macOS could not do

  /// Run the work; if macOS itself gave up on it - a codec it has no reader
  /// for, a sample rate its encoder will not take - hand the pair to a tool
  /// that can, or say which tool would. Its own error was a number: "Core
  /// Audio error 1954115647".
  private func handingOn(
    _ input: URL, to output: URL, _ work: () async throws -> ProcessingResult
  ) async throws -> ProcessingResult {
    do {
      return try await work()
    } catch let error as ProcessingError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.handedOn(input, to: output) ?? ProcessingError.conversionFailed(
        reason: "macOS cannot make \(input.lastPathComponent) into \(output.pathExtension.uppercased()) "
          + "(\(error.localizedDescription)).\(Self.whatWouldRead)"
      )
    }
  }

  /// "This pair is not mine", if a tool here would take it: the coordinator
  /// then asks the next processor, which is the tools.
  private static func handedOn(_ input: URL, to output: URL) -> ProcessingError? {
    let source = input.pathExtension.lowercased()
    let target = output.pathExtension.lowercased()
    guard ExternalBridge.couldPlan(from: source, to: target) else { return nil }
    return .unsupportedConversion(
      from: UTType(filenameExtension: source) ?? .movie, to: UTType(filenameExtension: target) ?? .data
    )
  }

  private static var whatWouldRead: String {
    ExternalTools.locate("ffmpeg") == nil ? " ffmpeg reads most of what macOS does not: brew install ffmpeg" : ""
  }

  static func nothingLeft(of input: URL) -> String { "\(input.lastPathComponent) without its sound has nothing left to write." }

  /// Audio that is not also a movie: `.m4a`, `.wav`, `.flac`, not `.mp4`.
  static func isSoundOnly(_ type: UTType) -> Bool {
    type.conforms(to: .audio) && !type.conforms(to: .movie)
  }

  // MARK: - Words out of a recording

  /// Whether a type is somewhere words can be written: plain text, or any of
  /// the document formats AppKit writes.
  static func isWords(_ type: UTType) -> Bool {
    type.conforms(to: .plainText) || DocumentText.canWrite(type)
  }

  /// Whether there are subtitles in it already.
  private static func carriesSubtitles(_ asset: AVURLAsset) async throws -> Bool {
    // Not `.text`: that is where chapter titles live.
    for type in [AVMediaType.subtitle, .closedCaption] where !(try await asset.loadTracks(withMediaType: type)).isEmpty {
      return true
    }
    return false
  }

  /// The language to listen for: recognition's and transcription's are one
  /// question, which language is this in.
  private static func spoken(in operations: [Operation]) -> String? {
    operations.compactMap { operation -> String? in
      guard case .recognizeText(let languages) = operation else { return nil }
      return languages.first
    }.first
  }

  private func transcribeCues(
    _ sound: URL,
    of input: URL,
    to output: URL,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let silent = ProcessingError.conversionFailed(
      reason: "There are no subtitles in \(input.lastPathComponent), and nothing is said in it to make them from"
    )
    let heard: Transcription.Heard
    do {
      heard = try await Transcription.hear(sound, locale: Self.spoken(in: operations), progress: progress)
    } catch where Transcription.isSilence(error) {
      throw silent
    }
    let cues = Subtitles.cues(from: heard.words)
    guard !cues.isEmpty else { throw silent }
    try Subtitles.write(cues, to: output)
    progress(1)
    return ProcessingResult(
      outputURL: output,
      outputSize: (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  private func transcribe(
    _ sound: URL,
    of input: URL,
    to output: URL,
    as wanted: UTType,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let text = try await Transcription.text(of: sound, locale: Self.spoken(in: operations), progress: progress)

    if wanted.conforms(to: .plainText) {
      try text.write(to: output, atomically: true, encoding: .utf8)
    } else {
      // AppKit's document writer belongs to the main actor, and so does the
      // attributed string it is handed: NSAttributedString is not Sendable.
      try await MainActor.run {
        try DocumentText.write(NSAttributedString(string: text), to: output, as: wanted)
      }
    }
    progress(1.0)

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    return ProcessingResult(
      outputURL: output,
      outputSize: attributes[.size] as? Int64 ?? 0,
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  // MARK: - Frames out of a video

  /// How often to sample when turning a video into frames. Twelve is the
  /// long-standing convention for an animated GIF: smooth enough to read, and
  /// small enough to send.
  private static let framesPerSecond: Double = 12

  /// Longest side of an exported frame when the preset does not say. A GIF at
  /// the source resolution is unusable at any length, so there is a default,
  /// and `--resize` overrides it.
  private static let defaultFrameSide: CGFloat = 640

  private func exportFrames(
    _ asset: AVAsset,
    to output: URL,
    as type: UTType,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let duration = try await asset.load(.duration).seconds
    guard duration > 0 else {
      throw ProcessingError.conversionFailed(reason: "The video has no duration to sample")
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    // Turned or cropped, the frames are drawn the way the film would be.
    if operations.tools.contains(where: { $0.kind == .crop || $0.kind == .turn }) {
      generator.videoComposition = try await Self.composition(for: asset, operations: operations)
    }
    generator.maximumSize = try await Self.frameSize(for: operations, asset: asset)

    // A whole number of hundredths of a second, because that is the only
    // delay a GIF can state: a twelfth of a second was written as 0.08 and the
    // animation ran four per cent fast. Sampling at what will be written keeps
    // it in time.
    let step = Self.interval(in: operations) ?? (100 / Self.framesPerSecond).rounded() / 100
    guard Self.interval(in: operations) == nil || duration / step <= Self.mostPictures else {
      throw ProcessingError.conversionFailed(reason: "That would make more than \(Int(Self.mostPictures)) pictures.")
    }
    let times = stride(from: 0, to: duration, by: step).map {
      CMTime(seconds: $0, preferredTimescale: 600)
    }
    guard !times.isEmpty else {
      throw ProcessingError.conversionFailed(reason: "The video is too short to sample")
    }

    // Stills are written as they are made. Held until the end, ninety seconds
    // of film was a gigabyte of frames in memory before the first was saved.
    if !FormatCatalog.holdsMultipleFrames(type) {
      var extras: [URL] = []
      var first: CGImage?
      for (index, time) in times.enumerated() {
        try Task.checkCancellation()
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        let destination = index == 0 ? output : output.numbered(index + 1, of: times.count)
        _ = try Self.writeFrames([ImageFrame(image: image, duration: step)], to: destination, as: type, operations: operations)
        if index == 0 { first = image } else { extras.append(destination) }
        progress(Double(index + 1) / Double(times.count))
      }
      return ProcessingResult(
        outputURL: output,
        outputSize: try Self.fileSize(output),
        outputDimensions: first.map { ($0.width, $0.height) },
        duration: Date().timeIntervalSince(start),
        additionalOutputs: extras
      )
    }

    var frames: [ImageFrame] = []
    frames.reserveCapacity(times.count)
    for (index, time) in times.enumerated() {
      try Task.checkCancellation()
      let image = try generator.copyCGImage(at: time, actualTime: nil)
      frames.append(ImageFrame(image: image, duration: step))
      progress(Double(index + 1) / Double(times.count) * 0.9)
    }

    let extras = try Self.writeFrames(frames, to: output, as: type, operations: operations)
    progress(1.0)

    return ProcessingResult(
      outputURL: output,
      outputSize: try Self.fileSize(output),
      outputDimensions: (frames[0].image.width, frames[0].image.height),
      duration: Date().timeIntervalSince(start),
      additionalOutputs: extras
    )
  }

  /// The size to sample at: what the preset asked for, or a readable default
  /// that never enlarges the source.
  private static func frameSize(for operations: [Operation], asset: AVAsset) async throws -> CGSize {
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      return CGSize(width: defaultFrameSide, height: defaultFrameSide)
    }
    // As it is shown: a film shot upright is stored on its side with a note to
    // turn it, and measured as stored its frames came out a third the size.
    let stored = try await track.load(.naturalSize)
    let turned = try await track.load(.preferredTransform)
    let natural = operations.tools.contains { $0.kind == .crop || $0.kind == .turn }
      ? try MediaEdit(operations).placement(of: stored, turned: turned)?.size ?? stored : stored.applying(turned)
    // Pictures of the film rather than a small moving one.
    if interval(in: operations) != nil, !operations.contains(where: { resizeRequest($0) != nil }) {
      return CGSize(width: abs(natural.width), height: abs(natural.height))
    }
    if let asked = operations.compactMap(resizeRequest).first,
       let size = renderSize(natural: CGSize(width: abs(natural.width), height: abs(natural.height)),
                             width: asked.width, height: asked.height, mode: .proportional) {
      return size
    }
    let longest = max(abs(natural.width), abs(natural.height))
    guard longest > defaultFrameSide else { return natural }
    let scale = defaultFrameSide / longest
    return CGSize(width: abs(natural.width) * scale, height: abs(natural.height) * scale)
  }

  /// How far apart the pictures were asked to be.
  private static let mostPictures = 10_000.0

  private static func interval(in operations: [Operation]) -> Double? {
    operations.tools.compactMap { if case .frames(let seconds) = $0 { return seconds } else { return nil } }.first
  }

  private static func writeFrames(
    _ frames: [ImageFrame],
    to output: URL,
    as type: UTType,
    operations: [Operation]
  ) throws -> [URL] {
    var options: [CFString: Any] = [:]
    if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
      let level = operations.compactMap(qualityLevel).first ?? ImageProcessor.defaultQuality
      options[kCGImageDestinationLossyCompressionQuality] = Float(level) / 100
    }

    if FormatCatalog.holdsMultipleFrames(type) {
      try ImageFrames.write(frames, to: output, as: type, frameOptions: options)
      return []
    }

    var extras: [URL] = []
    for (index, frame) in frames.enumerated() {
      let destination = index == 0 ? output : output.numbered(index + 1)
      try ImageFrames.write([frame], to: destination, as: type, frameOptions: options)
      if index > 0 { extras.append(destination) }
    }
    return extras
  }

  // MARK: - Video

  private func exportVideo(
    _ asset: AVAsset,
    of source: AVURLAsset,
    to output: URL,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let outputType = Self.outputType(for: output, operations: operations, fallback: .mpeg4Movie)
    guard FormatCatalog.isWritableVideo(outputType) else {
      throw ProcessingError.unsupportedConversion(from: .movie, to: outputType)
    }

    let fileType = AVFileType(outputType.identifier)
    let available = AVAssetExportSession.allExportPresets()
    // A named codec wins over a size: asking for ProRes and getting H.264
    // because the preset list is sorted by pixels would be the wrong answer.
    let edit = MediaEdit(operations)
    // As it was encoded, where a quick cut is all that is asked.
    let asIs = edit.isFast && edit.speed == 1 && !edit.isReversed && !edit.isEvened && edit.shapes.isEmpty && ImageProcessor.sizeCeiling(from: operations) == nil
    let preferred = Self.chosenCodec(in: operations)?.exportPreset
      ?? (asIs ? AVAssetExportPresetPassthrough : Self.videoPreset(for: operations, available: available))
    let resizing = try await Self.composition(for: asset, operations: operations)

    // Not every preset works with every asset, and the ones that do cannot
    // always write every container. Try the best match, then fall back rather
    // than failing on a video AVFoundation is perfectly able to convert.
    guard let session = Self.makeSession(
      asset: asset,
      preferred: preferred,
      fileType: fileType
    ) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot write \(FormatCatalog.fileExtension(for: outputType) ?? outputType.identifier) from this video"
      )
    }

    // A codec that was asked for and that this container cannot hold: the
    // fallback wrote H.264 into the MP4 and said nothing about the ProRes.
    // H.264 has no preset of its own: it is what the usual one writes.
    if let codec = Self.chosenCodec(in: operations), codec != .h264, session.presetName != codec.exportPreset {
      throw ProcessingError.conversionFailed(
        reason: "\(codec.title) does not fit in "
          + "\((FormatCatalog.fileExtension(for: outputType) ?? outputType.identifier).uppercased()). A MOV holds it."
      )
    }

    session.outputURL = output
    session.outputFileType = fileType
    session.shouldOptimizeForNetworkUse = true
    // Faster is not higher.
    session.audioTimePitchAlgorithm = .spectral

    // How small: a ceiling that was asked for, or a share of what the film
    // would otherwise weigh for a quality below the top. The session is told
    // the size and keeps the picture's shape and its frame rate; choosing a
    // "low quality" preset instead shrank a 1280 x 720 film to 568 x 320.
    var limit = ImageProcessor.sizeCeiling(from: operations).map(Int64.init)
    if let quality = operations.compactMap(Self.qualityLevel).first, quality < 100,
       session.presetName != AVAssetExportPresetPassthrough,
       let whole = try? await session.estimatedOutputFileLengthInBytes, whole > 0 {
      let share = Int64(Double(whole) * Double(quality) / 100)
      limit = min(limit ?? share, share)
    }
    if let limit, session.presetName != AVAssetExportPresetPassthrough { session.fileLengthLimit = limit }
    // Left as it was encoded, a part keeps the pictures before it, hidden: a
    // player is told to skip them, and whoever opens the file can see them.
    if resizing == nil, edit.part != nil, !edit.isFast, session.presetName != AVAssetExportPresetPassthrough {
      let hasPicture = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
      if hasPicture { session.videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) }
    }
    if let resizing {
      guard session.presetName != AVAssetExportPresetPassthrough else {
        throw ProcessingError.conversionFailed(reason: "This video cannot be resized into that container")
      }
      session.videoComposition = resizing
    }

    // Where the film was shot travels inside it. An export with no metadata of
    // its own carries the source's across, so leaving it out is done here: the
    // session's own filter for the thorough level, since AVFoundation knows
    // what each key means, and the location keys alone otherwise.
    let privacy = PrivacyFilter.policy(in: operations)
    // What was made out of a film carries nothing of it but the film.
    if !privacy.removesSomething, !edit.isNothing {
      session.metadata = try await source.load(.metadata)
    }
    if privacy.removesSomething {
      if let filter = PrivacyFilter.filter(for: privacy) {
        session.metadataItemFilter = filter
      }
      // Both, at the thorough level: AVFoundation's filter lets the copyright
      // line and the camera through, and that line is usually somebody's name.
      session.metadata = PrivacyFilter.metadata(
        try await source.load(.metadata), to: privacy
      )
    }
    // Metadata is deliberately not set: an export session with none of its own
    // carries the source's across, and setting it to the common key space
    // would *narrow* that to the handful of tags every container shares.

    // The export publishes progress as a polled property, so a sibling task
    // samples it while the export runs. It has to keep polling through the
    // statuses before `.exporting` too: sampling only while already exporting
    // meant the loop exited immediately and no progress was ever reported.
    let box = ExportBox(session)
    let reporter = Task {
      while !Task.isCancelled {
        switch box.session.status {
        case .completed, .failed, .cancelled:
          return
        case .exporting:
          progress(Double(box.session.progress))
        default:
          break
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    defer { reporter.cancel() }

    await withTaskCancellationHandler {
      await box.session.export()
    } onCancel: {
      box.session.cancelExport()
    }

    switch session.status {
    case .completed:
      break
    case .cancelled:
      throw CancellationError()
    default:
      // The session's own error, as it is: the caller decides whether a tool
      // can do what macOS could not before anything is said about it.
      throw session.error ?? ProcessingError.conversionFailed(reason: "Video export did not complete")
    }

    progress(1.0)

    let written = AVURLAsset(url: output)
    var dimensions: (width: Int, height: Int)?
    if let track = try await written.loadTracks(withMediaType: .video).first {
      let size = try await track.load(.naturalSize)
      dimensions = (Int(abs(size.width)), Int(abs(size.height)))
    }

    return ProcessingResult(
      outputURL: output,
      outputSize: try Self.fileSize(output),
      outputDimensions: dimensions,
      duration: Date().timeIntervalSince(start)
    )
  }

  /// The export preset for the requested quality. The size is not chosen here:
  /// the named sizes stop at 640 × 480 and only ever came close to what was
  /// asked, so an exact size is drawn by `composition(for:operations:)`.
  static func videoPreset(for operations: [Operation], available: [String]) -> String {
    // Always the one that keeps the picture as it is. Quality is a matter of
    // how many bytes, and is settled by telling the session a size.
    return available.contains(AVAssetExportPresetHighestQuality)
      ? AVAssetExportPresetHighestQuality
      : AVAssetExportPresetPassthrough
  }

  /// The frame a resize asks for, worked out as images do it: only the sides
  /// that were named decide the scale, and a crop or a pad box takes the
  /// source's side for one nobody named. Sides are even, as encoders want.
  static func renderSize(natural: CGSize, width: Int?, height: Int?, mode: ResizeFitMode) -> CGSize? {
    guard natural.width > 0, natural.height > 0 else { return nil }
    let asked = [
      width.map { CGFloat($0) / natural.width },
      height.map { CGFloat($0) / natural.height },
    ].compactMap { $0 }.filter { $0 > 0 }
    guard let smallest = asked.min() else { return nil }
    func even(_ value: CGFloat) -> CGFloat {
      let whole = max(2, Int(value.rounded()))
      return CGFloat(whole % 2 == 0 ? whole : whole + 1)
    }
    if mode == .proportional {
      return CGSize(width: even(natural.width * smallest), height: even(natural.height * smallest))
    }
    return CGSize(
      width: even(width.map(CGFloat.init) ?? natural.width),
      height: even(height.map(CGFloat.init) ?? natural.height)
    )
  }

  /// Where the picture goes inside the frame: filled exactly for a fit or a
  /// stretch, cut at the edges for a crop, framed in black for a pad.
  static func placement(of natural: CGSize, in render: CGSize, mode: ResizeFitMode) -> CGAffineTransform {
    let scaleX = render.width / natural.width, scaleY = render.height / natural.height
    let scale: CGFloat
    switch mode {
    case .proportional, .stretch: return CGAffineTransform(scaleX: scaleX, y: scaleY)
    case .cropCenter: scale = max(scaleX, scaleY)
    case .pad: scale = min(scaleX, scaleY)
    }
    return CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
      translationX: (render.width - natural.width * scale) / 2,
      y: (render.height - natural.height * scale) / 2
    ))
  }

  /// The video drawn at the size asked for, upright, or nil when no size was.
  private static func composition(for asset: AVAsset, operations: [Operation]) async throws -> AVVideoComposition? {
    guard let track = try await asset.loadTracks(withMediaType: .video).first,
          // A phone video is stored sideways with a turn on top; the size asked
          // for is the size it is watched at.
          let placed = try MediaEdit(operations).placement(
            of: try await track.load(.naturalSize), turned: try await track.load(.preferredTransform)
          ) else { return nil }

    let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
    composition.renderSize = placed.size
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(placed.transform, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
    instruction.layerInstructions = [layer]
    composition.instructions = [instruction]
    return composition
  }

  /// The first preset that both opens for this asset and writes this container.
  private static func makeSession(
    asset: AVAsset,
    preferred: String,
    fileType: AVFileType
  ) -> AVAssetExportSession? {
    let candidates = [preferred, AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough]
    for name in candidates {
      guard let session = AVAssetExportSession(asset: asset, presetName: name),
            session.supportedFileTypes.contains(fileType) else { continue }
      return session
    }
    return nil
  }

  static func chosenCodec(in operations: [Operation]) -> Codec? {
    operations.compactMap { if case .encode(let codec) = $0 { return codec } else { return nil } }.first
  }

  private static func resizeRequest(_ operation: Operation) -> (width: Int?, height: Int?, mode: ResizeFitMode)? {
    guard case .resize(let width, let height, let mode) = operation, width != nil || height != nil else { return nil }
    return (width, height, mode)
  }

  private static func qualityLevel(_ operation: Operation) -> Int? {
    guard case .quality(let level) = operation else { return nil }
    return level
  }

  // MARK: - Audio

  private func convertAudio(
    _ sound: URL,
    of input: URL,
    to output: URL,
    operations: [Operation],
    start: Date,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let outputType = Self.outputType(for: output, operations: operations, fallback: .mpeg4Audio)

    // A chosen codec decides what goes in the container, which is what makes
    // Apple Lossless in an .m4a and Opus in a .caf reachable at all.
    let chosen = Self.chosenCodec(in: operations)?.audioFormatID
    if let chosen, !FormatCatalog.canEncodeAudio(type: outputType, formatID: chosen) {
      throw ProcessingError.conversionFailed(
        reason: "\(Self.chosenCodec(in: operations)?.title ?? "That codec") does not fit in "
          + "\(FormatCatalog.fileExtension(for: outputType)?.uppercased() ?? outputType.identifier)."
      )
    }

    guard let formatID = chosen ?? FormatCatalog.audioFormatID(for: outputType) else {
      let inputType = UTType(filenameExtension: input.pathExtension) ?? .audio
      throw ProcessingError.unsupportedConversion(from: inputType, to: outputType)
    }

    let inputFile = try AVAudioFile(forReading: sound)
    let sourceFormat = inputFile.processingFormat

    // macOS opens some files it cannot measure - FLAC inside Ogg, which is what
    // `--to ogg` writes - and reports no frames. The copy below then ran zero
    // times and an empty file was reported as a conversion. Reading on
    // regardless yields the first second and stops, which is worse.
    guard inputFile.length > 0 else {
      throw ProcessingError.conversionFailed(
        reason: "\(input.lastPathComponent) holds no sound that macOS can read."
      )
    }

    // Sample rate and channel count follow the source: Forge offers no way to
    // ask for anything else, and silently resampling a 48 kHz mono recording
    // to 44.1 kHz stereo is not a conversion the user requested.
    var settings: [String: Any] = [
      AVFormatIDKey: formatID,
      // Opus is made at 48 kHz and a handful of rates below it, and refuses
      // the rest - 44.1 kHz, the commonest of all, included.
      AVSampleRateKey: formatID == kAudioFormatOpus && ![8_000, 12_000, 16_000, 24_000, 48_000].contains(sourceFormat.sampleRate)
        ? 48_000 : sourceFormat.sampleRate,
      AVNumberOfChannelsKey: Int(sourceFormat.channelCount),
    ]
    // The depth the recording has, where it says: everything used to be cut
    // to 16 bits, a 24-bit master included, and FLAC was written at 24 from a
    // 16-bit source. A compressed source has no depth of its own and gets 16.
    let description = inputFile.fileFormat.streamDescription.pointee
    let sourceBits = description.mFormatID == kAudioFormatLinearPCM && description.mBitsPerChannel > 0
      ? Int(description.mBitsPerChannel) : 16
    let isLossy = formatID == kAudioFormatMPEG4AAC || formatID == kAudioFormatOpus
    let seconds = sourceFormat.sampleRate > 0 ? Double(inputFile.length) / sourceFormat.sampleRate : 0
    let ceiling = ImageProcessor.sizeCeiling(from: operations)

    if formatID == kAudioFormatLinearPCM {
      // Float stays float where the container takes it; AIFF does not.
      let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0 && !FormatCatalog.usesBigEndianPCM(outputType)
      settings[AVLinearPCMBitDepthKey] = isFloat ? 32 : min(sourceBits, 32)
      settings[AVLinearPCMIsFloatKey] = isFloat
      settings[AVLinearPCMIsBigEndianKey] = FormatCatalog.usesBigEndianPCM(outputType)
    } else if isLossy {
      // A bit rate means something to an encoder that throws sound away, and
      // was an error to one that does not: "quality 80" on a FLAC failed.
      var rate = operations.compactMap(Self.qualityLevel).first.map {
        Self.bitrate(forQuality: $0, channels: Int(sourceFormat.channelCount))
      }
      // A size that was asked for is a bit rate, once the length is known.
      if let ceiling, seconds > 0 {
        let fits = Int(Double(ceiling) * 8 / seconds * 0.95)
        rate = min(rate ?? fits, fits)
      }
      if let rate { settings[AVEncoderBitRateKey] = rate }
    } else {
      settings[AVEncoderBitDepthHintKey] = min(sourceBits, 24)
    }

    let totalFrames = inputFile.length
    try Self.writeSamples(from: inputFile, to: output, settings: settings, format: sourceFormat) { position in
      progress(totalFrames > 0 ? Double(position) / Double(totalFrames) : 0)
    }

    // What was written has to be something: a clip of a few milliseconds made
    // a 42-byte FLAC that nothing opens, reported as converted.
    guard ((try? AVAudioFile(forReading: output))?.length ?? 0) > 0 else {
      throw ProcessingError.conversionFailed(
        reason: "\(input.lastPathComponent) is too short to be written as "
          + "\((FormatCatalog.fileExtension(for: outputType) ?? outputType.identifier).uppercased())."
      )
    }

    try await Self.carryTags(
      from: input, to: output, type: outputType, privacy: PrivacyFilter.policy(in: operations)
    )
    Self.carryCoverAndChapters(from: input, to: output, chapters: sound == input)
    progress(1.0)

    // A ceiling is a promise about the result. Where the format gave no way
    // to keep it - nothing can make a WAV smaller - that is said, not skipped.
    if let ceiling, let size = try? Self.fileSize(output), size > Int64(ceiling) {
      throw ProcessingError.conversionFailed(
        reason: "\(input.lastPathComponent) comes out at \(size.formatted(.byteCount(style: .file))), over the "
          + "\(Int64(ceiling).formatted(.byteCount(style: .file))) asked for, and "
          + "\((FormatCatalog.fileExtension(for: outputType) ?? "this format").uppercased()) cannot be made smaller."
      )
    }

    return ProcessingResult(
      outputURL: output,
      outputSize: try Self.fileSize(output),
      outputDimensions: nil,
      duration: Date().timeIntervalSince(start)
    )
  }

  /// Put the recording's tags back on the finished file.
  ///
  /// Audio is written with `AVAudioFile`, which has no notion of metadata, so
  /// a converted song used to come out with no title, no artist and no cover.
  /// They are added afterwards, by copying the track - not re-encoding it -
  /// into a tagged file and swapping that in.
  ///
  /// Which containers can hold tags is asked rather than listed: an export
  /// session says what it can write, and a FLAC or a WAV is simply left
  /// untagged instead of being promised something AVFoundation cannot do.
  private static func carryTags(
    from input: URL,
    to output: URL,
    type: UTType,
    privacy: PrivacyPolicy = .keepAll
  ) async throws {
    var tags = PrivacyFilter.metadata(
      try await AVURLAsset(url: input).load(.metadata), to: privacy
    )
    // Into another format, only the names every format shares mean anything.
    if UTType(filenameExtension: input.pathExtension) != type {
      tags = await PrivacyFilter.portable(tags)
    }
    guard !tags.isEmpty else { return }

    guard let session = AVAssetExportSession(
      asset: AVURLAsset(url: output),
      presetName: AVAssetExportPresetPassthrough
    ) else { return }

    let fileType = AVFileType(type.identifier)
    guard session.supportedFileTypes.contains(fileType) else {
      // FLAC, WAV, AIFF: macOS writes the sound and has no way to write a tag.
      // ffmpeg does, where it is installed; without it they go untagged.
      try? await Self.tagWithFFmpeg(output, tags)
      return
    }

    let tagged = output.deletingLastPathComponent()
      .appendingPathComponent(".forge-tags-\(UUID().uuidString).\(output.pathExtension)")
    session.outputURL = tagged
    session.outputFileType = fileType
    session.metadata = tags

    await session.export()
    // Tags are worth having and not worth failing a conversion over: the audio
    // is already written and correct. WAV, AIFF and CAF either refuse this
    // export or go through it without complaint and without the tags; for
    // those ffmpeg is asked, where it is installed.
    // Not merely "has metadata": a WAV comes back with one item, its length.
    let written = (try? await AVURLAsset(url: tagged).load(.metadata)) ?? []
    guard session.status == .completed, written.contains(where: { $0.commonKey != nil }) else {
      try? FileManager.default.removeItem(at: tagged)
      try? await Self.tagWithFFmpeg(output, tags)
      return
    }
    _ = try FileManager.default.replaceItemAt(output, withItemAt: tagged)
  }

  /// The tags, written by ffmpeg onto a copy of the finished file. Only what
  /// was asked to be kept is named, so nothing else can come across.
  private static func tagWithFFmpeg(_ output: URL, _ tags: [AVMetadataItem]) async throws {
    guard let ffmpeg = ExternalTools.locate("ffmpeg") else { return }
    // Where ffmpeg's name for a tag is not the one AVFoundation uses.
    let itsName: [AVMetadataKey: String] = [
      .commonKeyAlbumName: "album", .commonKeyCopyrights: "copyright", .commonKeyCreationDate: "date",
      .commonKeyDescription: "comment", .commonKeyType: "genre",
    ]
    var named: [String] = []
    for tag in tags {
      guard let key = tag.commonKey, let value = try? await tag.load(.stringValue) else { continue }
      named += ["-metadata", "\(itsName[key] ?? key.rawValue)=\(value)"]
    }
    guard !named.isEmpty else { return }
    // AIFF has room for a name and little else unless its tags go in an ID3
    // chunk, which ffmpeg writes only when asked.
    if UTType(filenameExtension: output.pathExtension)?.conforms(to: .aiff) == true {
      named += ["-write_id3v2", "1"]
    }

    let tagged = output.deletingLastPathComponent()
      .appendingPathComponent(".forge-tags-\(UUID().uuidString).\(output.pathExtension)")
    defer { try? FileManager.default.removeItem(at: tagged) }
    try ExternalTools.run(ffmpeg, [
      "-hide_banner", "-loglevel", "error", "-y", "-i", output.path,
      "-map", "0", "-c", "copy", "-map_metadata", "-1",
    ] + named + [tagged.path])
    _ = try FileManager.default.replaceItemAt(output, withItemAt: tagged)
  }

  /// Stream the samples across in bounded chunks, keeping memory flat on long
  /// recordings. Leaving this scope closes the output file, which is what makes
  /// the result valid: a previous version measured the file while it was still
  /// open and reported success on a partial write.
  private static func writeSamples(
    from inputFile: AVAudioFile,
    to output: URL,
    settings: [String: Any],
    format: AVAudioFormat,
    progress: (AVAudioFramePosition) -> Void
  ) throws {
    let outputFile = try AVAudioFile(forWriting: output, settings: settings)
    let chunk: AVAudioFrameCount = 64 * 1024

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
      throw ProcessingError.conversionFailed(reason: "Cannot allocate an audio buffer")
    }

    // Bounded by the source length: reading past the end throws rather than
    // returning zero frames.
    while inputFile.framePosition < inputFile.length {
      try Task.checkCancellation()
      let remaining = AVAudioFrameCount(min(Int64(chunk), inputFile.length - inputFile.framePosition))
      try inputFile.read(into: buffer, frameCount: remaining)
      guard buffer.frameLength > 0 else { break }
      try outputFile.write(from: buffer)
      progress(inputFile.framePosition)
    }
  }

  /// Map a 1-100 quality level onto a per-channel bitrate.
  static func bitrate(forQuality quality: Int, channels: Int) -> Int {
    let perChannel = 32_000 + (max(1, min(100, quality)) * 1_280)
    return perChannel * max(1, channels)
  }

  // MARK: - Shared helpers

  private static func outputType(for output: URL, operations: [Operation], fallback: UTType) -> UTType {
    let requested = operations.compactMap { operation -> UTType? in
      guard case .convertFormat(let to) = operation else { return nil }
      return to
    }.first
    return requested ?? UTType(filenameExtension: output.pathExtension) ?? fallback
  }

  private static func fileSize(_ url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.size] as? Int64 ?? 0
  }
}

/// Reading `progress` and calling `cancelExport()` from another task is what
/// an export session is for, but the class itself predates `Sendable`.
private final class ExportBox: @unchecked Sendable {
  let session: AVAssetExportSession
  init(_ session: AVAssetExportSession) { self.session = session }
}
