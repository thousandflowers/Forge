import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BatchProcessingView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var vm = BatchViewModel()

  @State private var choice = ConvertChoice()
  @State private var showingOptions = false
  @State private var isTargeted = false
  @State private var confirming = false

  /// The kinds of file in the list. What the sheet offers is decided from this,
  /// so a PDF is asked different questions than a video.
  private var kinds: Set<ConvertKind> {
    Set(vm.files.compactMap { ConvertKind(fileType: $0.fileType) })
  }

  private var totalSize: Int64 {
    vm.files.reduce(0) { $0 + $1.fileSize }
  }

  private var preset: RulePreset? { choice.resolved(against: model.presets) }

  var body: some View {
    VStack(spacing: 0) {
      if vm.files.isEmpty {
        dropZone
      } else {
        fileTable
      }
      // Nothing sits under the list while it waits: the settings live in the
      // sheet, and a bar of controls on an empty screen said nothing anybody
      // could act on.
      if vm.isProcessing {
        Divider()
        processingBar
      } else if let saving = vm.lastSaving {
        Divider()
        resultBar(saving)
      }

      if let skipped = vm.skipped {
        Divider()
        Label(skipped, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal).padding(.vertical, 8)
      }
    }
    // A drop is accepted anywhere on the screen. Hanging this on the empty
    // state meant dragging worked for the first file and silently stopped
    // working for the second.
    .dropDestination(for: URL.self) { urls, _ in
      add(urls)
      return true
    } isTargeted: { isTargeted = $0 }
    .overlay {
      if isTargeted, !vm.files.isEmpty {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(2)
          .allowsHitTesting(false)
      }
    }
    .animation(.easeOut(duration: 0.15), value: isTargeted)
    .navigationTitle("Convert")
    .toolbar {
      ToolbarItemGroup {
        Button { addFiles() } label: { Label("Add Files", systemImage: "plus") }
        // Nothing to clear is not a reason to show a disabled bin: it is a
        // reason for there to be no bin.
        if !vm.files.isEmpty {
          Button(role: .destructive) { clear() } label: { Label("Clear", systemImage: "trash") }
            .disabled(vm.isProcessing)
          Button { showingOptions = true } label: { Label("Convert…", systemImage: "slider.horizontal.3") }
            .disabled(vm.isProcessing)
        }
      }
    }
    .sheet(isPresented: $showingOptions) {
      ConvertOptionsSheet(
        kinds: kinds,
        fileCount: vm.files.count,
        totalSize: totalSize,
        presets: model.usablePresets,
        choice: $choice,
        onConvert: {
          // Overwrite and Move both change what is already on disk, so they are
          // worth a sentence before rather than an apology after.
          if choice.destinationMode == .copyTo { start() } else { confirming = true }
        }
      )
    }
    .confirmationDialog(summaryTitle, isPresented: $confirming) {
      Button(choice.destinationMode == .overwrite ? "Replace Files" : "Move Files", role: .destructive) {
        start()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(summary)
    }
  }

  private var dropZone: some View {
    VStack(spacing: 14) {
      Image(systemName: "square.and.arrow.down.on.square")
        .font(.system(size: 52, weight: .light))
        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
      Text("Drop files to convert").font(.title2.weight(.medium))
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
  }

  private var fileTable: some View {
    Table(vm.files) {
      TableColumn("File") { f in Text(f.fileName).lineLimit(1).truncationMode(.middle) }
      TableColumn("Type") { f in
        Text(f.fileType.localizedDescription ?? f.fileType.preferredFilenameExtension ?? "—")
          .foregroundStyle(.secondary)
      }
      TableColumn("Size") { f in
        Text(f.fileSize.formatted(.byteCount(style: .file)))
          .foregroundStyle(.secondary).monospacedDigit()
      }
      TableColumn("Dimensions") { f in
        Text(f.dimensions.map { "\($0.width) × \($0.height)" } ?? "—").foregroundStyle(.secondary)
      }
      TableColumn("Status") { f in
        let status = vm.statusMap[f.id] ?? .pending
        if status == .processing, let fraction = vm.fileProgress[f.id] {
          ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 120)
        } else {
          status.label
        }
      }
    }
  }

  private var processingBar: some View {
    HStack(spacing: 14) {
      ProgressView(value: vm.progress).progressViewStyle(.linear)
      Button("Cancel") { vm.cancel(model: model) }
    }
    .padding()
  }

  /// What the batch cost, once it is known. Measured, not promised.
  private func resultBar(_ saving: String) -> some View {
    HStack(spacing: 14) {
      Text(saving).font(.callout).foregroundStyle(.secondary)
      Spacer()
      Button("Convert Again…") { showingOptions = true }
    }
    .padding()
  }

  // MARK: - Doing it

  /// Adding files opens the sheet: the question "what should these become" is
  /// the whole reason the files were dropped, so it is asked straight away
  /// rather than waiting to be found in a toolbar.
  private func add(_ urls: [URL]) {
    let wasEmpty = vm.files.isEmpty
    vm.add(urls)
    if wasEmpty, !vm.files.isEmpty {
      // A batch starts from the general preference and can then disagree with
      // it, which is what makes the preference a default rather than a law.
      choice.fitMode = model.settings.defaultFitMode
      showingOptions = true
    }
  }

  private func clear() {
    vm.clear()
  }

  private func start() {
    guard let preset else { return }
    Task {
      await vm.convert(
        model: model,
        preset: preset,
        mode: choice.destinationMode,
        destination: choice.destinationURL
      )
    }
  }

  private var summaryTitle: String {
    choice.destinationMode == .overwrite
      ? (vm.files.count == 1 ? "Replace this file?" : "Replace these \(vm.files.count) files?")
      : (vm.files.count == 1 ? "Move this file?" : "Move these \(vm.files.count) files?")
  }

  /// What is about to happen, in the order it matters: what changes, where it
  /// goes, and whether anything can be got back.
  private var summary: String {
    var lines: [String] = []

    lines.append("\(vm.files.count) file\(vm.files.count == 1 ? "" : "s"), \(totalSize.formatted(.byteCount(style: .file)))")

    if let preset {
      let chain = preset.actions.map(PresetCard.chip).joined(separator: " · ")
      if !chain.isEmpty { lines.append(chain) }
    }

    switch choice.destinationMode {
    case .overwrite:
      lines.append(
        model.settings.createBackupBeforeOverwrite
          ? "The originals are replaced. A copy of each is kept in Backups."
          : "The originals are replaced and not kept."
      )
    case .moveTo:
      lines.append("The originals are removed once each conversion succeeds.")
    case .copyTo:
      break
    }

    return lines.joined(separator: "\n")
  }

  private func addFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if panel.runModal() == .OK { add(panel.urls) }
  }
}

