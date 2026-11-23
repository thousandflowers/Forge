import AppKit
import SwiftUI

/// The tools Forge can install, and which of them would help with what is in
/// front of the user. Asked where the need is - a file that would not open, a
/// Convert sheet with formats missing - rather than only on a screen of its own.
enum ToolOffers {
  /// Every tool Forge calls and can install, as Capabilities lists them.
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

/// Installs a tool with Homebrew and follows it to the end. One for the whole
/// app, so an install started in the Convert sheet is still visible, and still
/// running, in Capabilities - and the other way round.
@MainActor
final class ToolInstaller: ObservableObject {
  static let shared = ToolInstaller()

  enum State: Equatable {
    case idle
    /// The last line Homebrew printed, shown so it is plainly doing something.
    case running(String)
    case failed(String)
    case installed
  }

  @Published private(set) var states: [String: State] = [:]
  /// The tool whose install is waiting for the user to say yes.
  @Published var confirming: ExternalTool?

  /// What to do once each tool is in: files that were turned away are tried again.
  private var afterwards: [String: () -> Void] = [:]

  func state(of binary: String) -> State { states[binary] ?? .idle }

  func ask(_ tool: ExternalTool, then: (() -> Void)? = nil) {
    if let then { afterwards[tool.binary] = then }
    confirming = tool
  }

  func install(_ tool: ExternalTool) {
    confirming = nil
    states[tool.binary] = .running("")

    Task { [weak self] in
      // Bound once, strongly: a weak capture is a mutable reference, and one
      // cannot be read again from inside the progress closure's own task.
      guard let self else { return }
      do {
        try await ExternalTools.install(tool) { [self] line in
          Task { @MainActor in
            self.states[tool.binary] = .running(line)
          }
        }
        self.states[tool.binary] = .installed
        self.afterwards.removeValue(forKey: tool.binary)?()
      } catch {
        self.states[tool.binary] = .failed(error.localizedDescription)
      }
    }
  }
}

extension View {
  /// The question asked before anything is installed: the exact command, once.
  func confirmsToolInstalls(with installer: ToolInstaller) -> some View {
    confirmationDialog(
      installer.confirming.map { "Install \($0.formula)?" } ?? "",
      isPresented: Binding(
        get: { installer.confirming != nil },
        set: { if !$0 { installer.confirming = nil } }
      )
    ) {
      if let tool = installer.confirming {
        Button("Install") { installer.install(tool) }
        Button("Cancel", role: .cancel) { installer.confirming = nil }
      }
    } message: {
      if let tool = installer.confirming {
        Text("Forge will run “\(tool.installCommand)”. Homebrew installs it on your Mac; Forge neither ships nor hosts it.")
      }
    }
  }
}

/// One line about a tool that is not here: what it would add, and a button
/// that installs it - or, without Homebrew, where to get that first.
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
    case .running(let line):
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(line.isEmpty ? "Installing \(tool.formula)…" : line)
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
    case .failed(let reason):
      Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
    case .installed:
      Text("Installed.").font(.caption).foregroundStyle(.green)
    case .idle:
      if !ExternalTools.hasHomebrew {
        Text("Forge installs it with Homebrew, which is not on this Mac. Installing Homebrew asks for your password, so it is a step for you: brew.sh has the one line.")
          .font(.caption).foregroundStyle(.secondary)
      }
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
      if ExternalTools.hasHomebrew {
        Button("Install \(tool.formula)…") { installer.ask(tool, then: then) }.controlSize(.small)
      } else {
        Link("brew.sh", destination: URL(string: "https://brew.sh")!).controlSize(.small)
      }
    }
  }
}
