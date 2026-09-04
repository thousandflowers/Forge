import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BatchProcessingView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var vm = BatchViewModel()

  @State private var selectedPresetID: UUID?
  @State private var destinationMode: DestinationMode = .copyTo
  @State private var destinationURL: URL?
  @State private var isTargeted = false

  private var preset: RulePreset? { model.presets.first { $0.id == selectedPresetID } }
  private var needsDestination: Bool { destinationMode != .overwrite }
  private var canConvert: Bool {
    !vm.files.isEmpty && preset != nil && !vm.isProcessing && (!needsDestination || destinationURL != nil)
  }

  var body: some View {
    Group {
      if vm.files.isEmpty {
        dropZone
      } else {
        VStack(spacing: 0) {
          fileTable
          Divider()
          controlBar
        }
      }
    }
    .navigationTitle("Convert")
    .toolbar {
      ToolbarItemGroup {
        Button { addFiles() } label: { Label("Add Files", systemImage: "plus") }
        Button(role: .destructive) { vm.clear() } label: { Label("Clear", systemImage: "trash") }
          .disabled(vm.files.isEmpty || vm.isProcessing)
      }
    }
    .onAppear { if selectedPresetID == nil { selectedPresetID = model.presets.first?.id } }
  }

  private var dropZone: some View {
    VStack(spacing: 14) {
      Image(systemName: "square.and.arrow.down.on.square")
        .font(.system(size: 52, weight: .light))
        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
      Text("Drop files to convert").font(.title2.weight(.medium))
      Text("Images, video, audio, and PDFs").font(.callout).foregroundStyle(.secondary)
      Button { addFiles() } label: { Label("Choose Files…", systemImage: "folder") }
        .controlSize(.large).padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 16)
        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.22))
    )
    .padding(28)
    .contentShape(Rectangle())
    .dropDestination(for: URL.self) { urls, _ in
      vm.add(urls); return true
    } isTargeted: { isTargeted = $0 }
    .animation(.easeOut(duration: 0.15), value: isTargeted)
  }

  private var fileTable: some View {
    Table(vm.files) {
      TableColumn("File") { f in Text(f.fileName).lineLimit(1).truncationMode(.middle) }
      TableColumn("Type") { f in
        Text(f.fileType.localizedDescription ?? f.fileType.preferredFilenameExtension ?? "—")
          .foregroundStyle(.secondary)
      }
      TableColumn("Size") { f in
        Text(formatBytes(f.fileSize)).foregroundStyle(.secondary).monospacedDigit()
      }
      TableColumn("Dimensions") { f in
        Text(f.dimensions.map { "\($0.width) × \($0.height)" } ?? "—").foregroundStyle(.secondary)
      }
      TableColumn("Status") { f in
        let status = vm.statusMap[f.id] ?? .pending
        if status == .processing, let fraction = vm.fileProgress[f.id] {
          ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 120)
        } else {
          statusLabel(status)
        }
      }
    }
  }

  private var controlBar: some View {
    VStack(spacing: 10) {
      if vm.isProcessing {
        ProgressView(value: vm.progress).progressViewStyle(.linear)
      }
      HStack(spacing: 14) {
        Picker("Preset", selection: $selectedPresetID) {
          Text("Choose preset…").tag(UUID?.none)
          ForEach(model.presets) { p in Text(p.name).tag(Optional(p.id)) }
        }
        .labelsHidden().frame(maxWidth: 220)

        Picker("Destination", selection: $destinationMode) {
          ForEach(DestinationMode.allCases, id: \.self) { m in Text(m.displayName).tag(m) }
        }
        .labelsHidden().frame(maxWidth: 170)

        if needsDestination {
          Button { chooseDestination() } label: {
            Label(destinationURL?.lastPathComponent ?? "Choose folder…", systemImage: "folder")
              .lineLimit(1)
          }
        }

        Spacer()

        Text(vm.files.count == 1 ? "1 file" : "\(vm.files.count) files")
          .font(.callout).foregroundStyle(.secondary)

        if vm.isProcessing {
          Button("Cancel") { vm.cancel(model: model) }
        } else {
          Button {
            if let preset {
              Task { await vm.convert(model: model, preset: preset, mode: destinationMode, destination: destinationURL) }
            }
          } label: { Text("Convert").frame(minWidth: 84) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConvert)
        }
      }
    }
    .padding()
  }

  private func addFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if panel.runModal() == .OK { vm.add(panel.urls) }
  }

  private func chooseDestination() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    if panel.runModal() == .OK { destinationURL = panel.url }
  }
}

