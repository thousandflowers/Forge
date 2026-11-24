import Foundation
import UniformTypeIdentifiers

/// A named chain of actions, applied in order.
///
/// A preset used to be a fixed set of fields - one format, one resize, one
/// quality - which meant the order was decided for you and there was no room
/// for a second filter or an action that had not been thought of. It is now a
/// list, the way Shortcuts is a list, and the editor builds it by stacking
/// actions rather than filling a form.
struct RulePreset: Identifiable, Codable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var description: String
  var category: PresetCategory

  /// Off presets stay where they are but are not offered anywhere. Turning one
  /// off is the answer to "I do not need this right now", which used to mean
  /// deleting it and making it again later.
  var isEnabled: Bool = true

  /// Where this sits in the list. Presets used to be sorted by name, which is
  /// tidy and not the order anyone works in.
  var position: Int = 0

  /// The actions, in the order they run.
  var actions: [Operation] = []

  /// What this preset asks for before it runs.
  ///
  /// A preset with no parameters is fixed: it does the same thing every time.
  /// One with parameters is a shape rather than a setting — "make it fit under
  /// a size you choose" — and the answer is asked for at conversion time and
  /// can be spent in the file's name.
  var parameters: [PresetParameter] = []

  /// Overrides the general name template for the files this preset writes.
  var nameTemplate: String? = nil

  /// The file extensions this preset takes, when it names them. `nil` means
  /// every file of its category. A custom preset with none named takes
  /// anything Forge can open.
  var inputFormats: [String]? = nil

  /// A word that starts this preset from a file's name: rename `foto.jpg` to
  /// `foto_web.jpg` in a watched folder and the preset with the word `web`
  /// runs on it, whatever the folder's own preset is. The word is dropped
  /// from the output's name.
  var nameTrigger: String? = nil

  /// The extension asked for, where it is one of several the format goes by:
  /// `--to jpg` was written as `.jpeg`. Nil takes the format's own name.
  var outputExtension: String? = nil

  /// A test the file has to pass, or the preset leaves it alone.
  var gate: Condition? = nil

  /// What the parameters were answered with, for this run only.
  ///
  /// Deliberately outside `CodingKeys`: an answer belongs to one conversion,
  /// not to the preset, and saving it would turn a question into a setting.
  var parameterValues: [String: Double] = [:]

  init(
    id: UUID = UUID(),
    name: String,
    description: String,
    category: PresetCategory,
    position: Int = 0,
    isEnabled: Bool = true,
    actions: [Operation] = []
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.category = category
    self.position = position
    self.isEnabled = isEnabled
    self.actions = actions
  }

  /// The same preset under another name: everything it does, asks and tests.
  ///
  /// Duplicate used to rebuild the copy from format, size, quality and filter,
  /// the four things the first presets had, and so lost the name template, the
  /// questions, the test and every block added since. The trigger word is the
  /// one thing left behind: two presets answering to one word would both
  /// claim the same renamed file.
  func duplicate() -> RulePreset {
    var copy = self
    copy.id = UUID()
    copy.name = "\(name) copy"
    copy.nameTrigger = nil
    copy.parameterValues = [:]
    return copy
  }

  /// Build a chain from the pieces a form would ask for. The order is the one
  /// that makes sense: change the format, then the size, then the quality,
  /// then anything applied on top.
  init(
    id: UUID = UUID(),
    name: String,
    description: String,
    targetFormat: UTType? = nil,
    resize: ResizeSpec? = nil,
    quality: Int? = nil,
    filters: [FilterType] = [],
    category: PresetCategory,
    ocrLanguages: [String] = []
  ) {
    self.init(
      id: id,
      name: name,
      description: description,
      category: category,
      actions: Self.chain(
        targetFormat: targetFormat,
        resize: resize,
        quality: quality,
        filters: filters,
        ocrLanguages: ocrLanguages
      )
    )
  }

  static func chain(
    targetFormat: UTType?,
    resize: ResizeSpec?,
    quality: Int?,
    filters: [FilterType],
    ocrLanguages: [String]
  ) -> [Operation] {
    var actions: [Operation] = []
    if let targetFormat { actions.append(.convertFormat(to: targetFormat)) }
    if let resize {
      actions.append(.resize(width: resize.width, height: resize.height, fitMode: resize.fitMode))
    }
    if let quality { actions.append(.quality(level: quality)) }
    actions.append(contentsOf: filters.map { .filter(type: $0) })
    // The language travels with the chain whenever one was given, not only
    // into plain text: a recording transcribed into a Word file, or a document
    // read aloud, asks the same question - which language is this in - and the
    // answer was being dropped on the way.
    if targetFormat?.conforms(to: .plainText) == true || !ocrLanguages.isEmpty {
      actions.append(.recognizeText(languages: ocrLanguages))
    }
    return actions
  }

  /// The actions, ready to run.

  /// Whether this preset would actually do anything.
  ///
  /// A preset with no steps could be saved, and converting with it copied the
  /// file and reported "1 converted" - work that looks like work and is not.
  var doesSomething: Bool { !actions.isEmpty }

  /// A preset that asks questions, finished by the answers: each one becomes
  /// the step it stands for, and the answers travel along so the file name can
  /// say what was asked for. A question nobody answered takes its default.
  func answered(with answers: [String: Double]) -> RulePreset {
    var answered = self
    for parameter in parameters {
      let value = answers[parameter.key] ?? parameter.defaultValue
      answered = answered.replacing(parameter.operation(for: value))
      answered.parameterValues[parameter.key] = value
    }
    return answered
  }

  /// The same preset with nothing left to ask. A question nobody was there to
  /// answer - in a watched folder, from the command line - takes its default;
  /// it used to be dropped, default and all.
  var settled: RulePreset {
    parameters.isEmpty || !parameterValues.isEmpty ? self : answered(with: [:])
  }

  /// A copy with `action` put in place of the one of its kind already there,
  /// or added if there is none.
  ///
  /// This is how the convert screen adjusts a preset for one batch without
  /// editing the preset itself.
  func replacing(_ action: Operation) -> RulePreset {
    var copy = self
    if let index = copy.actions.firstIndex(where: { $0.id == action.id }) {
      copy.actions[index] = action
    } else {
      copy.actions.append(action)
    }
    return copy
  }

  /// A copy without any action of that kind.
  func removing(_ kind: String) -> RulePreset {
    var copy = self
    copy.actions.removeAll { $0.id == kind }
    return copy
  }

  // MARK: - Reading the chain

  /// What the chain converts to, if it says.
  var targetFormat: UTType? {
    actions.flatMap(\.leaves).compactMap { if case .convertFormat(let to) = $0 { return to } else { return nil } }.first
  }

  var resize: ResizeSpec? {
    actions.compactMap { action -> ResizeSpec? in
      guard case .resize(let width, let height, let fitMode) = action else { return nil }
      return ResizeSpec(width: width, height: height, fitMode: fitMode)
    }.first
  }

  var quality: Int? {
    actions.compactMap { if case .quality(let level) = $0 { return level } else { return nil } }.first
  }

  var filters: [FilterType] {
    actions.compactMap { if case .filter(let type) = $0 { return type } else { return nil } }
  }

  var ocrLanguages: [String] {
    actions.compactMap { if case .recognizeText(let languages) = $0 { return languages } else { return nil } }
      .first ?? []
  }
}

