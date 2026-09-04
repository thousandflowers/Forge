import SwiftUI
import UniformTypeIdentifiers

struct PresetEditorView: View {
  @Environment(\.dismiss) private var dismiss
  private let existing: RulePreset?
  private let onSave: (RulePreset) -> Void

  @State private var name: String
  @State private var description: String
  @State private var category: PresetCategory
  @State private var formatChoice: FormatChoice
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
    _formatChoice = State(initialValue: FormatChoice(preset?.targetFormat))
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
          Picker("Format", selection: $formatChoice) {
            ForEach(FormatChoice.allCases) { Text($0.label).tag($0) }
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
    let resize: ResizeSpec? = enableResize
      ? ResizeSpec(width: Int(width), height: Int(height), fitMode: fitMode)
      : nil
    let preset = RulePreset(
      id: existing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      description: description,
      targetFormat: formatChoice.utType,
      resize: resize,
      quality: enableQuality ? Int(quality) : nil,
      filters: Array(filters),
      icon: existing?.icon,
      category: category,
      applicableFileTypes: existing?.applicableFileTypes
    )
    onSave(preset)
    dismiss()
  }
}

/// User-facing output-format choices, mapped to concrete UTTypes.
enum FormatChoice: String, CaseIterable, Identifiable {
  case keep, jpeg, png, heic, tiff, mp4, mov, mp3, m4a, wav
  var id: String { rawValue }

  init(_ type: UTType?) {
    switch type {
    case .some(.jpeg): self = .jpeg
    case .some(.png): self = .png
    case .some(.heic): self = .heic
    case .some(.tiff): self = .tiff
    case .some(.mpeg4Movie): self = .mp4
    case .some(.quickTimeMovie): self = .mov
    case .some(.mp3): self = .mp3
    case .some(.wav): self = .wav
    default:
      if let t = type, t.identifier == "com.apple.m4a-audio" { self = .m4a } else { self = .keep }
    }
  }

  var label: String { self == .keep ? "Keep original" : rawValue.uppercased() }

  var utType: UTType? {
    switch self {
    case .keep: return nil
    case .jpeg: return .jpeg
    case .png: return .png
    case .heic: return .heic
    case .tiff: return .tiff
    case .mp4: return .mpeg4Movie
    case .mov: return .quickTimeMovie
    case .mp3: return .mp3
    case .m4a: return UTType("com.apple.m4a-audio")
    case .wav: return .wav
    }
  }
}
