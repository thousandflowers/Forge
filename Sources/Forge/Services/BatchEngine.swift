import Foundation
import UniformTypeIdentifiers

/// Decides how much runs at once, and backs off when the Mac says it is
/// struggling.
///
/// One number for the whole app was wrong in both directions: two videos at
/// once is one too many, because the media engine is a single piece of hardware
/// and asking it for two only makes heat; two images at once is far too few on
/// a machine with ten cores. So the limit is per kind of work, computed from
/// what the machine actually is.
///
/// Nothing here decides which chip does the work. Core Image goes to the GPU,
/// Vision to the neural engine, VideoToolbox to the media engine, and Apple
/// routes all of that without being asked. What this controls is how many
/// things are asked for at once, and what happens when the answer should be
/// fewer.
actor BatchEngine {
  static let shared = BatchEngine()

  /// The kinds of work, which is to say the pieces of hardware they contend
  /// for.
  enum Workload: String, CaseIterable, Sendable {
    /// Core Image and ImageIO: the GPU, and a lot of memory per decode.
    case image
    /// VideoToolbox through AVFoundation: one media engine, shared.
    case video
    /// Audio conversion, which is cheap and mostly waiting.
    case audio
    /// Vision, on the neural engine.
    case text
    /// A tool Forge fetched, in a process of its own.
    case subprocess

    /// What a file of this kind converts through.
    static func of(_ file: ProcessableFile, writing target: UTType?) -> Workload {
      let kind = ConvertKind(fileType: file.fileType)
      if kind == nil, ExternalBridge.canHandle(file.fileType) { return .subprocess }
      if let target, target.conforms(to: .plainText) { return .text }
      switch kind {
      case .video: return .video
      case .audio: return .audio
      case .image, .document, .data, .model, .subtitle, .font, nil: return .image
      }
    }
  }

  /// What the Mac is, as the numbers that matter here.
  struct Capability: Sendable, Equatable {
    let cores: Int
    let memoryGB: Double
    /// Apple silicon shares memory between the processor and the graphics, and
    /// has a media engine of its own, so it takes more at once than an Intel
    /// Mac with the same core count.
    let isAppleSilicon: Bool

    static var current: Capability {
      #if arch(arm64)
      let appleSilicon = true
      #else
      // `uname` would answer for the process, which under Rosetta is not the
      // same question.
      let appleSilicon = false
      #endif
      return Capability(
        cores: ProcessInfo.processInfo.activeProcessorCount,
        memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
        isAppleSilicon: appleSilicon
      )
    }

    /// How many of this kind of work this machine should be asked for at once.
    ///
    /// Images are bounded by memory rather than by cores: a decoded sixty
    /// megapixel photograph is a quarter of a gigabyte before anything has been
    /// done to it, and eight of those at once is how a batch takes a Mac down.
    func limit(for workload: Workload) -> Int {
      switch workload {
      case .video:
        // The media engine is one piece of hardware. Two gives it something to
        // start while the last frames of the other are written; more only
        // queues, and queues warm.
        return isAppleSilicon && cores >= 8 ? 2 : 1
      case .image:
        let byMemory = Int(memoryGB / 1.5)
        let byCores = max(1, cores - 2)
        return max(1, min(byMemory, byCores, 8))
      case .text:
        // The neural engine is shared, and Vision is already parallel inside.
        return max(1, min(cores / 4, 3))
      case .audio:
        return max(1, min(cores / 2, 4))
      case .subprocess:
        // A process of its own, using the cores Forge is not using.
        return max(1, min(cores - 1, 8))
      }
    }
  }

  /// Why the engine has backed off, if it has.
  enum Pressure: String, Sendable, Equatable {
    case none
    case thermal
    case memory
    case lowPower

    var reason: String {
      switch self {
      case .none: return ""
      case .thermal: return "Your Mac is warm, so Forge is converting fewer at once."
      case .memory: return "Memory is tight, so Forge is converting fewer at once."
      case .lowPower: return "Low Power Mode is on, so Forge is converting fewer at once."
      }
    }
  }

  private let capability: Capability
  private var pressure: Pressure = .none
  private var paused = false

  /// How many of each kind are running.
  private var running: [Workload: Int] = [:]
  /// The most the user is willing to have running, whatever the machine could
  /// manage.
  private var ceiling: Int?
  /// Everything waiting for a slot, oldest first, so a batch keeps its order.
  private var queue: [(workload: Workload, resume: CheckedContinuation<Void, Never>)] = []

  private var monitor: PressureMonitor?

  /// - Parameter watchesTheSystem: off under test, where the Mac's real
  ///   temperature has no business deciding whether an assertion holds.
  init(capability: Capability = .current, watchesTheSystem: Bool = true) {
    self.capability = capability
    guard watchesTheSystem else { return }
    Task { await self.start() }
  }

  // MARK: - What is allowed

  /// The number of this kind that may run at once, as things stand.
  func limit(for workload: Workload) -> Int {
    let base = min(capability.limit(for: workload), ceiling ?? .max)
    switch pressure {
    case .none:
      return base
    case .lowPower, .thermal:
      return max(1, base / 2)
    case .memory:
      // The one that ends in a Mac nobody can use.
      return 1
    }
  }

  var currentPressure: Pressure { pressure }
  var isPaused: Bool { paused }
  var isThrottled: Bool { pressure != .none }
  func running(_ workload: Workload) -> Int { running[workload, default: 0] }

  /// Wait until this kind of work may start.
  ///
  /// Waiters are let in in the order they arrived, so a batch converts in the
  /// order it was given rather than in whatever order the queue wakes up.
  /// - Parameter ceiling: what the user asked for in Settings, which can only
  ///   ever ask for less. The machine's own limit is not something a preference
  ///   should be able to raise past.
  func acquire(_ workload: Workload, ceiling: Int? = nil) async {
    self.ceiling = ceiling.map { max(1, $0) }
    if !paused, queue.isEmpty, running[workload, default: 0] < limit(for: workload) {
      running[workload, default: 0] += 1
      return
    }
    // The slot is taken by `admit` at the moment it resumes this, not here: a
    // waiter that counted itself in only once it woke up left a window where
    // two of them could be let in for the same slot.
    await withCheckedContinuation { continuation in
      queue.append((workload, continuation))
    }
  }

  func release(_ workload: Workload) {
    running[workload] = max(0, running[workload, default: 1] - 1)
    admit()
  }

  // MARK: - Pause

  /// Stop starting new work. What is already running finishes: a native encode
  /// cannot be frozen halfway, and a button claiming otherwise would be lying.
  func pause() { paused = true }

  func resume() {
    paused = false
    admit()
  }

  // MARK: - Pressure

  /// Told from outside, so a test can say "the Mac is hot now" without one
  /// being hot.
  func pressureChanged(to pressure: Pressure) {
    self.pressure = pressure
    // Coming back down frees slots that were being held closed.
    admit()
  }

  private func start() {
    monitor = PressureMonitor { [weak self] pressure in
      // Bound once, strongly: a weak capture is a mutable reference, and one
      // cannot be read again from inside the task this closure starts.
      guard let engine = self else { return }
      Task { await engine.pressureChanged(to: pressure) }
    }
  }

  // MARK: - Private

  /// Let in whoever may go now.
  private func admit() {
    guard !paused else { return }
    var stillWaiting: [(workload: Workload, resume: CheckedContinuation<Void, Never>)] = []

    for waiter in queue {
      if running[waiter.workload, default: 0] < limit(for: waiter.workload) {
        running[waiter.workload, default: 0] += 1
        waiter.resume.resume()
      } else {
        stillWaiting.append(waiter)
      }
    }
    queue = stillWaiting
  }
}

