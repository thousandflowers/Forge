import Foundation
import UniformTypeIdentifiers
import SwiftUI

final class BatchProcessingViewModel: ObservableObject {
  @Published var files: [ProcessableFile] = []
  @Published var isProcessing = false
  @Published var progress: Double = 0
  @Published var statusMap: [UUID: String] = [:]
  @Published var availablePresets: [RulePreset] = []

  private let coordinator: ProcessingCoordinator
  private var processingTasks: [UUID: Task<Void, Never>] = [:]

  init(coordinator: ProcessingCoordinator) {
    self.coordinator = coordinator
    // In real app, get coordinator from DI container
    Task {
      await loadPresets()
    }
  }

  private func loadPresets() async {
    do {
      availablePresets = try await PersistenceManager.shared.loadAllPresets()
    } catch {
      availablePresets = []
    }
  }

  func addFiles(_ urls: [URL]) {
    let newFiles = urls.compactMap { url in
      try? ProcessableFile(url: url)
    }
    files.append(contentsOf: newFiles)
  }

  func clearFiles() {
    cancelAll()
    files.removeAll()
    statusMap.removeAll()
    progress = 0
  }

  func status(for fileId: UUID) -> String? {
    statusMap[fileId]
  }

  func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = .useKB
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  // MARK: - Processing

  @MainActor
  func startProcessing(
    presetID: UUID?,
    destinationMode: DestinationMode,
    destinationFolder: URL?
  ) async {
    guard let presetID = presetID else {
      // Should not happen if UI disables button
      return
    }

    do {
      preset = try await PersistenceManager.shared.loadPreset(id: presetID)
    } catch {
      // Should not happen if UI disables button
      return
    }

    isProcessing = true
    progress = 0
    statusMap.removeAll()

    let total = files.count
    var processed = 0

    for file in files {
      let fileId = file.id
      statusMap[fileId] = "Processing..."

      let task = Task {
        do {
          _ = try await coordinator.processFile(
            file,
            with: preset,
            destinationMode: destinationMode,
            destinationURL: destinationFolder
          ) { fileProgress in
            // Per-file progress
          }
          await MainActor.run {
            statusMap[fileId] = "Completed"
          }
        } catch {
          await MainActor.run {
            statusMap[fileId] = "Failed"
          }
        }
      }

      await MainActor.run {
        processed += 1
        self.progress = Double(processed) / Double(total)
      }
    }

    await coordinator.waitForAll()
    isProcessing = false
  }

  func cancelProcessing() {
    cancelAll()
    isProcessing = false
  }

  private func cancelAll() {
    for task in processingTasks.values {
      task.cancel()
    }
    processingTasks.removeAll()
  }
}