@MainActor
final class BatchViewModel: ObservableObject {
  @Published var files: [ProcessableFile] = []
  @Published var statusMap: [UUID: ProcessingStatus] = [:]
  @Published var fileProgress: [UUID: Double] = [:]
  @Published var isProcessing = false
  @Published var progress: Double = 0
  /// What the last batch actually cost, once it is known. Guessing beforehand
  /// would be a guess; this is measured.
  @Published var lastSaving: String?
  /// What was dropped and not taken, and why. Files Forge cannot open used to
  /// be discarded without a word: drop ten and see seven, with nothing to say
  /// which three were missing or what was wrong with them.
  @Published var skipped: String?

  private let cancellation = CancellationFlag()

  func add(_ urls: [URL]) {
    // What the last batch cost describes files that are no longer the ones on
    // screen, so it stops being shown the moment the batch changes.
    lastSaving = nil
    skipped = nil

    let existing = Set(files.map(\.url))
    var added: [ProcessableFile] = []
    var unreadable: [URL] = []

    for url in urls {
      guard let file = try? ProcessableFile(url: url) else {
        unreadable.append(url)
        continue
      }
      guard !existing.contains(file.url), !added.contains(where: { $0.url == file.url }) else { continue }
      added.append(file)
    }

    files.append(contentsOf: added)
    loadVideoDimensions(for: added)
    skipped = Self.describe(unreadable)
  }

  /// The files that were turned away, named by what they are rather than
  /// counted: "Forge cannot open .zzz" is something to act on.
  static func describe(_ unreadable: [URL]) -> String? {
    guard !unreadable.isEmpty else { return nil }

    let kinds = Set(unreadable.map { $0.pathExtension.lowercased() })
      .filter { !$0.isEmpty }
      .sorted()
      .map { ".\($0)" }

    let what = kinds.isEmpty ? "those files" : kinds.joined(separator: ", ")
    return unreadable.count == 1
      ? "\(unreadable[0].lastPathComponent) was not added: Forge cannot open \(what)."
      : "\(unreadable.count) files were not added: Forge cannot open \(what)."
  }

