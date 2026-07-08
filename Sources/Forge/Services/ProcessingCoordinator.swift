import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// Coordinates file processing with concurrency control and memory monitoring
actor ProcessingCoordinator {
  private let registry: ProcessorRegistry
  private let nativeQueue: AsyncQueue
  private let externalQueue: AsyncQueue
  private let persistence: PersistenceManager
  private let settings: AppSettings

  // For progress reporting (per file ID → progress)
  private var progressHandlers: [UUID: @Sendable (Double) -> Void] = [:]

  // Active processing tasks for cancellation
  private var activeTasks: [UUID: Task<ProcessingHistory, Error>] = [:]

  init(registry: ProcessorRegistry, settings: AppSettings) {
    self.registry = registry
    self.settings = settings
    self.nativeQueue = AsyncQueue(maxConcurrent: settings.maxConcurrentNative)
    self.externalQueue = AsyncQueue(maxConcurrent: settings.maxConcurrentExternal)
    self.persistence = .shared
  }

  /// Process a single file with the given rule preset
  func processFile(
    _ file: ProcessableFile,
    with preset: RulePreset,
    destinationMode: DestinationMode,
    destinationURL: URL? = nil,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingHistory {
    let fileId = file.id

    // Create task so we can cancel later
    let task = Task {
      do {
        let result = try await self.executeProcessing(
          file: file,
          preset: preset,
          destinationMode: destinationMode,
          destinationURL: destinationURL,
          progress: progress
        )

        // Save to history
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
        // Save failed history
        let history = ProcessingHistory(
          fileURL: file.url,
          ruleId: preset.id,
          timestamp: Date(),
          status: .failed,
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

  /// Cancel processing for a specific file
  func cancelFile(_ file: ProcessableFile) {
    activeTasks[file.id]?.cancel()
    activeTasks.removeValue(forKey: file.id)
  }

  /// Cancel all processing
  func cancelAll() {
    for task in activeTasks.values {
      task.cancel()
    }
    activeTasks.removeAll()
  }

  /// Wait for all queued tasks to complete
  func waitForAll() async {
    await nativeQueue.waitForAll()
    await externalQueue.waitForAll()
  }


  // MARK: - Private

  private func executeProcessing(
    file: ProcessableFile,
    preset: RulePreset,
    destinationMode: DestinationMode,
    destinationURL: URL?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    // Find suitable processor
    guard let processor = registry.processor(for: file) else {
      throw ProcessingError.unsupportedFormat(file.fileType)
    }

    // Determine output URL
    let outputURL = try determineOutputURL(
      for: file,
      preset: preset,
      destinationMode: destinationMode,
      destinationFolder: destinationURL
    )

    // Ensure output directory exists
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    // Convert preset to operations
    let operations = preset.toOperations()

    // Validate operations for this processor
    try processor.validateOperations(operations, for: file.fileType)

    // Schedule on appropriate queue
    if processor.isNative {
      return try await withCheckedThrowingContinuation { cont in
        Task {
          do {
            let result = try await processor.process(
              file.url,
              to: outputURL,
              with: operations
            ) { fraction in
              // Global progress callback (0-1)
              progress(fraction)
            }
            cont.resume(returning: result)
          } catch {
            cont.resume(throwing: error)
          }
        }
      }
    } else {
      // External processor runs in its own queue
      return try await withCheckedThrowingContinuation { cont in
        Task {
          do {
            let result = try await processor.process(
              file.url,
              to: outputURL,
              with: operations
            ) { fraction in
              progress(fraction)
            }
            cont.resume(returning: result)
          } catch {
            cont.resume(throwing: error)
          }
        }
      }
    }
  }

  private func determineOutputURL(
    for file: ProcessableFile,
    preset: RulePreset,
    destinationMode: DestinationMode,
    destinationFolder: URL?
  ) throws -> URL {
    switch destinationMode {
    case .overwrite:
      // Overwrite original (with optional backup?)
      return file.url

    case .copyTo:
      guard let destFolder = destinationFolder else {
        throw ProcessingError.validationFailed(message: "Copy destination folder not specified")
      }
      let destFileName = applyRenameIfNeeded(file.fileName, preset: preset, outputExtension: preset.targetFormat?.preferredFilenameExtension ?? file.fileType.preferredFilenameExtension ?? "dat")
      return destFolder.appendingPathComponent(destFileName)

    case .moveTo:
      guard let destFolder = destinationFolder else {
        throw ProcessingError.validationFailed(message: "Move destination folder not specified")
      }
      let destFileName = applyRenameIfNeeded(file.fileName, preset: preset, outputExtension: preset.targetFormat?.preferredFilenameExtension ?? file.fileType.preferredFilenameExtension ?? "dat")
      return destFolder.appendingPathComponent(destFileName)
    }
  }

  private func applyRenameIfNeeded(_ originalName: String, preset: RulePreset, outputExtension: String) -> String {
    // If preset has rename operation, apply pattern
    if let renameOp = preset.toOperations().first(where: {
      if case .rename = $0 { return true } else { return false }
    }) {
      if case .rename(let pattern) = renameOp {
        let baseName = (originalName as NSString).deletingPathExtension
        let template = pattern.replacingOccurrences(of: "{name}", with: baseName)
        let ext = outputExtension
        return "\(template).\(ext)"
      }
    }

    // Default: change extension
    let baseName = (originalName as NSString).deletingPathExtension
    return "\(baseName).\(outputExtension)"
  }

  /// Get current queue statistics (for UI)
  func queueStatus() -> (nativeActive: Int, nativePending: Int, externalActive: Int, externalPending: Int) {
    // For MVP, we don't expose internal queue counts
    // Could add introspection to AsyncQueue if needed
    return (0, 0, 0, 0)
  }
}
