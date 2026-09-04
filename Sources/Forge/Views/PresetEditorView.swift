import SwiftUI
import UniformTypeIdentifiers

struct PresetEditorView: View {
  @Environment(\.dismiss) private var dismiss
  private let existing: RulePreset?
  private let onSave: (RulePreset) -> Void

  @State private var name: String
  @State private var description: String
  @State private var category: PresetCategory
  @State private var format: OutputFormat
  @State private var enableResize: Bool
  @State private var width: String
  @State private var height: String
  @State private var fitMode: ResizeFitMode
  @State private var enableQuality: Bool
  @State private var quality: Double
  @State private var filters: Set<FilterType>

  init(preset: RulePreset?, onSave: @escaping (RulePreset) -> Void) {
    self.existing = preset
    self.onSave = onSave
    _name = State(initialValue: preset?.name ?? "")
    _description = State(initialValue: preset?.description ?? "")
    _category = State(initialValue: preset?.category ?? .image)
    _format = State(initialValue: OutputFormat.matching(preset?.targetFormat))
    _enableResize = State(initialValue: preset?.resize != nil)
    _width = State(initialValue: preset?.resize?.width.map(String.init) ?? "")
    _height = State(initialValue: preset?.resize?.height.map(String.init) ?? "")
    _fitMode = State(initialValue: preset?.resize?.fitMode ?? .proportional)
    _enableQuality = State(initialValue: preset?.quality != nil)
    _quality = State(initialValue: Double(preset?.quality ?? 80))
    _filters = State(initialValue: Set(preset?.filters ?? []))
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
          TextField("Description", text: $description)
          Picker("Category", selection: $category) {
            ForEach(PresetCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
          }
        }
        Section("Output") {
          Picker("Format", selection: $format) {
            Text(OutputFormat.keep.label).tag(OutputFormat.keep)
            Section("Images") {
              ForEach(OutputFormat.images) { Text($0.label).tag($0) }
            }
            Section("Audio") {
              ForEach(OutputFormat.audio) { Text($0.label).tag($0) }
            }
            Section("Video") {
              ForEach(OutputFormat.video) { Text($0.label).tag($0) }
            }
          }
          Toggle("Resize", isOn: $enableResize)
          if enableResize {
            HStack {
              TextField("Width", text: $width).frame(width: 80)
              Text("×").foregroundStyle(.secondary)
              TextField("Height", text: $height).frame(width: 80)
            }
            Picker("Fit mode", selection: $fitMode) {
              ForEach(ResizeFitMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
          }
          Toggle("Quality", isOn: $enableQuality)
          if enableQuality {
            HStack {
              Slider(value: $quality, in: 1...100, step: 1)
              Text("\(Int(quality))").monospacedDigit().frame(width: 34, alignment: .trailing)
            }
          }
        }
        Section("Filters") {
          ForEach(FilterType.allCases, id: \.self) { filter in
            Toggle(filter.rawValue.capitalized, isOn: Binding(
              get: { filters.contains(filter) },
              set: { on in if on { filters.insert(filter) } else { filters.remove(filter) } }
            ))
          }
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding()
    }
    .frame(width: 460, height: 580)
  }

  private func save() {
    // "Resize" with nothing typed into either box, or with text that is not a
    // positive number, is not a resize at all.
    let resize: ResizeSpec? = {
      guard enableResize else { return nil }
      let w = Int(width.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
      let h = Int(height.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
      guard w != nil || h != nil else { return nil }
      return ResizeSpec(width: w, height: h, fitMode: fitMode)
    }()
    let preset = RulePreset(
      id: existing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      description: description,
      targetFormat: format.type,
      resize: resize,
      quality: enableQuality ? Int(quality) : nil,
      filters: Array(filters),
      category: category,
    )
    onSave(preset)
    dismiss()
  }
}

/// The output formats offered in the editor, taken from what this machine can
/// really write rather than a list typed out by hand. The old list offered MP3,
/// which AVFoundation cannot encode, and omitted most of what does work.
struct OutputFormat: Identifiable, Hashable {
  /// `nil` means "keep the source format".
  let type: UTType?

  var id: String { type?.identifier ?? "keep" }

  var label: String {
    guard let type else { return "Keep original" }
    return type.preferredFilenameExtension?.uppercased() ?? type.identifier
  }

  static let keep = OutputFormat(type: nil)

  static var images: [OutputFormat] { Self.sorted(FormatCatalog.writableImageTypes) }
  static var audio: [OutputFormat] { Self.sorted(Set(FormatCatalog.writableAudioTypes.keys)) }
  static var video: [OutputFormat] { Self.sorted(FormatCatalog.writableVideoTypes) }

  static func matching(_ type: UTType?) -> OutputFormat {
    guard let type else { return .keep }
    return OutputFormat(type: type)
  }

  private static func sorted(_ types: Set<UTType>) -> [OutputFormat] {
    types
      .map { OutputFormat(type: $0) }
      .sorted { $0.label < $1.label }
  }
}
