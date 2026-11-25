import AppKit

extension AppSettings.WhenFinished {
  @MainActor
  func run(_ outputs: [URL]) {
    switch self {
    case .nothing: break
    case .show: if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    case .sleep:
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
      process.arguments = ["sleepnow"]
      try? process.run()
    case .quit: NSApp.terminate(nil)
    }
  }
}
