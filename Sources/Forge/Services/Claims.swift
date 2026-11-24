import Foundation

/// What is being written right now, kept where a Forge that was shut down in the
/// middle can be tidied up after: the empty file that holds a name, and the
/// hidden one behind it.
final class Claims: @unchecked Sendable {
  private let lock = NSLock()
  private let file: URL
  private var paths: Set<String> = []

  init(root: URL) {
    let folder = root.appendingPathComponent("Writing", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    file = folder.appendingPathComponent("\(getpid())-\(UUID().uuidString).json")
  }

  func add(_ url: URL) { change { $0.insert(url.path) } }
  func remove(_ url: URL) { change { $0.remove(url.path) } }

  private func change(_ work: (inout Set<String>) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    work(&paths)
    if paths.isEmpty {
      try? FileManager.default.removeItem(at: file)
    } else {
      try? JSONEncoder().encode(paths.sorted()).write(to: file, options: .atomic)
    }
  }

  /// Takes away what nobody is writing any more. Only what is certainly Forge's:
  /// hidden files it named, and files with nothing in them.
  @discardableResult
  static func sweep(root: URL) -> Int {
    let folder = root.appendingPathComponent("Writing", isDirectory: true)
    var swept = 0
    for note in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where note.pathExtension == "json" {
      guard let owner = note.lastPathComponent.split(separator: "-").first.flatMap({ pid_t($0) }), !isRunning(owner) else { continue }
      let left = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: note))) ?? []
      for path in left {
        let isScratch = (path as NSString).lastPathComponent.hasPrefix(".forge-")
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64
        if isScratch { swept += sweepBeside(path) }
        guard isScratch || size == 0 else { continue }
        if (try? FileManager.default.removeItem(atPath: path)) != nil { swept += 1 }
      }
      try? FileManager.default.removeItem(at: note)
    }
    return swept
  }

  /// What macOS keeps beside a file it is writing is named after it, and after
  /// nothing else: the name is one of Forge's own.
  private static func sweepBeside(_ path: String) -> Int {
    let folder = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
    let beside = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(name + ".") || $0.hasPrefix("." + name) }
    return beside.filter { (try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent($0))) != nil }.count
  }

  private static func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}
