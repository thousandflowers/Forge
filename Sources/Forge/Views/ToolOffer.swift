import AppKit
import SwiftUI

/// The tools Forge can install, and which of them would help with what is in
/// front of the user. Asked where the need is - a file that would not open, a
/// Convert sheet with formats missing - rather than only on a screen of its own.
enum ToolOffers {
  /// Every tool Forge calls and can fetch, as Capabilities lists them.
  static var all: [ExternalTool] {
    Capabilities.all.compactMap { capability in
      guard case .needsPack(let pack) = capability.status, pack.isWired else { return nil }
      return pack.tool
    }
  }

  /// The tools not installed here that give these kinds of file more formats.
  static func missing(for kinds: Set<ConvertKind>) -> [ExternalTool] {
    all.filter { !$0.isInstalled && !$0.serves.isDisjoint(with: kinds) }
  }

  /// The tool that would open a file Forge cannot, if there is one and it is
  /// not here: the capability whose files look like this one.
  static func opener(for url: URL) -> ExternalTool? {
    let ext = url.pathExtension.lowercased()
    guard !ext.isEmpty else { return nil }
    for capability in Capabilities.all where capability.evidence.contains(ext) {
      if case .needsPack(let pack) = capability.status, pack.isWired, let tool = pack.tool, !tool.isInstalled {
        return tool
      }
    }
    return nil
  }
}

/// Fetches a tool and follows it to the end. One for the whole app, so a
/// download started in the Convert sheet is still visible, and still running,
/// in Capabilities - and the other way round.
@MainActor
final class ToolInstaller: ObservableObject {
  static let shared = ToolInstaller()

  enum State: Equatable {
    case idle
    /// How much of it is in; nil while it is unpacked and tried.
    case running(Double?)
    case failed(String)
    case installed
  }

  @Published private(set) var states: [String: State] = [:]
  /// The tool whose download is waiting for the user to say yes.
  @Published var confirming: ExternalTool?

  /// What to do once each tool is in: files that were turned away are tried again.
  private var afterwards: [String: () -> Void] = [:]
  private var fetching: [String: Task<Void, Never>] = [:]

  func state(of binary: String) -> State { states[binary] ?? .idle }

  func ask(_ tool: ExternalTool, then: (() -> Void)? = nil) {
    if let then { afterwards[tool.binary] = then }
    confirming = tool
  }

  func install(_ tool: ExternalTool) {
    confirming = nil
    guard let release = tool.release, fetching[tool.binary] == nil else { return }
    states[tool.binary] = .running(0)

    fetching[tool.binary] = Task { [weak self] in
      // Bound once, strongly: a weak capture is a mutable reference, and one
      // cannot be read again from inside the progress closure's own task.
      guard let self else { return }
      do {
        try await Toolbox.shared.fetch(tool.name, release) { [self] share in
          Task { @MainActor in
            // A step that arrives after the end is not a step back.
            if case .running = self.states[tool.binary] { self.states[tool.binary] = .running(share) }
          }
        }
        self.states[tool.binary] = .installed
        self.afterwards.removeValue(forKey: tool.binary)?()
      } catch {
        // Stopped on purpose, under whichever name it comes back.
        let stopped = error is CancellationError || (error as? URLError)?.code == .cancelled
        self.states[tool.binary] = stopped ? .idle : .failed(error.localizedDescription)
      }
      self.fetching[tool.binary] = nil
    }
  }

  func stop(_ tool: ExternalTool) { fetching[tool.binary]?.cancel() }

  func remove(_ tool: ExternalTool) {
    do {
      try Toolbox.shared.remove(tool.name)
      states[tool.binary] = .idle
    } catch {
      states[tool.binary] = .failed(error.localizedDescription)
    }
  }
}

extension View {
  /// The question asked before anything is fetched: what, from where, how much.
  func confirmsToolInstalls(with installer: ToolInstaller) -> some View {
    confirmationDialog(
      installer.confirming.map { "Download \($0.name)?" } ?? "",
      isPresented: Binding(
        get: { installer.confirming != nil },
        set: { if !$0 { installer.confirming = nil } }
      )
    ) {
      if let tool = installer.confirming {
        Button("Download") { installer.install(tool) }
        Button("Cancel", role: .cancel) { installer.confirming = nil }
      }
    } message: {
      if let tool = installer.confirming, let release = tool.release {
        Text("\(tool.name) \(release.version), \(tool.weight), from \(release.build.url.host ?? ""). License: \(release.licence). Forge verifies the download and keeps it in its own folder.")
      }
    }
  }
}

/// A download on its way, and the button that stops it.
struct ToolProgress: View {
  let tool: ExternalTool
  let share: Double?

  var body: some View {
    HStack(spacing: 8) {
      if let share {
        ProgressView(value: share).frame(maxWidth: 140)
        Text("\(Int(share * 100))% of \(tool.weight)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        Button("Stop") { ToolInstaller.shared.stop(tool) }.controlSize(.small)
      } else {
        ProgressView().controlSize(.small)
        Text("Unpacking…").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

/// One line about a tool that is not here: what it would add, and the button
/// that fetches it.
struct ToolOfferRow: View {
  let tool: ExternalTool
  /// The sentence before the button: what the tool would do here.
  let because: String
  @ObservedObject var installer: ToolInstaller
  var then: (() -> Void)? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "shippingbox").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text(because).font(.callout)
        status
      }
      Spacer(minLength: 8)
      action
    }
  }

  @ViewBuilder
  private var status: some View {
    switch installer.state(of: tool.binary) {
    case .running(let share): ToolProgress(tool: tool, share: share)
    case .failed(let reason): Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
    case .installed: Text("Ready.").font(.caption).foregroundStyle(Color.lighter)
    case .idle: EmptyView()
    }
  }

  @ViewBuilder
  private var action: some View {
    switch installer.state(of: tool.binary) {
    case .running, .installed:
      EmptyView()
    case .failed:
      Button("Try Again") { installer.ask(tool, then: then) }.controlSize(.small)
    case .idle:
      Button("Download, \(tool.weight)…") { installer.ask(tool, then: then) }.controlSize(.small)
    }
  }
}
