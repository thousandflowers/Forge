import XCTest
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Forge

/// Everything Forge offers, tried on real files: each file it says it reads,
/// into every format the sheet would offer for that file, and through every
/// preset that suits it.
///
/// The rule is the one a person relies on. A conversion either leaves a file
/// that opens, or says why it did not. What it must never do is report success
/// over an empty or unreadable file, hang, or leave scratch files behind.
///
/// It needs real files, one per format, which the repository does not carry:
///
///     FORGE_CONFORMANCE_FIXTURES=/path/to/folder   one file per format, any names
///     FORGE_CONFORMANCE_PRESETS=/path/to/Presets   optional: saved presets to run as well
///     FORGE_CONFORMANCE_REPORT=/path/to/report.tsv optional: every attempt, one per line
///     FORGE_CONFORMANCE_OUTPUT=/path/to/folder     optional: keep what was written, to look at
///
/// `Scripts/conformance.sh` makes the folder, runs these and checks what came
/// out with other tools. Without the folder the tests skip.
final class ConformanceTests: BaseTestCase {

  // MARK: - What happened to one attempt

  private enum Outcome: String {
    case ok
    /// Forge said no, and said why.
    case refused
    /// Reported as converted, and there is nothing there.
    case empty
    /// Reported as converted, and it does not open.
    case unreadable
    /// Still running when the patience ran out.
    case timedOut
    /// Scratch files left where the user would find them.
    case leftover
    /// Offered, and then turned down for being that pair of formats - which is
    /// what the sheet promises never to do.
    case offeredAndTurnedDown

    var isHonest: Bool { self == .ok || self == .refused }
  }

  private struct Attempt {
    let input: String
    let kind: String
    let output: String
    let outcome: Outcome
    let seconds: Double
    let detail: String

    var line: String {
      [input, kind, output, outcome.rawValue, String(format: "%.2f", seconds), detail]
        .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        .joined(separator: "\t")
    }
  }

  /// Writes each attempt as it finishes, so a crash halfway still leaves the
  /// record of how far it got and which file it was on.
  private final class Report: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [Attempt] = []
    private let handle: FileHandle?

    init(named name: String) {
      guard let base = ProcessInfo.processInfo.environment["FORGE_CONFORMANCE_REPORT"] else {
        handle = nil
        return
      }
      let url = URL(fileURLWithPath: base).deletingPathExtension()
        .appendingPathExtension(name).appendingPathExtension("tsv")
      FileManager.default.createFile(atPath: url.path, contents: nil)
      handle = try? FileHandle(forWritingTo: url)
    }

    func add(_ attempt: Attempt) {
      lock.lock()
      defer { lock.unlock() }
      attempts.append(attempt)
      handle?.write(Data((attempt.line + "\n").utf8))
    }

