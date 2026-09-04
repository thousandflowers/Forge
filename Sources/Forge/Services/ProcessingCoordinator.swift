import Foundation
import UniformTypeIdentifiers

/// Runs conversions, decides where their output lands, and keeps every write
/// off the file the user already has on disk.
actor ProcessingCoordinator {
  private let registry: ProcessorRegistry
  private let persistence: PersistenceManager
  private var settings: AppSettings

  /// Active tasks, so a cancel actually reaches the work in flight.
  private var activeTasks: [UUID: Task<ProcessingHistory, Error>] = [:]

  init(
    registry: ProcessorRegistry,
    settings: AppSettings,
    persistence: PersistenceManager = .shared
  ) {
    self.registry = registry
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
  func processFile(
    _ file: ProcessableFile,
    with preset: RulePreset,
    destinationMode: DestinationMode,
    destinationURL: URL? = nil,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingHistory {
    let fileId = file.id

    let task = Task {
      do {
        let result = try await self.executeProcessing(
          file: file,
          preset: preset,
          destinationMode: destinationMode,
          destinationURL: destinationURL,
          progress: progress
        )

        let history = ProcessingHistory(
          fileURL: file.url,
          ruleId: preset.id,
          timestamp: Date(),
          status: .completed,
          duration: result.duration,
          outputURL: result.outputURL
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
          duration: 0,
          outputURL: nil
        )
        try? await self.persistence.appendHistory(history)
        throw error
      }
    }

    activeTasks[fileId] = task
    defer { activeTasks.removeValue(forKey: fileId) }

    return try await task.value
  }

  func cancelFile(_ file: ProcessableFile) {
    activeTasks[file.id]?.cancel()
    activeTasks.removeValue(forKey: file.id)
  }

  func cancelAll() {
    for task in activeTasks.values { task.cancel() }
    activeTasks.removeAll()
  }

  // MARK: - Private

  private func executeProcessing(
    file: ProcessableFile,
    preset: RulePreset,
    destinationMode: DestinationMode,
    destinationURL: URL?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    guard let processor = await registry.processor(for: file) else {
      throw ProcessingError.unsupportedFormat(file.fileType)
    }

    let plan = try makeOutputPlan(
      for: file,
      preset: preset,
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

    // The conversion always writes to a scratch file, never to a path the user
    // already has data at. Converting in place used to read and write the same
    // URL, which truncated the source mid-read and destroyed the original.
    let result = try await processor.process(
      file.url,
      to: plan.workURL,
      with: preset.toOperations(),
      progress: progress
    )

    try Task.checkCancellation()

    if plan.replacesSource, settings.createBackupBeforeOverwrite {
      try backUp(file.url)
    }

    let extras = try commit(plan, extras: result.additionalOutputs)

    if plan.removesSource, plan.finalURL != file.url,
       FileManager.default.fileExists(atPath: file.url.path) {
      try FileManager.default.removeItem(at: file.url)
    }

    succeeded = true

    return ProcessingResult(
      outputURL: plan.finalURL,
      outputSize: result.outputSize,
      outputDimensions: result.outputDimensions,
      duration: result.duration,
      additionalOutputs: extras
    )
  }

  /// Move the finished scratch files into their final places, replacing
  /// whatever reservation or previous file is sitting there.
  ///
  /// Extra outputs keep the suffix the processor gave them (`-002`, `-003`)
  /// but hang off the destination's name rather than the scratch name.
  private func commit(_ plan: OutputPlan, extras: [URL]) throws -> [URL] {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: plan.finalURL.path) {
      _ = try fileManager.replaceItemAt(plan.finalURL, withItemAt: plan.workURL)
    } else {
      try fileManager.moveItem(at: plan.workURL, to: plan.finalURL)
    }

    let workBase = plan.workURL.deletingPathExtension().lastPathComponent
    let finalBase = plan.finalURL.deletingPathExtension().lastPathComponent
    let folder = plan.finalURL.deletingLastPathComponent()

    return try extras.map { extra in
      let suffix = extra.deletingPathExtension().lastPathComponent.replacingOccurrences(of: workBase, with: "")
      let ext = extra.pathExtension
      let name = ext.isEmpty ? "\(finalBase)\(suffix)" : "\(finalBase)\(suffix).\(ext)"
      let destination = try reserveUniqueURL(folder.appendingPathComponent(name))
      _ = try fileManager.replaceItemAt(destination, withItemAt: extra)
      return destination
    }
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
    destinationMode: DestinationMode,
    destinationFolder: URL?
  ) throws -> OutputPlan {
    let outputExtension = preset.targetFormat?.preferredFilenameExtension
      ?? file.fileType.preferredFilenameExtension
      ?? file.url.pathExtension

    switch destinationMode {
    case .overwrite:
      // Converting in place still renames when the format changes: JPEG bytes
      // in a file called `.png` are not a converted file, they are a broken one.
      let final = file.url
        .deletingLastPathComponent()
        .appendingPathComponent(outputName(for: file, extension: outputExtension))
      return OutputPlan(
        finalURL: final,
        workURL: scratchURL(besides: final),
        reservationURL: nil,
        replacesSource: true,
        removesSource: final != file.url
      )

    case .copyTo, .moveTo:
      guard let folder = destinationFolder else {
        throw ProcessingError.validationFailed(
          message: "\(destinationMode.displayName) needs a destination folder"
        )
      }
      let desired = folder.appendingPathComponent(outputName(for: file, extension: outputExtension))
      // Claim the name straight away: two files converging on one output name
      // used to leave a single file behind, with both reported as converted.
      let final = try reserveUniqueURL(desired)
      return OutputPlan(
        finalURL: final,
        workURL: scratchURL(besides: final),
        reservationURL: final,
        replacesSource: false,
        removesSource: destinationMode == .moveTo
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

  private func outputName(for file: ProcessableFile, extension ext: String) -> String {
    let base = (file.fileName as NSString).deletingPathExtension
    return ext.isEmpty ? base : "\(base).\(ext)"
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
  let finalURL: URL
  /// The scratch file the conversion actually writes to.
  let workURL: URL
  /// A zero-byte file created to hold `finalURL`, cleaned up on failure.
  let reservationURL: URL?
  /// Whether this replaces a file the user already had.
  let replacesSource: Bool
  /// Whether the original should be removed once the output is in place.
  let removesSource: Bool
}