/// Watches the three things macOS will tell you about a Mac in trouble.
///
/// A class rather than part of the actor because the notifications and the
/// dispatch source arrive on their own terms; everything it learns is handed
/// straight over.
private final class PressureMonitor: @unchecked Sendable {
  private let report: @Sendable (BatchEngine.Pressure) -> Void
  private var memorySource: DispatchSourceMemoryPressure?
  private var observers: [NSObjectProtocol] = []

  init(report: @escaping @Sendable (BatchEngine.Pressure) -> Void) {
    self.report = report

    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: .global(qos: .utility)
    )
    source.setEventHandler { [weak self] in
      guard let self else { return }
      // Any event from this source is the system asking for less. What it looks
      // like once that has passed is whatever the rest of the Mac says.
      self.report(.memory)
    }
    source.resume()
    memorySource = source

    for name in [
      ProcessInfo.thermalStateDidChangeNotification,
      Notification.Name.NSProcessInfoPowerStateDidChange,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          guard let self else { return }
          self.report(Self.current())
        }
      )
    }

    report(Self.current())
  }

  deinit {
    memorySource?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  /// What the Mac says right now, worst thing first.
  static func current() -> BatchEngine.Pressure {
    let info = ProcessInfo.processInfo
    switch info.thermalState {
    case .serious, .critical: return .thermal
    default: break
    }
    return info.isLowPowerModeEnabled ? .lowPower : .none
  }
}