extension RulePreset {
  private enum CodingKeys: String, CodingKey {
    case id, name, description, category, position, isEnabled, actions
    case parameters, nameTemplate, inputFormats, nameTrigger, gate, outputExtension
    // The shape presets were saved in before they became a chain.
    case targetFormat, resize, quality, filters, ocrLanguages
  }

  /// Decode tolerantly, and migrate.
  ///
  /// A preset saved before this change has separate fields and no `actions`,
  /// so the chain is rebuilt from them. Absence is handled for every field:
  /// the synthesized decoder does not fall back to a property's default, it
  /// fails, which would strand everything already in Application Support.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    category = try container.decodeIfPresent(PresetCategory.self, forKey: .category) ?? .custom
    position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

    // Both are newer than the presets already on disk, so absence is normal
    // and means "asks for nothing" and "use the general name template".
    parameters = try container.decodeIfPresent([PresetParameter].self, forKey: .parameters) ?? []
    nameTemplate = try container.decodeIfPresent(String.self, forKey: .nameTemplate)
    inputFormats = try container.decodeIfPresent([String].self, forKey: .inputFormats)
    nameTrigger = try container.decodeIfPresent(String.self, forKey: .nameTrigger)
    outputExtension = try container.decodeIfPresent(String.self, forKey: .outputExtension)
    gate = try container.decodeIfPresent(Condition.self, forKey: .gate)

    if let actions = try container.decodeIfPresent([Operation].self, forKey: .actions) {
      self.actions = actions
      return
    }

