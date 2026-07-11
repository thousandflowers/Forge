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
    cancelProcessing()
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

    let preset: RulePreset
    do {
      guard let loaded = try await PersistenceManager.shared.loadPreset(id: presetID) else {
        return
      }
      preset = loaded
    } catch {
      // Should not happen if UI disables button
      return
    }

    isProcessing = true
    progress = 0
    statusMap.removeAll()

    let total = files.count
    var processed = 0
    let limit = max(1, await coordinator.maxConcurrentNative)

    // Process in bounded waves so we never exceed `limit` concurrent conversions,
    // and report progress only as files actually finish.
    for start in stride(from: 0, to: files.count, by: limit) {
      let wave = files[start..<min(start + limit, files.count)]
      for file in wave { statusMap[file.id] = "Processing..." }

      await withTaskGroup(of: Void.self) { group in
        for file in wave {
          let fileId = file.id
          group.addTask {
            do {
              _ = try await self.coordinator.processFile(
                file,
                with: preset,
                destinationMode: destinationMode,
                destinationURL: destinationFolder
              ) { _ in }
              await MainActor.run { self.statusMap[fileId] = "Completed" }
            } catch {
              await MainActor.run { self.statusMap[fileId] = "Failed" }
            }
          }
        }
      }

      processed += wave.count
      progress = Double(processed) / Double(total)
    }

    isProcessing = false
  }

  func cancelProcessing() {
    Task { await coordinator.cancelAll() }
    isProcessing = false
  }
}
