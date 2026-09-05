import Foundation
import UniformTypeIdentifiers

/// Runs conversions, decides where their output lands, and keeps every write
/// off the file the user already has on disk.
actor ProcessingCoordinator {
  /// The processors, in the order they get asked. Images first because ImageIO
  /// reads the widest set of types; documents last because their readers are
  /// the most permissive about what counts as text.
  private let processors: [FileProcessor] = [
    // Before the image processor, which would claim an SVG through
    // `readableImageTypes` and then hand ImageIO a file it cannot decode.
    VectorProcessor(),
    ImageProcessor(),
    // Before the media path: AVFoundation lists WebVTT among the types it
    // opens, and then finds no tracks in one, so a subtitle handed to it fails
    // with "contains no audio or video tracks" rather than being converted.
    SubtitleProcessor(),
    MediaProcessor(),
    // Before the document reader: JSON and CSV are plain text as far as the
    // system is concerned, and the document reader would take them.
    DataProcessor(),
    SimpleDocProcessor(),
    ModelProcessor(),
    // Last: a conversion macOS can do itself is still done by macOS, and a
    // tool the user installed is only asked about what is left over.
    ExternalProcessor(),
  ]

  private let persistence: PersistenceManager
  private var settings: AppSettings

  /// Active tasks, so a cancel actually reaches the work in flight.
  private var activeTasks: [UUID: Task<ProcessingHistory, Error>] = [:]

  init(
    settings: AppSettings,
    persistence: PersistenceManager = .shared
  ) {
    self.settings = settings
    self.persistence = persistence
  }

  /// Settings are pushed in rather than snapshotted at init, so changing the
  /// concurrency limit takes effect without relaunching the app.
  func update(settings: AppSettings) {
    self.settings = settings
  }

  /// Max number of files to convert at once.
  var maxConcurrentNative: Int { settings.maxConcurrentNative }

  /// Convert one file and record the outcome in history.
  /// - Parameter counter: which file this is in the batch, counting from one,
  ///   for a name template that numbers them. Nil where there is no batch to
  ///   count - a watched folder, or one file on its own.
  func processFile(
    _ file: ProcessableFile,
    with preset: RulePreset,
    destinationMode: DestinationMode,
    destinationURL: URL? = nil,
    counter: Int? = nil,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingHistory {
    let fileId = file.id

    let started = Date()
    let task = Task {
      do {
        let result = try await self.run(
          file: file,
          preset: preset,
          destinationMode: destinationMode,
          destinationURL: destinationURL,
          counter: counter,
          progress: progress
        )

        let history = ProcessingHistory(
          fileURL: file.url,
          ruleId: preset.id,
          timestamp: Date(),
          status: .completed,
          duration: result.duration,
          outputURL: result.outputURL,
          additionalOutputs: result.additionalOutputs.isEmpty ? nil : result.additionalOutputs,
          destinationFolder: destinationURL,
          actions: preset.toOperations(),
          presetName: preset.name
        )
        try await self.persistence.appendHistory(history)
        return history
      } catch {
        let history = ProcessingHistory(
          fileURL: file.url,
          ruleId: preset.id,
          timestamp: Date(),
          status: error is CancellationError ? .cancelled : .failed,
          errorMessage: error.localizedDescription,
          // Measured rather than zeroed: a conversion that failed after two
          // minutes and one that failed at once are not the same event, and
          // history used to record both as taking no time at all.
          duration: Date().timeIntervalSince(started),
          outputURL: nil,
          additionalOutputs: nil,
          destinationFolder: destinationURL,
          actions: preset.toOperations(),
          presetName: preset.name
        )
        try? await self.persistence.appendHistory(history)
        throw error
      }
    }

    activeTasks[fileId] = task
    defer { activeTasks.removeValue(forKey: fileId) }

    return try await task.value
  }

  /// Convert one file into a folder of the caller's choosing, without writing
  /// it down.
  ///
  /// The same chain, the same processors, the same output planning - it is the
  /// real conversion, which is the only kind worth showing somebody before they
  /// agree to it. What it is not is an event in their history: a preview they
  /// looked at and cancelled did not happen.
  func preview(
    _ file: ProcessableFile,
    with preset: RulePreset,
    into folder: URL,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> ProcessingResult {
    try await run(
      file: file,
      preset: preset,
      destinationMode: .copyTo,
      destinationURL: folder,
      counter: nil,
      progress: progress
    )
  }

  /// Stop one file. Its siblings carry on: a row that is taking too long is a
  /// row, not a batch.
  func cancel(_ file: UUID) {
    activeTasks[file]?.cancel()
    activeTasks.removeValue(forKey: file)
  }

  func cancelAll() {
    for task in activeTasks.values { task.cancel() }
    activeTasks.removeAll()
  }

  // MARK: - Private

  /// Run the preset once per format it asks for.
  ///
  /// A preset naming two formats is not a preset that changed its mind: it is
  /// one that wants both, so the same file goes through twice and two files
  /// come out. One format is the ordinary case and takes the ordinary path.
  private func run(
    file: ProcessableFile,
    preset: RulePreset,
    destinationMode: DestinationMode,
    destinationURL: URL?,
    counter: Int?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    let formats = Self.formats(of: preset)
    guard formats.count > 1 else {
      return try await executeProcessing(
        file: file,
        preset: preset,
        destinationMode: destinationMode,
        destinationURL: destinationURL,
        counter: counter,
        progress: progress
      )
    }

    // Two files cannot both replace one original. Saying so beats writing one
    // of them over the other and calling it converted.
    guard destinationMode != .overwrite else {
      throw ProcessingError.validationFailed(
        message: "“\(preset.name)” writes \(formats.count) files per input, "
          + "so it cannot replace the original. Choose a destination folder."
      )
    }

    var results: [ProcessingResult] = []
    for (index, format) in formats.enumerated() {
      try Task.checkCancellation()
      let step = 1.0 / Double(formats.count)
      results.append(
        try await executeProcessing(
          file: file,
          preset: Self.preset(preset, writingOnly: format),
          destinationMode: destinationMode,
          destinationURL: destinationURL,
          counter: counter,
          progress: { fraction in progress(Double(index) * step + fraction * step) }
        )
      )
    }

    guard let first = results.first else {
      throw ProcessingError.conversionFailed(reason: "Nothing was written")
    }

    return ProcessingResult(
      outputURL: first.outputURL,
      outputSize: results.reduce(0) { $0 + $1.outputSize },
      outputDimensions: first.outputDimensions,
      duration: results.reduce(0) { $0 + $1.duration },
      additionalOutputs: first.additionalOutputs + results.dropFirst().map(\.outputURL),
      appliedQuality: first.appliedQuality
    )
  }

  /// Every format the preset asks for, in the order it asks.
  static func formats(of preset: RulePreset) -> [UTType] {
    preset.actions.compactMap {
      if case .convertFormat(let to) = $0 { return to } else { return nil }
    }
  }

  /// The same preset with one of its formats and none of the others.
  private static func preset(_ preset: RulePreset, writingOnly format: UTType) -> RulePreset {
    var copy = preset
    let position = copy.actions.firstIndex { if case .convertFormat = $0 { return true } else { return false } } ?? 0
    copy.actions.removeAll { if case .convertFormat = $0 { return true } else { return false } }
    copy.actions.insert(.convertFormat(to: format), at: min(position, copy.actions.count))
    return copy
  }

  private func executeProcessing(
    file: ProcessableFile,
    preset: RulePreset,
    destinationMode: DestinationMode,
    destinationURL: URL?,
    counter: Int?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    guard processors.contains(where: { $0.canProcess(file) }) else {
      throw ProcessingError.unreadableFormat(file.fileType)
    }

    // A preset says what it cares about; Settings says the rest; and what is
    // written into the file's own name beats both, because somebody typed it
    // onto that file for this conversion.
    let operations = settings.applyingDefaults(
      to: NameTokens.applying(to: preset.toOperations(), from: file.fileName),
      writing: preset.targetFormat ?? file.fileType
    )

    var plan = try makeOutputPlan(
      for: file,
      preset: preset,
      operations: operations,
      counter: counter,
      destinationMode: destinationMode,
      destinationFolder: destinationURL
    )

    // Anything written before the conversion succeeds is scratch, and must not
    // survive a failure or a cancellation.
    var succeeded = false
    defer {
      if !succeeded {
        try? FileManager.default.removeItem(at: plan.workURL)
        if let reservation = plan.reservationURL {
          try? FileManager.default.removeItem(at: reservation)
        }
        // A multi-page conversion may have written scratch siblings before it
        // failed; none of them should outlive the failure.
        let folder = plan.workURL.deletingLastPathComponent()
        let prefix = plan.workURL.deletingPathExtension().lastPathComponent
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for leftover in leftovers where leftover.lastPathComponent.hasPrefix(prefix) {
          try? FileManager.default.removeItem(at: leftover)
        }
      }
    }

    try Task.checkCancellation()

    // Which processor can open the file is not the whole question: the media
    // path reads an MP4 and cannot write a WMV, and saying so is not the same
    // as the conversion being impossible. So a processor that turns the pair
    // down hands the file to the next one that can read it - which is how a
    // tool the user installed gets asked about what macOS declined.
    //
    // The conversion always writes to a scratch file, never to a path the user
    // already has data at. Converting in place used to read and write the same
    // URL, which truncated the source mid-read and destroyed the original.
    var attempt: ProcessingResult?
    var declined: Error?
    for candidate in processors where candidate.canProcess(file) {
      do {
        attempt = try await candidate.process(
          file.url,
          to: plan.workURL,
          with: operations,
          progress: progress
        )
        break
      } catch let error as ProcessingError {
        guard case .unsupportedConversion = error else { throw error }
        // Nothing has been written yet, but a processor that turned the pair
        // down after starting must not leave its scratch for the next one.
        try? FileManager.default.removeItem(at: plan.workURL)
        declined = error
      }
    }

    guard let result = attempt else {
      throw declined ?? ProcessingError.unreadableFormat(file.fileType)
    }

    try Task.checkCancellation()

    // A PDF's author details can only be taken out of a PDF that exists, so
    // this happens here rather than in a processor - on the scratch file,
    // before anything is moved into place.
    try PrivacyFilter.applyAfterWriting(
      PrivacyFilter.policy(in: operations),
      to: [plan.workURL] + result.additionalOutputs
    )

    if plan.replacesSource, settings.createBackupBeforeOverwrite {
      try backUp(file.url)
    }

    // Now the file exists, the parts of its name that describe it can be
    // filled in - how wide it came out, what a size ceiling settled on.
    plan = try settle(plan, with: result)

    // A video taken apart into a hundred stills is a hundred loose files in
    // somebody's Downloads. They belong together, in a folder named after what
    // they came from.
    let committed = try commit(
      plan,
      extras: result.additionalOutputs,
      gatherIntoAFolder: Self.isFrameExport(from: file, to: plan.finalURL, extras: result.additionalOutputs)
    )

    if plan.removesSource, plan.finalURL != file.url,
       FileManager.default.fileExists(atPath: file.url.path) {
      try FileManager.default.removeItem(at: file.url)
    }

    succeeded = true

    return ProcessingResult(
      outputURL: committed.primary,
      outputSize: result.outputSize,
      outputDimensions: result.outputDimensions,
      duration: result.duration,
      additionalOutputs: committed.extras,
      appliedQuality: result.appliedQuality
    )
  }

  /// Move the finished scratch files into their final places, replacing
  /// whatever reservation or previous file is sitting there.
  ///
  /// Extra outputs keep the suffix the processor gave them (`-002`, `-003`)
  /// but hang off the destination's name rather than the scratch name.
  /// Whether this was a video taken apart into stills — the one case where the
  /// extra files are a set rather than a sequel.
  static func isFrameExport(from file: ProcessableFile, to output: URL, extras: [URL]) -> Bool {
    guard !extras.isEmpty else { return false }
    guard FormatCatalog.isReadableMedia(file.fileType), !file.fileType.conforms(to: .audio) else {
      return false
    }
    guard let type = UTType(filenameExtension: output.pathExtension) else { return false }
    return FormatCatalog.isWritableImage(type)
  }

  private func commit(
    _ plan: OutputPlan,
    extras: [URL],
    gatherIntoAFolder: Bool = false
  ) throws -> (primary: URL, extras: [URL]) {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: plan.finalURL.path) {
      _ = try fileManager.replaceItemAt(plan.finalURL, withItemAt: plan.workURL)
    } else {
      try fileManager.moveItem(at: plan.workURL, to: plan.finalURL)
    }

    let workBase = plan.workURL.deletingPathExtension().lastPathComponent
    let finalBase = plan.finalURL.deletingPathExtension().lastPathComponent
    var folder = plan.finalURL.deletingLastPathComponent()
    var primary = plan.finalURL

    if gatherIntoAFolder {
      // Not `reserveUniqueURL`: that claims a name by putting an empty file
      // there, and a folder cannot be created on top of a file.
      var home = folder.appendingPathComponent(finalBase)
      var attempt = 2
      while fileManager.fileExists(atPath: home.path) {
        home = folder.appendingPathComponent("\(finalBase) \(attempt)")
        attempt += 1
      }
      try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
      // The first frame went out under the plan's own name; it belongs with
      // the rest of them.
      primary = home.appendingPathComponent(plan.finalURL.lastPathComponent)
      try fileManager.moveItem(at: plan.finalURL, to: primary)
      folder = home
    }

    let moved = try extras.map { extra -> URL in
      let suffix = extra.deletingPathExtension().lastPathComponent.replacingOccurrences(of: workBase, with: "")
      let ext = extra.pathExtension
      let name = ext.isEmpty ? "\(finalBase)\(suffix)" : "\(finalBase)\(suffix).\(ext)"
      let destination = try reserveUniqueURL(folder.appendingPathComponent(name))
      _ = try fileManager.replaceItemAt(destination, withItemAt: extra)
      return destination
    }

    return (primary, moved)
  }

  private func backUp(_ url: URL) throws {
    let backups = persistence.backupsDirectory
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    let stamp = Self.backupStamp.string(from: Date())
    let name = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    let desired = backups.appendingPathComponent(
      ext.isEmpty ? "\(name)-\(stamp)" : "\(name)-\(stamp).\(ext)"
    )
    try FileManager.default.copyItem(at: url, to: try Self.freeURL(desired))
  }

  private func makeOutputPlan(
    for file: ProcessableFile,
    preset: RulePreset,
    operations: [Operation],
    counter: Int?,
    destinationMode: DestinationMode,
    destinationFolder: URL?
  ) throws -> OutputPlan {
    let outputExtension = preset.targetFormat.flatMap(FormatCatalog.fileExtension(for:))
      ?? FormatCatalog.fileExtension(for: file.fileType)
      ?? file.url.pathExtension
    let suffix = Self.sizeSuffix(for: preset)
    let context = Self.nameContext(
      for: file, preset: preset, operations: operations, extension: outputExtension, counter: counter
    )

    switch destinationMode {
    case .overwrite:
      // Converting in place still renames when the format changes: JPEG bytes
      // in a file called `.png` are not a converted file, they are a broken one.
      let named = file.url
        .deletingLastPathComponent()
        // No size in the name here: converting in place means the file stays
        // where it is, under the name it has.
        .appendingPathComponent(
          outputName(for: file, preset: preset, context: context, extension: outputExtension, fallbackSuffix: "")
        )
      // Overwrite replaces the file it was handed, and nothing else. Changing
      // the format changes the name, and a *different* file already holding
      // that name is somebody else's data: it used to be replaced silently and
      // was not backed up either, because the backup is taken of the source.
      // It takes the next free name instead, which is what the other modes do.
      let final = named == file.url ? named : try reserveUniqueURL(named)
      return OutputPlan(
        finalURL: final,
        workURL: scratchURL(besides: final),
        reservationURL: final == file.url ? nil : final,
        replacesSource: true,
        removesSource: final != file.url,
        nameContext: context
      )

    case .copyTo, .moveTo:
      guard let folder = destinationFolder else {
        throw ProcessingError.validationFailed(
          message: "\(destinationMode.displayName) needs a destination folder"
        )
      }
      let desired = folder.appendingPathComponent(
        outputName(for: file, preset: preset, context: context, extension: outputExtension, fallbackSuffix: suffix)
      )
      // Claim the name straight away: two files converging on one output name
      // used to leave a single file behind, with both reported as converted.
      let final = try reserveUniqueURL(desired)
      return OutputPlan(
        finalURL: final,
        workURL: scratchURL(besides: final),
        reservationURL: final,
        replacesSource: false,
        removesSource: destinationMode == .moveTo,
        nameContext: context
      )
    }
  }

  /// Find a free name and create an empty file to hold it, so a conversion
  /// running alongside this one cannot pick the same name.
  private func reserveUniqueURL(_ desired: URL) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: desired.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var candidate = try Self.freeURL(desired)
    var attempts = 0
    while !fileManager.createFile(atPath: candidate.path, contents: nil) {
      attempts += 1
      guard attempts < 10_000 else {
        throw ProcessingError.conversionFailed(
          reason: "Cannot claim a name for \(desired.lastPathComponent)"
        )
      }
      candidate = try Self.freeURL(candidate)
    }
    return candidate
  }

  /// The first name in the `name`, `name 2`, `name 3` sequence that is free.
  private static func freeURL(_ desired: URL) throws -> URL {
    let fileManager = FileManager.default
    let folder = desired.deletingLastPathComponent()
    let base = desired.deletingPathExtension().lastPathComponent
    let ext = desired.pathExtension

    var candidate = desired
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = folder.appendingPathComponent(
        ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
      )
      suffix += 1
      guard suffix < 10_000 else {
        throw ProcessingError.conversionFailed(
          reason: "Cannot find a free name for \(desired.lastPathComponent)"
        )
      }
    }
    return candidate
  }

  private func scratchURL(besides final: URL) -> URL {
    let ext = final.pathExtension
    let name = ext.isEmpty ? ".forge-\(UUID().uuidString)" : ".forge-\(UUID().uuidString).\(ext)"
    return final.deletingLastPathComponent().appendingPathComponent(name)
  }

  /// Everything a name can be built from before the conversion runs.
  static func nameContext(
    for file: ProcessableFile,
    preset: RulePreset,
    operations: [Operation],
    extension ext: String,
    counter: Int?
  ) -> NameTemplate.Static {
    var answers: [String: String] = [:]
    for parameter in preset.parameters {
      let value = preset.parameterValues[parameter.key] ?? parameter.defaultValue
      answers[parameter.key] = parameter.token(for: value)
    }

    let quality = operations.compactMap { operation -> Int? in
      if case .quality(let level) = operation { return level } else { return nil }
    }.first
    let codec = operations.compactMap { operation -> String? in
      if case .encode(let codec) = operation { return codec.rawValue } else { return nil }
    }.first

    return NameTemplate.Static(
      name: (file.fileName as NSString).deletingPathExtension,
      parent: file.url.deletingLastPathComponent().lastPathComponent,
      // The file's own date where the filesystem knows one, since a template
      // asking for a date is asking about the photograph, not about now.
      date: (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? Date(),
      counter: counter ?? 1,
      ext: ext,
      quality: quality,
      codec: codec,
      parameters: answers
    )
  }

  /// What the finished file is called, as far as anything knows yet.
  ///
  /// The template is the preset's own if it has one, otherwise the general one
  /// from Settings. Tokens that only a written file can answer are left in the
  /// name and filled in afterwards.
  private func outputName(
    for file: ProcessableFile,
    preset: RulePreset,
    context: NameTemplate.Static,
    extension ext: String,
    fallbackSuffix: String
  ) -> String {
    let template = preset.nameTemplate ?? settings.nameTemplate
    var name = NameTemplate.resolve(template, with: context)

    // A template that said nothing keeps the old behaviour, where a resize
    // puts its size in the name.
    if name == context.name { name += fallbackSuffix }
    if name.isEmpty { name = context.name }

    return ext.isEmpty ? name : "\(name).\(ext)"
  }

  /// The same name again, now that the file exists and can answer the rest.
  ///
  /// Only when there is something left to answer: the usual template has no
  /// such tokens in it, and renaming a file for no reason is a way to lose one.
  private func settle(_ plan: OutputPlan, with result: ProcessingResult) throws -> OutputPlan {
    let ext = plan.finalURL.pathExtension
    let stem = plan.finalURL.deletingPathExtension().lastPathComponent
    guard NameTemplate.needsSecondPass(stem) else { return plan }

    let dynamic = NameTemplate.Dynamic(
      width: result.outputDimensions?.width,
      height: result.outputDimensions?.height,
      bytes: result.outputSize,
      quality: result.appliedQuality
    )
    var settled = NameTemplate.resolve(stem, with: plan.nameContext, and: dynamic)
    if settled.isEmpty { settled = plan.nameContext.name }

    let wanted = plan.finalURL.deletingLastPathComponent()
      .appendingPathComponent(ext.isEmpty ? settled : "\(settled).\(ext)")
    guard wanted != plan.finalURL else { return plan }

    // The name claimed before the conversion is given up in the same breath as
    // the new one is claimed, so nothing else can take it in between.
    let final = try reserveUniqueURL(wanted)
    if let reservation = plan.reservationURL, reservation != final {
      try? FileManager.default.removeItem(at: reservation)
    }

    var updated = plan
    updated.finalURL = final
    updated.reservationURL = final
    return updated
  }

  /// A resize puts its size in the name. Converting one picture to three sizes
  /// used to give `photo.jpg`, `photo 2.jpg` and `photo 3.jpg`, which says
  /// nothing about which is which.
  private static func sizeSuffix(for preset: RulePreset) -> String {
    guard let resize = preset.resize else { return "" }
    switch (resize.width, resize.height) {
    case let (width?, _): return "-\(width)"
    case let (nil, height?): return "-\(height)"
    case (nil, nil): return ""
    }
  }

  private static let backupStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }()
}

/// Where a conversion's output goes, and what happens to the original.
private struct OutputPlan {
  /// Where the converted file ends up.
  var finalURL: URL
  /// The scratch file the conversion actually writes to.
  let workURL: URL
  /// A zero-byte file created to hold `finalURL`, cleaned up on failure.
  var reservationURL: URL?
  /// Whether this replaces a file the user already had.
  let replacesSource: Bool
  /// Whether the original should be removed once the output is in place.
  let removesSource: Bool
  /// What the name was built from, for the tokens only a finished file can
  /// answer.
  let nameContext: NameTemplate.Static
}