@MainActor
final class BatchViewModel: ObservableObject {
  @Published var files: [ProcessableFile] = []
  @Published var statusMap: [UUID: FileStatus] = [:]
  @Published var fileProgress: [UUID: Double] = [:]
  @Published var isProcessing = false
  @Published var progress: Double = 0

  private let cancellation = CancellationFlag()

  func add(_ urls: [URL]) {
    let existing = Set(files.map(\.url))
    let added = urls.compactMap { try? ProcessableFile(url: $0) }.filter { !existing.contains($0.url) }
    files.append(contentsOf: added)
  }

  func clear() {
    files.removeAll()
    statusMap.removeAll()
    fileProgress.removeAll()
    progress = 0
  }

  func cancel(model: AppModel) {
    // The flag stops new files from being started; cancelling the coordinator
    // stops the ones already running. Doing only the second let the loop keep
    // queueing work after the user asked it to stop.
    cancellation.set()
    let coordinator = model.coordinator
    Task { await coordinator.cancelAll() }
  }

  func convert(model: AppModel, preset: RulePreset, mode: DestinationMode, destination: URL?) async {
    guard !files.isEmpty else { return }

    cancellation.reset()
    isProcessing = true
    progress = 0
    fileProgress.removeAll()
    defer { isProcessing = false }

    let coordinator = model.coordinator
    let limit = max(1, await coordinator.maxConcurrentNative)
    let total = files.count
    let cancellation = self.cancellation

    // Each file is packaged up here, on the main actor, so the group below
    // only ever touches values it is allowed to touch.
    let jobs: [Job] = files.map { file in
      let onProgress = progressHandler(for: file.id)
      return Job(id: file.id) {
        do {
          let entry = try await coordinator.processFile(
            file, with: preset, destinationMode: mode, destinationURL: destination,
            progress: onProgress
          )
          return Outcome(id: file.id, status: .completed, output: entry.outputURL)
        } catch is CancellationError {
          return Outcome(id: file.id, status: .cancelled, output: nil)
        } catch {
          return Outcome(id: file.id, status: .failed, output: nil)
        }
      }
    }

    var completed = 0

    // A new file starts the moment a slot frees up, instead of waiting for a
    // whole batch to drain: one long video no longer holds up everything queued
    // behind it.
    await withTaskGroup(of: Outcome.self) { group in
      var next = 0

      func spawn() async -> Bool {
        guard !cancellation.isSet, next < jobs.count else { return false }
        let job = jobs[next]
        next += 1
        await MainActor.run { self.statusMap[job.id] = .processing }
        group.addTask { await job.run() }
        return true
      }

      for _ in 0..<limit where await spawn() {}

      while let outcome = await group.next() {
        completed += 1
        let done = completed
        await MainActor.run {
          self.statusMap[outcome.id] = outcome.status
          self.fileProgress[outcome.id] = outcome.status == .completed ? 1 : 0
          self.progress = Double(done) / Double(total)
          if let output = outcome.output { model.remember(output) }
        }
        _ = await spawn()
      }
    }

    await model.refreshHistory()
  }

  /// Progress arrives off the main actor and far more often than the screen
  /// can use, so it is coalesced to whole percentage points.
  private func progressHandler(for id: UUID) -> @Sendable (Double) -> Void {
    { [weak self] fraction in
      Task { @MainActor in
        guard let self else { return }
        let rounded = (fraction * 100).rounded() / 100
        guard self.fileProgress[id] != rounded else { return }
        self.fileProgress[id] = rounded
      }
    }
  }
}

/// One queued conversion, ready to run away from the main actor.
private struct Job: Sendable {
  let id: UUID
  let run: @Sendable () async -> Outcome
}

private struct Outcome: Sendable {
  let id: UUID
  let status: FileStatus
  let output: URL?
}

/// A cancel flag both the main actor and the conversion tasks can see.
private final class CancellationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  func reset() {
    lock.lock()
    value = false
    lock.unlock()
  }
}
