import Foundation
import UniformTypeIdentifiers

/// What a file in a watched folder is asking for, read from its name.
///
/// The app and `forge watch` decide it here, so a name means the same thing in
/// both.
enum Arrival: Equatable {
  case leave
  case run(RulePreset)
  case ask(AskRequest)

  static func of(_ url: URL, folderPreset: RulePreset?, presets: [RulePreset], onlyWhenRenamed: Bool) -> Arrival {
    // A preset's own word first: the user made it up, so it beats Forge's.
    if let called = presets.first(where: { $0.isEnabled && $0.isTriggered(by: url) }) {
      guard called.accepts(url) else { return .leave }
      let questions = called.parameters.filter { $0.source == .prompt }
      return questions.isEmpty ? .run(called) : .ask(AskRequest(preset: called, questions: questions.map { .parameter($0) }))
    }

    let name = NameTokens.read(url.lastPathComponent)
    // Where every file is converted anyway, the bare word is more likely a
    // title: `how_to_ask.pdf`.
    if let word = name.ask, onlyWhenRenamed || word != .everything {
      return .ask(AskRequest(word: word, over: folderPreset?.accepts(url) == true ? folderPreset : nil))
    }
    if onlyWhenRenamed, name.isEmpty { return .leave }
    if let folderPreset, folderPreset.accepts(url) { return .run(folderPreset) }
    // A name that says what it wants needs no preset to say it again.
    return name.isEmpty ? .leave : .run(RulePreset(name: "From its name", description: "", category: .custom))
  }
}

/// A chain with something left to choose.
struct AskRequest: Equatable {
  enum Question: Hashable {
    case format, size, width, quality, privacy
    /// Something done to it, and several made into one.
    case tool, join
    /// By hand, in a window.
    case cut
    /// What is spoken in it.
    case language
    /// One the preset asks, under its own key.
    case parameter(PresetParameter)

    /// What is being chosen, whoever asks.
    var kind: PresetParameter.Kind? {
      switch self {
      case .size: return .maxFileSize
      case .width: return .width
      case .quality: return .quality
      case .parameter(let parameter): return parameter.kind
      case .format, .privacy, .tool, .join, .cut, .language: return nil
      }
    }

    var title: String {
      switch self {
      case .format: return "Comes out as"
      case .tool, .cut: return "Do this to it"
      case .join: return "All of them together"
      case .language: return "What is spoken in it"
      case .privacy: return "Remove location and camera details"
      case .parameter(let parameter) where !parameter.label.isEmpty: return parameter.label
      case .size, .width, .quality, .parameter:
        switch kind {
        case .maxFileSize: return "Stay under"
        case .width: return "How wide"
        default: return "How good"
        }
      }
    }
  }

  enum Answer: Hashable {
    case format(UTType)
    case bytes(Int)
    case number(Double)
    case flag(Bool)
    case tool(Tool)
    case join(Joiner.Kind)
    case cut
    case language(String)
  }

  var preset: RulePreset
  var questions: [Question]

  init(preset: RulePreset, questions: [Question]) {
    self.preset = preset
    self.questions = questions
  }

  /// A built-in word. One that asks about a single thing asks it over what the
  /// folder does anyway; `_ask` on its own starts from nothing.
  init(word: NameTokens.Ask, over folderPreset: RulePreset?) {
    var base = RulePreset(name: "Asked", description: "", category: .custom)
    if word != .everything, word != .format, let folderPreset {
      base = folderPreset.settled
      base.id = UUID()
      base.name = "Asked"
    }
    base.nameTrigger = word.rawValue
    preset = base
    switch word {
    case .everything: questions = [.join, .format, .language, .tool, .cut, .size, .privacy]
    case .format: questions = [.format]
    case .size: questions = [.size]
    case .width: questions = [.width]
    case .quality: questions = [.quality]
    }
  }

  /// The chain with the answers in it, ready to run.
  func answered(with answers: [Question: Answer]) -> RulePreset {
    var run = preset
    var spent: [String: Double] = [:]
    for question in questions {
      switch (question, answers[question]) {
      case (.format, .format(let type)):
        run.actions.removeAll(where: \.isFormat)
        run.actions.insert(.convertFormat(to: type), at: 0)
      case (.language, .language(let tag)):
        run = run.replacing(.recognizeText(languages: [tag]))
      case (.tool, .tool(let tool)):
        run.actions = run.actions.adding(tool)
      case (.privacy, .flag(true)):
        run = run.replacing(.stripMetadata(policy: .stripAll))
      case (.parameter(let parameter), .number(let value)):
        spent[parameter.key] = value
      case (.parameter(let parameter), .bytes(let bytes)):
        spent[parameter.key] = Double(bytes) / 1_000_000
      case (_, .bytes(let bytes)):
        run = run.replacing(.limitSize(bytes: bytes))
      case (.width, .number(let value)):
        run = run.replacing(.resize(width: Int(value), height: nil, fitMode: .proportional))
      case (.quality, .number(let value)):
        run = run.replacing(.quality(level: Int(value)))
      default: break
      }
    }
    return run.parameters.isEmpty ? run : run.answered(with: spent)
  }
}

