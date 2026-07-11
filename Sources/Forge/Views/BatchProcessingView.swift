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
      TableColumn("Status") { f in statusLabel(vm.statusMap[f.id] ?? .pending) }
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
  @Published var isProcessing = false
  @Published var progress: Double = 0

  func add(_ urls: [URL]) {
    let existing = Set(files.map(\.url))
    let added = urls.compactMap { try? ProcessableFile(url: $0) }.filter { !existing.contains($0.url) }
    files.append(contentsOf: added)
  }

  func clear() {
    files.removeAll(); statusMap.removeAll(); progress = 0
  }

  func cancel(model: AppModel) {
    let coordinator = model.coordinator
    Task { await coordinator.cancelAll() }
    isProcessing = false
  }

  func convert(model: AppModel, preset: RulePreset, mode: DestinationMode, destination: URL?) async {
    guard !files.isEmpty else { return }
    isProcessing = true
    progress = 0
    let coordinator = model.coordinator
    let total = files.count
    var done = 0
    let limit = max(1, await coordinator.maxConcurrentNative)

    for start in stride(from: 0, to: files.count, by: limit) {
      let wave = Array(files[start..<min(start + limit, files.count)])
      for f in wave { statusMap[f.id] = .processing }

      let results = await withTaskGroup(of: (UUID, FileStatus).self) { group -> [(UUID, FileStatus)] in
        for f in wave {
          group.addTask {
            do {
              _ = try await coordinator.processFile(
                f, with: preset, destinationMode: mode, destinationURL: destination
              ) { _ in }
              return (f.id, .completed)
            } catch {
              return (f.id, .failed)
            }
          }
        }
        var out: [(UUID, FileStatus)] = []
        for await result in group { out.append(result) }
        return out
      }
      for (id, status) in results { statusMap[id] = status }

      done += wave.count
      progress = Double(done) / Double(total)
    }

    isProcessing = false
    await model.refreshHistory()
  }
}
