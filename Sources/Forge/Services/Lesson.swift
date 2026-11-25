import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Trying Forge out where it is used: a folder in the Finder with a few files
/// in it, really watched, and a small panel beside it that says what to try.
@MainActor
final class Lesson: ObservableObject {
  static let shared = Lesson()
  static let seenKey = "welcomeSeen"
  static var isNew: Bool { !UserDefaults.standard.bool(forKey: seenKey) }

  /// One file taken from a photo to a PDF, and then the other two.
  enum Step: Int, CaseIterable { case hello, scan, kind, word, drag, end }

  @Published private(set) var step = Step.hello
  /// It was done: said for a moment before the next thing.
  @Published private(set) var isDone = false
  @Published private(set) var problem: String?
  @Published private(set) var files: WelcomeSamples.Files?
  /// What the tiles turn into.
  @Published private(set) var formats: [[String]] = []
  /// What the recipe has been so far, to be looked at.
  @Published private(set) var chain: [NSImage] = []
  /// The names given at the end, and the one being given.
  @Published private(set) var tried: Set<String> = []
  @Published private(set) var trying: String?
  /// Which side of the panel the folder is on.
  @Published var isFolderOnTheLeft = true
  @Published var isLoud = true { didSet { score.isOn = isLoud } }

  private(set) weak var model: AppModel?
  private let score = WelcomeScore()
  private var panel: LessonPanel?
  private var watching: AnyCancellable?
  private var began = Date()
  private var going: Task<Void, Never>?

  func open(_ model: AppModel) {
    UserDefaults.standard.set(true, forKey: Self.seenKey)
    self.model = model
    guard panel == nil else { panel?.show(); return }
    step = .hello
    isDone = false
    problem = nil
    let panel = LessonPanel(self)
    self.panel = panel
    panel.show()
    Task { await score.begin() }
    Task { formats = await Task.detached(priority: .userInitiated) { WelcomeSamples.formats() }.value }
    // With no window, nobody else has.
    Task { await model.bootstrap() }
  }