/// The choices put in the menu. The sizes are the ones upload forms ask for;
/// what cannot help - a size above the file's, a width above the picture's -
/// is left out.
enum AskOptions {
  struct Choice: Identifiable, Equatable {
    let label: String
    let value: AskRequest.Answer
    var isDefault = false
    var id: String { label }
  }

  private static let imageSizes = [50_000, 100_000, 500_000, 1_000_000, 2_000_000]
  private static let filmSizes = [10_000_000, 25_000_000, 50_000_000, 100_000_000]
  private static let widths = [800, 1080, 1920, 2048]
  private static let qualities: [(String, Double)] = [("Small", 60), ("Balanced", 80), ("Best", 92)]

  static func choices(for question: AskRequest.Question, files: [ProcessableFile]) -> [Choice] {
    let kinds = Set(files.compactMap { ConvertKind(fileType: $0.fileType) })
    // Different kinds have nothing in common but what they make together.
    if question == .join { return Joiner.kinds(for: files).map { Choice(label: $0.title, value: .join($0)) } }
    guard kinds.count == 1, let kind = kinds.first else { return [] }
    var made = plain(question, kind: kind, files: files)

    // The default goes first, and says that it is one.
    if case .parameter(let parameter) = question {
      let value = answer(parameter.defaultValue, for: parameter.kind)
      made.removeAll { $0.value == value }
      made.insert(Choice(label: label(parameter.defaultValue, for: parameter.kind), value: value, isDefault: true), at: 0)
    }
    return made
  }

  private static func plain(_ question: AskRequest.Question, kind: ConvertKind, files: [ProcessableFile]) -> [Choice] {
    switch question {
    case .format:
      let own = Set(files.map(\.fileType))
      return kind.leading(of: kind.outputGroups(for: files).flatMap(\.formats))
        .filter { format in format.type.map { !own.contains($0) } ?? false }
        .compactMap { format in format.type.map { Choice(label: format.label, value: .format($0)) } }
    case .privacy:
      return [Choice(label: question.title, value: .flag(true))]
    case .tool:
      return Tool.handy(for: kind)
        .filter { tool in files.allSatisfy { tool.suits($0.fileType) } }
        .map { Choice(label: $0.title, value: .tool($0)) }
    case .language:
      guard kind == .video || kind == .audio else { return [] }
      return spoken.map { tag in Choice(label: Locale.current.localizedString(forLanguageCode: tag) ?? tag, value: .language(tag)) }
    case .cut:
      guard files.count == 1, [.image, .video, .audio].contains(kind) else { return [] }
      return [Choice(label: kind == .image ? "Crop…" : "Cut…", value: .cut)]
    case .join:
      return []
    case .size, .width, .quality, .parameter:
      switch question.kind {
      case .maxFileSize:
        let offered = kind == .image ? imageSizes : kind == .video ? filmSizes : []
        let largest = files.map(\.fileSize).max() ?? 0
        return offered.filter { $0 < largest }.map { Choice(label: label(Double($0) / 1_000_000, for: .maxFileSize), value: .bytes($0)) }
      case .width:
        guard kind.supportsResize else { return [] }
        let widest = files.compactMap { $0.dimensions?.width }.max() ?? .max
        return widths.filter { $0 < widest }.map { Choice(label: "\($0) px", value: .number(Double($0))) }
      case .quality:
        guard kind.supportsQuality else { return [] }
        return qualities.map { Choice(label: $0.0, value: .number($0.1)) }
      case nil: return []
      }
    }
  }

  /// The languages of whoever this Mac belongs to, and English, as the
  /// recogniser knows them.
  static let spoken: [String] = {
    let known = Transcription.supportedLocales.map { $0.replacingOccurrences(of: "_", with: "-") }
    var found: [String] = []
    for wanted in Locale.preferredLanguages + ["en-US"] {
      let code = wanted.split(separator: "-").first.map(String.init) ?? wanted
      guard let tag = known.first(where: { $0 == wanted }) ?? known.first(where: { $0.hasPrefix(code + "-") }),
            !found.contains(where: { $0.hasPrefix(code + "-") }) else { continue }
      found.append(tag)
    }
    return found
  }()

  private static func answer(_ value: Double, for kind: PresetParameter.Kind) -> AskRequest.Answer {
    kind == .maxFileSize ? .bytes(Int(value * 1_000_000)) : .number(value)
  }

  static func label(_ value: Double, for kind: PresetParameter.Kind) -> String {
    switch kind {
    case .maxFileSize: return Int64(value * 1_000_000).formatted(.byteCount(style: .file))
    case .width: return String(format: "%g px", value)
    case .quality: return String(format: "%g %%", value)
    }
  }

  /// Something typed instead of picked. Nil when it is not an answer.
  static func typed(_ text: String, for question: AskRequest.Question) -> AskRequest.Answer? {
    guard let kind = question.kind else { return nil }
    let tidy = text.lowercased().filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
    if kind == .maxFileSize {
      let bytes = SizeInName.bytes(in: tidy) ?? SizeInName.bytes(in: tidy + "mb")
      return bytes.map(AskRequest.Answer.bytes)
    }
    let digits = tidy.trimmingCharacters(in: CharacterSet(charactersIn: "px%q"))
    guard let value = Double(digits), kind.range.contains(value) else { return nil }
    return .number(value)
  }
}