    var all: [Attempt] {
      lock.lock()
      defer { lock.unlock() }
      return attempts
    }
  }

  // MARK: - The files

  private func fixtures() throws -> [ProcessableFile] {
    guard let folder = ProcessInfo.processInfo.environment["FORGE_CONFORMANCE_FIXTURES"] else {
      throw XCTSkip("Set FORGE_CONFORMANCE_FIXTURES to a folder of real files, one per format.")
    }
    let urls = try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    )
    return urls
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { try? ProcessableFile(url: $0) }
  }

  // MARK: - Trying one

  private struct TimedOut: Error {}

  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if taken { return false }
      taken = true
      return true
    }
  }

  /// Whichever comes first, the work or the clock. Work that ignores
  /// cancellation is left behind rather than waited for: that it never came
  /// back is the finding.
  private func race<T: Sendable>(
    seconds: Double, _ work: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { continuation in
      Task {
        do {
          let value = try await work()
          if once.take() { continuation.resume(returning: value) }
        } catch {
          if once.take() { continuation.resume(throwing: error) }
        }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if once.take() { continuation.resume(throwing: TimedOut()) }
      }
    }
  }

  /// Whether what was written is something, judged by what it claims to be.
  private func verdict(on output: URL) -> (Outcome, String) {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isFolder) else {
      return (.empty, "reported \(output.lastPathComponent), which is not there")
    }
    if isFolder.boolValue {
      let inside = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
      return inside.isEmpty ? (.empty, "an empty folder") : (.ok, output.path)
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
    guard size > 0 else { return (.empty, "\(output.lastPathComponent) is 0 bytes") }

    guard let type = UTType(filenameExtension: output.pathExtension) else { return (.ok, output.path) }
    if type.conforms(to: .pdf) {
      return (PDFDocument(url: output)?.pageCount ?? 0) > 0
        ? (.ok, output.path) : (.unreadable, "\(output.lastPathComponent): no pages")
    }
    if type.conforms(to: .image) {
      guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
        // A format written through a tool that ImageIO cannot read back is
        // judged by the tool's own word, not called broken here.
        return FormatCatalog.readableImageTypes.contains(type)
          ? (.unreadable, "\(output.lastPathComponent): does not decode") : (.ok, output.path)
      }
      return (.ok, output.path)
    }
    if type.conforms(to: .text) {
      let text = (try? String(contentsOf: output, encoding: .utf8)) ?? "?"
      return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? (.empty, "\(output.lastPathComponent) holds only white space") : (.ok, output.path)
    }
    if FormatCatalog.writableAudioTypes.keys.contains(type), let file = try? AVAudioFile(forReading: output) {
      return file.length > 0 ? (.ok, output.path) : (.empty, "\(output.lastPathComponent): no sound in it")
    }
    return (.ok, output.path)
  }

  private func attempt(
    _ file: ProcessableFile, with preset: RulePreset, called label: String, into root: URL,
    on coordinator: ProcessingCoordinator
  ) async -> Attempt {
    let kind = ConvertKind(fileType: file.fileType)?.rawValue ?? "unknown"
    let name = file.url.lastPathComponent
    let destination = root.appendingPathComponent(UUID().uuidString.prefix(8).description)
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let start = Date()

    func made(_ outcome: Outcome, _ detail: String) -> Attempt {
      Attempt(input: name, kind: kind, output: label, outcome: outcome,
              seconds: Date().timeIntervalSince(start), detail: detail)
    }
    func strays() -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    do {
      let entry = try await race(seconds: 180) {
        try await coordinator.processFile(
          file, with: preset, destinationMode: .copyTo, destinationURL: destination
        ) { _ in }
      }
      guard entry.status == .completed else {
        let reason = entry.errorMessage ?? ""
        if reason.hasPrefix("Forge cannot convert") { return made(.offeredAndTurnedDown, reason) }
        if !strays().isEmpty { return made(.leftover, "\(strays()) after: \(reason)") }
        return made(reason.isEmpty ? .empty : .refused, reason.isEmpty ? "failed without a reason" : reason)
      }
      if !strays().isEmpty { return made(.leftover, "\(strays())") }
      guard !entry.outputs.isEmpty else { return made(.empty, "converted, and named no file") }
      for output in entry.outputs {
        let (outcome, detail) = verdict(on: output)
        if outcome != .ok { return made(outcome, detail) }
      }
      return made(.ok, entry.outputs.map(\.path).joined(separator: " "))
    } catch is TimedOut {
      return made(.timedOut, "no answer in 180 seconds")
    } catch ProcessingError.unsupportedConversion(let from, let to) {
      return made(.offeredAndTurnedDown, "\(from.identifier) to \(to.identifier)")
    } catch {
      if !strays().isEmpty { return made(.leftover, "\(strays()) after: \(error.localizedDescription)") }
      let reason = error.localizedDescription
      return made(reason.isEmpty ? .empty : .refused, reason.isEmpty ? "failed without a reason" : reason)
    }
  }

  private typealias Job = (file: ProcessableFile, preset: RulePreset, label: String)

  /// Run every job, a few at a time, and say which ones broke the rule.
  private func run(_ jobs: [Job], reportNamed name: String) async throws {
    let report = Report(named: name)
    let coordinator = coordinator()
    let kept = ProcessInfo.processInfo.environment["FORGE_CONFORMANCE_OUTPUT"]
    let root = try kept.map { URL(fileURLWithPath: $0).appendingPathComponent(name) } ?? folder("conformance-\(name)")
    let atOnce = 4

    await withTaskGroup(of: Void.self) { group in
      var next = 0
      func launch() {
        guard next < jobs.count else { return }
        let job = jobs[next]
        next += 1
        group.addTask {
          report.add(await self.attempt(job.file, with: job.preset, called: job.label, into: root, on: coordinator))
        }
      }
      for _ in 0..<atOnce { launch() }
      while await group.next() != nil { launch() }
    }

    let attempts = report.all
    let broken = attempts.filter { !$0.outcome.isHonest }
    let counts = Dictionary(grouping: attempts, by: \.outcome.rawValue).mapValues(\.count)
    print("conformance \(name): \(attempts.count) attempts \(counts.sorted { $0.key < $1.key })")
    XCTAssertTrue(
      broken.isEmpty,
      "\(broken.count) of \(attempts.count) broke the rule:\n" + broken.map(\.line).joined(separator: "\n")
    )
  }

  // MARK: - The tests

  /// Every file, into every format Forge offers for its kind.
  func test_everyOfferedConversionLeavesAFileThatOpensOrSaysWhy() async throws {
    var jobs: [Job] = []
    // Asked here, where waiting is allowed: the sheet only uses what pandoc
    // has already said, and in the app it has said it by the time one opens.
    _ = ExternalBridge.pandocFormats
    var unplaced: [String] = []
    for file in try fixtures() {
      // A file Forge opens but has no kind for is offered nothing at all.
      guard let kind = ConvertKind(fileType: file.fileType) else {
        unplaced.append(file.url.lastPathComponent)
        continue
      }
      let formats = Set(kind.outputGroups(for: [file]).flatMap(\.formats).compactMap(\.type))
      for format in formats.sorted(by: { $0.identifier < $1.identifier }) {
        jobs.append((file, .make(format: format, category: .custom), OutputFormat(type: format).label))
      }
    }
    print("conformance: offered nothing for \(unplaced.count) files: \(unplaced.joined(separator: " "))")
    try await run(jobs, reportNamed: "formats")
  }

  /// Every preset Forge ships, and any saved ones it is pointed at, on every
  /// file each one suits.
  func test_everyPresetLeavesAFileThatOpensOrSaysWhyOnEveryFileItSuits() async throws {
    let files = try fixtures()
    var presets = await AppModel.defaultPresets
    if let folder = ProcessInfo.processInfo.environment["FORGE_CONFORMANCE_PRESETS"] {
      let saved = try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil
      )
      let names = Set(presets.map(\.name))
      presets += saved
        .filter { $0.pathExtension == "json" }
        .compactMap { try? JSONDecoder().decode(RulePreset.self, from: Data(contentsOf: $0)) }
        .filter { !names.contains($0.name) }
    }

    var jobs: [Job] = []
    for preset in presets.sorted(by: { $0.name < $1.name }) {
      for file in files {
        guard let kind = ConvertKind(fileType: file.fileType), preset.suits([kind]), preset.suits([file]) else { continue }
        jobs.append((file, preset, preset.name))
      }
    }
    try await run(jobs, reportNamed: "presets")
  }
}
