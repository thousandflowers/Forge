import AppKit
import SwiftUI

/// Puts a question on screen when a file's name asks for one, and runs the
/// answer.
///
/// One question at a time. Files that ask the same thing while it is still up
/// join it; a different question waits its turn.
@MainActor
final class AskCenter: ObservableObject {
  typealias Convert = @MainActor (ProcessableFile, RulePreset) async throws -> [URL]
  typealias Join = @MainActor ([ProcessableFile], Joiner.Kind) async throws -> URL
  typealias Preview = @MainActor (ProcessableFile, RulePreset, URL) async throws -> ProcessingResult

  @Published private(set) var current: AskSession?
  private var queue: [AskSession] = []
  private let shows: Bool
  private var panel: AskPanel?
  var preview: Preview?
  var suggest: (([ProcessableFile]) -> [RulePreset])?
  var cut: (@MainActor (ProcessableFile) -> Void)?

  var waiting: Int { queue.count }

  /// - Parameter shows: off in tests, where there is no screen to ask on.
  init(shows: Bool = true) { self.shows = shows }

  /// - Parameter scope: the folder that asks. Where files go is the folder's to
  ///   say, so two folders are never one question.
  func ask(_ request: AskRequest, from scope: UUID? = nil, about file: ProcessableFile, convert: @escaping Convert) {
    for session in [current].compactMap({ $0 }) + queue where session.takes(request, from: scope, file) {
      if !session.files.contains(where: { $0.url == file.url }) { session.files.append(file) }
      return
    }
    let session = AskSession(request: request, scope: scope, file: file, convert: convert, preview: preview)
    session.cut = cut
    session.suggest = suggest
    session.onClose = { [weak self, weak session] in
      guard let self, self.current === session else { return }
      self.dismiss()
    }
    if current == nil { show(session) } else { queue.append(session) }
  }

  /// Close the question. Whatever was not answered is left exactly as it is.
  func dismiss() {
    current?.stop()
    panel?.close()
    panel = nil
    current = nil
    if !queue.isEmpty { show(queue.removeFirst()) }
  }

  private func show(_ session: AskSession) {
    current = session
    guard shows else { return }
    let panel = AskPanel(session: session) { [weak self] in self?.dismiss() }
    self.panel = panel
    panel.appear()
    session.measure()
  }
}

/// One question, the files it is about, and how far it has got.
@MainActor
final class AskSession: ObservableObject {
  enum State {
    case asking
    case working(Double)
    case done([URL])
    case failed(String)
  }

  let request: AskRequest
  private let scope: UUID?
  @Published var files: [ProcessableFile] { didSet { lookUp() } }
  @Published private(set) var answers: [AskRequest.Question: AskRequest.Answer] = [:]
  @Published private(set) var state: State = .asking
  /// What each choice would really come out as, measured on the first file.
  @Published private(set) var measured: [AskRequest.Answer: String] = [:]
  /// Whether what is wanted now and then is shown as well.
  @Published var showsMore = false { didSet { if showsMore, !oldValue { measure(again: false) } } }
  var onClose: () -> Void = {}

  private let convert: AskCenter.Convert
  private let preview: AskCenter.Preview?
  /// Nil where files come one at a time, and are never all of them together.
  var join: AskCenter.Join?
  /// The user's own presets for these files. Nil where they are not offered.
  var suggest: (([ProcessableFile]) -> [RulePreset])? { didSet { lookUp() } }
  /// Kept, rather than asked for every time the panel is drawn.
  private var suggested: [RulePreset] = []
  /// Nil where there is no window to cut in.
  var cut: (@MainActor (ProcessableFile) -> Void)?
  private var measuring: Task<Void, Never>?
  private var working: Task<Void, Never>?
  private let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("ForgeAsk-\(UUID().uuidString)", isDirectory: true)

  init(request: AskRequest, scope: UUID? = nil, file: ProcessableFile, convert: @escaping AskCenter.Convert, preview: AskCenter.Preview? = nil) {
    self.request = request
    self.scope = scope
    files = [file]
    self.convert = convert
    self.preview = preview
  }

  func takes(_ other: AskRequest, from folder: UUID?, _ file: ProcessableFile) -> Bool {
    guard case .asking = state, scope == folder else { return false }
    // A built-in word makes its chain afresh for every file, so it is compared
    // by what it does.
    return request.questions == other.questions && request.preset.runs(like: other.preset) && ConvertKind(fileType: file.fileType) == files.first.flatMap { ConvertKind(fileType: $0.fileType) }
  }

  var isWorking: Bool { if case .working = state { return true } else { return false } }

  func choices(for question: AskRequest.Question) -> [AskOptions.Choice] {
    let found = AskOptions.choices(for: question, files: files)
    guard question == .forYou else { return found }
    return found + suggested.map { AskOptions.Choice(label: $0.name, value: .preset($0)) }
  }

  private func lookUp() { suggested = suggest?(files) ?? [] }

  /// The questions these files can really be asked.
  var questions: [AskRequest.Question] {
    request.questions.filter { ($0 != .join || join != nil) && ($0 != .forYou || suggest != nil) && ($0 != .cut || cut != nil) && ($0 != .language || asksLanguage) && !choices(for: $0).isEmpty }
  }

