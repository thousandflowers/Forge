import AppKit
import Combine
import SwiftUI

/// Trying Forge out where it is used: a folder in the Finder with a few files
/// in it, really watched, and a small panel beside it that says what to try.
@MainActor
final class Lesson: ObservableObject {
  static let shared = Lesson()
  static let seenKey = "welcomeSeen"
  static var isNew: Bool { !UserDefaults.standard.bool(forKey: seenKey) }

  /// One file each, and each its own gesture.
  enum Step: Int, CaseIterable { case hello, kind, word, drag, end }

  @Published private(set) var step = Step.hello
  /// It was done: said for a moment before the next thing.
  @Published private(set) var isDone = false
  @Published private(set) var problem: String?
  @Published private(set) var files: WelcomeSamples.Files?
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
        go(to: .kind)
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
    score.play(step == .end ? .hello : .latch)
    withAnimation(Motion.move) {
      self.step = step
      isDone = false
      problem = nil
    }
    began = Date()
  }

  func showFolder() {
    guard let folder = files?.folder else { return }
    panel?.follow(folder)
  }

  func pop() { score.play(.pop) }

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
    score.end()
    panel?.close()
    panel = nil
    files = nil
  }

  // MARK: - Whether it was done

  /// What has just been converted, if it is what was asked for.
  private func heard(_ history: [ProcessingHistory]) {
    guard !isDone, let folder = files?.folder,
          let entry = history.first(where: { $0.timestamp >= began && Self.isIn(folder, $0.fileURL) }) else { return }
    if entry.status == .failed {
      problem = entry.errorMessage
      score.play(.thud)
      return
    }
    guard entry.status == .completed, Self.answers(entry, step) else { return }
    problem = nil
    score.play(.shimmer)
    withAnimation(Motion.arrive) { isDone = true }
    if step == .word, let output = entry.outputURL { score.play(output) }
    let pause: UInt64 = step == .word ? 6_200_000_000 : 1_700_000_000
    going = Task { [weak self] in
      try? await Task.sleep(nanoseconds: pause)
      guard !Task.isCancelled else { return }
      self?.next()
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
    case .kind: return name.hasPrefix(WelcomeSamples.letter) && to != nil && to != "md"
    case .word: return from == "wav" && name.contains("_")
    case .drag: return from == "png" && !name.contains("_")
    }
  }

  // MARK: - Doing it for somebody

  /// The name it is to be given, and the one it has now.
  func renaming() -> (from: URL, to: URL)? {
    guard let files else { return nil }
    switch step {
    case .kind: return (files.letter, files.letter.deletingPathExtension().appendingPathExtension("pdf"))
    case .word:
      let file = files.sound, name = file.deletingPathExtension().lastPathComponent
      return (file, file.deletingLastPathComponent().appendingPathComponent("\(name)_reverse").appendingPathExtension(file.pathExtension))
    case .hello, .drag, .end: return nil
    }
  }

  func showHow() {
    guard let (from, to) = renaming() else { return }
    score.play(.pop)
    do {
      try FileManager.default.moveItem(at: from, to: to)
      NSWorkspace.shared.selectFile(to.path, inFileViewerRootedAtPath: "")
    } catch {
      problem = error.localizedDescription
    }
  }
}
