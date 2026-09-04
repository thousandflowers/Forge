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
  @State private var showingAdjustments = false
  @State private var overrideFormat: OutputFormat = .keep
  @State private var overrideQuality: Double = 0
  @State private var overrideWidth = ""

  private var preset: RulePreset? { model.presets.first { $0.id == selectedPresetID } }

  /// The preset with this batch's adjustments applied, without touching the
  /// saved one. Converting one folder differently should not mean editing a
  /// preset and putting it back.
  private var effectivePreset: RulePreset? {
    guard var preset else { return nil }
    if let format = overrideFormat.type {
      preset = preset.replacing(.convertFormat(to: format))
    }
    if overrideQuality > 0 {
      preset = preset.replacing(.quality(level: Int(overrideQuality)))
    }
    if let width = Int(overrideWidth.trimmingCharacters(in: .whitespaces)), width > 0 {
      let mode = preset.resize?.fitMode ?? .proportional
      preset = preset.replacing(.resize(width: width, height: nil, fitMode: mode))
    }
    return preset
  }

  private var hasAdjustments: Bool {
    overrideFormat.type != nil || overrideQuality > 0 || !overrideWidth.isEmpty
  }
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

  private var controlBar: some View {
    VStack(spacing: 10) {
      if vm.isProcessing {
        ProgressView(value: vm.progress).progressViewStyle(.linear)
      }
      if showingAdjustments {
        adjustments
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

        Toggle(isOn: $showingAdjustments) {
          Label("Adjust", systemImage: hasAdjustments ? "slider.horizontal.3" : "slider.horizontal.below.rectangle")
        }
        .toggleStyle(.button)
        .help("Change the format, size or quality for this batch only")

        Spacer()

        Text(vm.files.count == 1 ? "1 file" : "\(vm.files.count) files")
          .font(.callout).foregroundStyle(.secondary)

        if vm.isProcessing {
          Button("Cancel") { vm.cancel(model: model) }
        } else {
          Button {
            if let preset = effectivePreset {
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

  /// Overrides for this batch only. Empty means "whatever the preset says".
  private var adjustments: some View {
    HStack(spacing: 14) {
      Picker("Format", selection: $overrideFormat) {
        Text("From preset").tag(OutputFormat.keep)
        Section("Images") { ForEach(OutputFormat.images) { Text($0.label).tag($0) } }
        Section("Audio") { ForEach(OutputFormat.audio) { Text($0.label).tag($0) } }
        Section("Video") { ForEach(OutputFormat.video) { Text($0.label).tag($0) } }
        Section("Documents") { ForEach(OutputFormat.documents) { Text($0.label).tag($0) } }
      }
      .frame(maxWidth: 200)

      HStack(spacing: 4) {
        Text("Width").foregroundStyle(.secondary)
        TextField("auto", text: $overrideWidth).frame(width: 60)
      }

      HStack(spacing: 6) {
        Text("Quality").foregroundStyle(.secondary)
        Slider(value: $overrideQuality, in: 0...100, step: 1).frame(width: 130)
        Text(overrideQuality > 0 ? "\(Int(overrideQuality))" : "preset")
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 46, alignment: .leading)
      }

      Spacer()

      Button("Reset") {
        overrideFormat = .keep
        overrideQuality = 0
        overrideWidth = ""
      }
      .disabled(!hasAdjustments)
    }
    .padding(.bottom, 4)
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
  @Published var statusMap: [UUID: ProcessingStatus] = [:]
  @Published var fileProgress: [UUID: Double] = [:]
  @Published var isProcessing = false
  @Published var progress: Double = 0

  private let cancellation = CancellationFlag()

  func add(_ urls: [URL]) {
    let existing = Set(files.map(\.url))
    let added = urls.compactMap { try? ProcessableFile(url: $0) }.filter { !existing.contains($0.url) }
    files.append(contentsOf: added)
    loadVideoDimensions(for: added)
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
    defer { isProcessing = false }

    let total = files.count
    let coordinator = model.coordinator
    let limit = await coordinator.maxConcurrentNative

    // Progress arrives far more often than the screen can use, so it is
    // coalesced before hopping to the main actor rather than after.
    let gates = ProgressGates()

    await Batch.run(
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
      Task { @MainActor [weak self] in self?.apply(event, of: total, in: model) }
    }

    await model.refreshHistory()

    if model.settings.notifyWhenFinished, !cancellation.isSet {
      let finished = statusMap.values
      await Notifier.batchFinished(
        converted: finished.filter { $0 == .completed }.count,
        failed: finished.filter { $0 == .failed }.count
      )
    }
  }

  private func apply(_ event: Batch.Event, of total: Int, in model: AppModel) {
    switch event {
    case .started(let id):
      statusMap[id] = .processing

    case .progress(let id, let fraction):
      fileProgress[id] = fraction

    case .finished(let id, let status, let output, _):
      statusMap[id] = status
      fileProgress[id] = status == .completed ? 1 : 0
      if let output { model.remember(output) }
      let done = statusMap.values.filter { $0 != .pending && $0 != .processing }.count
      progress = total > 0 ? Double(done) / Double(total) : 0
    }
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