    self.actions = Self.chain(
      targetFormat: try container.decodeIfPresent(UTType.self, forKey: .targetFormat),
      resize: try container.decodeIfPresent(ResizeSpec.self, forKey: .resize),
      quality: try container.decodeIfPresent(Int.self, forKey: .quality),
      filters: try container.decodeIfPresent([FilterType].self, forKey: .filters) ?? [],
      ocrLanguages: try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? []
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(description, forKey: .description)
    try container.encode(category, forKey: .category)
    try container.encode(position, forKey: .position)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(actions, forKey: .actions)
    if !parameters.isEmpty { try container.encode(parameters, forKey: .parameters) }
    try container.encodeIfPresent(nameTemplate, forKey: .nameTemplate)
    try container.encodeIfPresent(inputFormats, forKey: .inputFormats)
    try container.encodeIfPresent(nameTrigger, forKey: .nameTrigger)
    try container.encodeIfPresent(outputExtension, forKey: .outputExtension)
    try container.encodeIfPresent(gate, forKey: .gate)
  }

  /// Whether the file's name carries this preset's trigger word, as `_word`
  /// before the extension.
  func isTriggered(by url: URL) -> Bool {
    guard let word = nameTrigger?.trimmingCharacters(in: .whitespaces).lowercased(), !word.isEmpty else { return false }
    let stem = url.deletingPathExtension().lastPathComponent.lowercased()
    return stem.split(separator: "_").dropFirst().contains(Substring(word))
  }

  /// The stem with the trigger word taken out: `foto_web` becomes `foto`.
  func untriggered(stem: String) -> String {
    guard let word = nameTrigger?.trimmingCharacters(in: .whitespaces).lowercased(), !word.isEmpty else { return stem }
    let pieces = stem.split(separator: "_").map(String.init)
    guard pieces.count > 1 else { return stem }
    return ([pieces[0]] + pieces.dropFirst().filter { $0.lowercased() != word }).joined(separator: "_")
  }

  /// Whether a file is one this preset takes.
  ///
  /// A preset that names formats takes only those. One that names none takes
  /// every file of its category, and a custom one takes anything at all -
  /// the sheet and the watcher both ask this before offering it.
  func accepts(_ url: URL) -> Bool {
    guard let inputFormats, !inputFormats.isEmpty else {
      guard category != .custom, let type = UTType(filenameExtension: url.pathExtension),
            let kind = ConvertKind(fileType: type) else { return true }
      return category.covers(kind)
    }
    return inputFormats.contains(url.pathExtension.lowercased())
  }
}

struct ResizeSpec: Codable, Hashable, Sendable {
  var width: Int?
  var height: Int?
  var fitMode: ResizeFitMode = .proportional
}

enum PresetCategory: String, Codable, CaseIterable, Sendable {
  case image
  case video
  case audio
  case document
  case data
  case model
  case subtitle
  case font
  /// Any file, or the formats the preset names for itself.
  case custom

  var icon: String {
    switch self {
    case .image: return "photo"
    case .video: return "film"
    case .audio: return "waveform"
    case .document: return "doc"
    case .data: return "tablecells"
    case .model: return "cube"
    case .subtitle: return "captions.bubble"
    case .font: return "textformat"
    case .custom: return "star"
    }
  }

  /// One file of this kind, for a sentence: "every image file".
  var noun: String {
    switch self {
    case .image: return "image"
    case .video: return "video"
    case .audio: return "audio"
    case .document: return "document"
    case .data: return "data"
    case .model: return "3D model"
    case .subtitle: return "subtitle"
    case .font: return "font"
    case .custom: return "chosen"
    }
  }

  /// Whether a file of this kind belongs to this category.
  ///
  /// Documents covers data files, 3D models, subtitles and fonts as well as
  /// documents: those kinds sat on the Documents shelf until they had shelves
  /// of their own, and a preset or a watched folder saved back then must keep
  /// taking the files it always took.
  func covers(_ kind: ConvertKind) -> Bool {
    if kind.presetCategory == self { return true }
    return self == .document && [.data, .model, .subtitle, .font].contains(kind)
  }

  var title: String {
    switch self {
    case .image: return "Images"
    case .video: return "Videos"
    case .audio: return "Audio"
    case .document: return "Documents"
    case .data: return "Data files"
    case .model: return "3D models"
    case .subtitle: return "Subtitles"
    case .font: return "Fonts"
    case .custom: return "Custom"
    }
  }

  /// Which kind of work a file of this type is in for.
  ///
  /// Asked once a file is actually in hand, so that what is offered for it
  /// suits what it is: a photograph has no business being offered Audio → MP3.
  /// `nil` for a type none of these describes, which is the signal to offer
  /// everything rather than nothing.
  init?(fileType: UTType) {
    if fileType.conforms(to: .image) {
      self = .image
    } else if fileType.conforms(to: .movie) {
      self = .video
    } else if fileType.conforms(to: .audio) {
      self = .audio
    } else if fileType.conforms(to: .pdf) || fileType.conforms(to: .text) {
      self = .document
    } else {
      return nil
    }
  }
}