  /// The folder, its files, and somebody watching it.
  func begin() {
    guard let model else { return }
    Task {
      do {
        let root = model.lessonRoot
        let made = try await Task.detached(priority: .userInitiated) { try WelcomeSamples.make(in: root) }.value
        files = made
        model.startLesson(in: made.folder)
        watching = model.$history.dropFirst().sink { [weak self] in self?.heard($0) }
        panel?.follow(made.folder)
        chain = NSImage(contentsOf: made.recipe).map { [$0] } ?? []
        go(to: .scan)
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  func next() {
    guard let next = Step(rawValue: step.rawValue + 1) else { return close() }
    go(to: next)
  }

  func back() {
    guard let before = Step(rawValue: step.rawValue - 1), before != .hello else { return }
    go(to: before)
  }

  private func go(to step: Step) {
    going?.cancel()
    score.play(step == .end ? .finale : .latch)
    // From here to the end: somebody may want to drag something else.
    if step == .drag { lendDragMenu() }
    withAnimation(Motion.move) {
      self.step = step
      isDone = false
      problem = nil
    }
    began = Date()
  }

  /// Whether it was off before, and so whether to keep it is a question.
  @Published private(set) var isDragMenuNew = false

  private func lendDragMenu() {
    guard let model, !model.isDragMenuOn else { return }
    isDragMenuNew = true
    model.lendDragMenu(true)
  }

  func showFolder() {
    guard let folder = files?.folder else { return }
    panel?.follow(folder)
  }

  func pop() { score.play(.pop) }
  func touch(_ tile: Int) { score.touch(tile) }

  /// And on to the program itself.
  func openForge(_ section: AppSection? = nil) {
    let model = model
    close()
    if let section { model?.section = section }
    model?.showWindow?()
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() {
    going?.cancel()
    watching = nil
    model?.endLesson()
    model?.lendDragMenu(false)
    isDragMenuNew = false
    score.end()
    panel?.close()
    panel = nil
    files = nil
    chain = []
    tried = []
    trying = nil
  }

  // MARK: - Whether it was done

  /// What has just been converted, if it is what was asked for.
  private func heard(_ history: [ProcessingHistory]) {
    guard !isDone, let folder = files?.folder,
          let entry = history.first(where: { $0.timestamp >= began && Self.isIn(folder, $0.fileURL) }) else { return }
    if entry.status == .failed {
      problem = entry.errorMessage
      trying = nil
      score.play(.thud)
      return
    }
    if step == .end { return came(entry) }
    guard entry.status == .completed, Self.answers(entry, step) else { return }
    problem = nil
    score.play(.shimmer)
    withAnimation(Motion.arrive) {
      isDone = true
      if step == .scan || step == .kind, let output = entry.outputURL, let image = NSImage(contentsOf: output) { chain.append(image) }
    }
    if step == .word, let output = entry.outputURL { score.play(output) }
    let pause = UInt64(pause(after: step) * 1_000_000_000)
    going = Task { [weak self] in
      try? await Task.sleep(nanoseconds: pause)
      guard !Task.isCancelled else { return }
      self?.next()
    }
  }

  /// Long enough to hear it, or to see it.
  private func pause(after step: Step) -> Double {
    switch step {
    case .word: return WelcomeTune.seconds + 0.2
    case .scan, .kind: return 4
    default: return 1.7
    }
  }

  static func isIn(_ folder: URL, _ file: URL) -> Bool {
    HandRenames.real(file.deletingLastPathComponent()).path == HandRenames.real(folder).path
  }

  static func answers(_ entry: ProcessingHistory, _ step: Step) -> Bool {
    let name = entry.fileURL.deletingPathExtension().lastPathComponent
    let from = entry.fileURL.pathExtension.lowercased(), to = entry.outputURL?.pathExtension.lowercased()
    switch step {
    case .hello, .end: return false
    case .kind: return name.hasPrefix(WelcomeSamples.recipe) && to != nil && to != "jpg"
    case .word: return from == "wav" && name.contains("_")
    case .drag: return from == "png" && !name.contains("_")
    case .scan: return from == "jpg" && name.contains("_scan")
    }
  }

  // MARK: - Doing it for somebody

  /// The name it is to be given, and the one it has now.
  func renaming() -> (from: URL, to: URL)? {
    guard let files else { return nil }
    func word(_ file: URL, _ word: String) -> (URL, URL) {
      (file, file.deletingLastPathComponent().appendingPathComponent(WelcomeSamples.Extra(name: file.lastPathComponent, word: word).given))
    }
    switch step {
    case .kind: return word(files.recipe, ".pdf")
    case .word: return word(files.sound, "_reverse")
    case .scan: return word(files.recipe, "_scan")
    case .hello, .drag, .end: return nil
    }
  }

  /// Asked again whenever something is tried: one of them is no longer a picture.
  func isThere(_ extra: WelcomeSamples.Extra) -> Bool {
    guard let folder = files?.folder else { return false }
    return FileManager.default.fileExists(atPath: folder.appendingPathComponent(extra.name).path)
  }

  /// One of the names at the end.
  func give(_ extra: WelcomeSamples.Extra) {
    guard trying == nil, let folder = files?.folder else { return }
    let old = folder.appendingPathComponent(extra.name)
    guard FileManager.default.fileExists(atPath: old.path) else {
      problem = "“\(extra.name)” is no longer in the folder."
      score.play(.thud)
      return
    }
    problem = nil
    began = Date()
    trying = extra.word
    rename(old, to: folder.appendingPathComponent(extra.given))
  }

  private func came(_ entry: ProcessingHistory) {
    guard let word = trying, entry.status == .completed else { return }
    trying = nil
    tried.insert(word)
    score.play(.shimmer)
    guard let output = entry.outputURL else { return }
    NSWorkspace.shared.selectFile(output.path, inFileViewerRootedAtPath: "")
    if UTType(filenameExtension: output.pathExtension)?.conforms(to: .audio) == true { score.play(output) }
  }

  func showHow() {
    guard let (from, to) = renaming() else { return }
    rename(from, to: to)
  }

  private func rename(_ from: URL, to: URL) {
    score.play(.pop)
    do {
      try FileManager.default.moveItem(at: from, to: to)
      NSWorkspace.shared.selectFile(to.path, inFileViewerRootedAtPath: "")
    } catch {
      problem = error.localizedDescription
      trying = nil
    }
  }
}