  /// Video sizes need the asset opened, which is far too slow to do for every
  /// file while the drop is being handled. They fill in as they arrive.
  private func loadVideoDimensions(for added: [ProcessableFile]) {
    for file in added where file.dimensions == nil {
      Task { [weak self] in
        guard let size = await ProcessableFile.videoDimensions(url: file.url, type: file.fileType) else { return }
        guard let self, let index = self.files.firstIndex(where: { $0.id == file.id }) else { return }
        self.files[index].dimensions = size
      }
    }
  }

  func clear() {
    files.removeAll()
    statusMap.removeAll()
    fileProgress.removeAll()
    progress = 0
    lastSaving = nil
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

    let cancellation = self.cancellation
    cancellation.reset()
    isProcessing = true
    progress = 0
    fileProgress.removeAll()
    statusMap.removeAll()
    lastSaving = nil
    defer { isProcessing = false }

    let total = files.count
    let coordinator = model.coordinator
    let limit = await coordinator.maxConcurrentNative

    // Progress arrives far more often than the screen can use, so it is
    // coalesced before hopping to the main actor rather than after.
    let gates = ProgressGates()
    let outputs = OutputSizes()

    _ = await Batch.run(
      files,
      preset: preset,
      mode: mode,
      destination: destination,
      limit: limit,
      coordinator: coordinator,
      shouldContinue: { !cancellation.isSet }
    ) { [weak self] event in
      if case .progress(let id, let fraction) = event {
        guard gates.advance(id: id, to: (fraction * 100).rounded() / 100) else { return }
      }
      // Every file written, not the first one: the measured saving at the end
      // of a batch counted one output of a two-format conversion and called it
      // the total.
      if case .finished(_, _, _, let written, _) = event, !written.isEmpty {
        written.forEach(outputs.add)
      }
      Task { @MainActor [weak self] in self?.apply(event, of: total, in: model) }
    }

    lastSaving = Self.saving(from: outputs.paths(), sources: files)
    await model.refreshHistory()

    if model.settings.notifyWhenFinished, !cancellation.isSet {
      let finished = statusMap.values
      await Notifier.batchFinished(
        converted: finished.filter { $0 == .completed }.count,
        failed: finished.filter { $0 == .failed }.count
      )
    }
  }

  /// What the batch cost, compared with what went in. A pure reading of file
  /// sizes, so it belongs to nobody's actor.
  nonisolated static func saving(from outputs: [URL], sources: [ProcessableFile]) -> String? {
    guard !outputs.isEmpty else { return nil }
    let before = sources.reduce(Int64(0)) { $0 + $1.fileSize }
    let after = outputs.reduce(Int64(0)) { total, url in
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
      return total + (size ?? 0)
    }
    guard before > 0, after > 0 else { return nil }

    let written = after.formatted(.byteCount(style: .file))
    let change = Int(((Double(before) - Double(after)) / Double(before) * 100).rounded())
    if change > 0 { return "\(written) written, \(change)% smaller" }
    if change < 0 { return "\(written) written, \(-change)% larger" }
    return "\(written) written"
  }

  private func apply(_ event: Batch.Event, of total: Int, in model: AppModel) {
    switch event {
    case .started(let id):
      statusMap[id] = .processing

    case .progress(let id, let fraction):
      fileProgress[id] = fraction

    case .finished(let id, let status, let output, _, _):
      statusMap[id] = status
      fileProgress[id] = status == .completed ? 1 : 0
      if let output { model.remember(output) }
      let done = statusMap.values.filter { $0 != .pending && $0 != .processing }.count
      progress = total > 0 ? Double(done) / Double(total) : 0
    }
  }

}

/// Collects the outputs a batch produced, from whichever thread reports them.
private final class OutputSizes: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []

  func add(_ url: URL) {
    lock.lock()
    urls.append(url)
    lock.unlock()
  }

  func paths() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return urls
  }
}

/// Lets a progress value through only when it has actually moved, per file.
private final class ProgressGates: @unchecked Sendable {
  private let lock = NSLock()
  private var last: [UUID: Double] = [:]

  func advance(id: UUID, to value: Double) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard last[id] != value else { return false }
    last[id] = value
    return true
  }
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