  /// Once what is said is what is wanted, and there is more than one to choose
  /// from.
  private var asksLanguage: Bool {
    guard case .format(let type)? = answers[.format] else { return false }
    return (MediaProcessor.isWords(type) || Subtitles.carriesCues(Conversions.fileExtension(of: type))) && AskOptions.spoken.count > 1
  }

  /// Folded only where there is something else to see: one question is asked
  /// outright.
  var folds: Bool { questions.contains { !$0.isSecondary } && questions.contains(where: \.isSecondary) }
  var shownQuestions: [AskRequest.Question] { folds && !showsMore ? questions.filter { !$0.isSecondary } : questions }

  /// Files of one kind are asked about; of several, nothing suits them all.
  var isMixed: Bool { Set(files.map { ConvertKind(fileType: $0.fileType) }).count > 1 }

  /// A lone question is answered by pressing the answer.
  var answersAtOnce: Bool { questions.count == 1 && questions[0] != .privacy }

  var canRun: Bool { request.answered(with: answers).actions != request.preset.actions || !request.preset.actions.isEmpty }

  func choose(_ answer: AskRequest.Answer?, for question: AskRequest.Question) {
    if answer == .cut { return openTheCutter() }
    answers[question] = answer
    // Made into one they are not made into anything else as well.
    // And a preset is the whole recipe.
    if question == .join, answer != nil { answers = answers.filter { $0.key == .join } }
    if question != .join, answer != nil { answers[.join] = nil }
    if case .preset? = answer { answers = answers.filter { $0.key == question } }
    if question != .forYou, answer != nil, case .preset? = answers[.forYou] { answers[.forYou] = nil }
    // What the other choices come to has just changed.
    if questions.count > 1 { measure() }
  }

  /// What is cut is cut somewhere else, and this has no more to ask.
  private func openTheCutter() {
    guard let file = files.first, let cut else { return }
    stop()
    cut(file)
    onClose()
  }

  /// Run the answer, where closing the panel can stop it.
  func start() {
    guard case .asking = state, working == nil else { return }
    working = Task { await run() }
  }

  /// How far whatever is being converted has got, for whoever converts it to say.
  @TaskLocal static var progress: (@Sendable (Double) -> Void)?

  func run() async {
    guard case .asking = state else { return }
    stopMeasuring()
    let preset = request.answered(with: answers)
    var outputs: [URL] = []
    var failures: [String] = []
    state = .working(0)
    if case .join(let kind)? = answers[.join], let join {
      do { state = .done([try await join(files, kind)]) } catch is CancellationError {
        state = .failed("Stopped before it finished.")
      } catch { state = .failed(error.localizedDescription) }
      return
    }
    for (index, file) in files.enumerated() {
      do {
        let count = Double(files.count)
        outputs += try await Self.$progress.withValue({ [weak self] share in
          Task { @MainActor in self?.advance(to: (Double(index) + share) / count) }
        }) { try await convert(file, preset) }
      } catch is CancellationError {
        state = .failed("Stopped before it finished.")
        return
      } catch {
        // The rest are still wanted, and nothing would ask about them again.
        failures.append(error.localizedDescription)
      }
      state = .working(Double(index + 1) / Double(files.count))
    }
    if let first = failures.first {
      state = .failed(files.count == 1 ? first : "\(failures.count) of \(files.count) could not be converted. \(first)")
    } else {
      state = .done(outputs)
    }
  }

  private func advance(to fraction: Double) {
    if case .working(let already) = state, fraction > already { state = .working(min(fraction, 1)) }
  }

  /// Stop everything: what is being measured, and what is being converted.
  func stop() {
    working?.cancel()
    working = nil
    stopMeasuring()
  }

  private func stopMeasuring() {
    measuring?.cancel()
    measuring = nil
    try? FileManager.default.removeItem(at: scratch)
  }

  /// Each choice tried on the first file, so the menu says what comes out
  /// rather than what was asked for. Pictures only: trying a film takes as
  /// long as converting it.
  /// - Parameter again: what is known already is no longer so.
  func measure(again: Bool = true) {
    guard let preview, let file = files.first, ConvertKind(fileType: file.fileType) == .image else { return }
    measuring?.cancel()
    if again { measured = [:] }
    let asked = shownQuestions.filter { $0 != .privacy && $0 != .join && $0 != .cut && $0 != .language }
    let given = answers
    measuring = Task { [weak self] in
      for question in asked {
        guard let self else { return }
        for choice in self.choices(for: question) {
          guard !Task.isCancelled else { return }
          if self.measured[choice.value] != nil { continue }
          let folder = self.scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
          try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let tried = given.merging([question: choice.value]) { _, new in new }
          let result = try? await preview(file, self.request.answered(with: tried), folder)
          try? FileManager.default.removeItem(at: folder)
          guard !Task.isCancelled else { return }
          self.measured[choice.value] = result.map(Self.describe) ?? "cannot"
        }
      }
    }
  }

  private static func describe(_ result: ProcessingResult) -> String {
    let size = result.outputSize.formatted(.byteCount(style: .file))
    return result.outputDimensions.map { "\(size) · \($0.width) × \($0.height)" } ?? size
  }
}
