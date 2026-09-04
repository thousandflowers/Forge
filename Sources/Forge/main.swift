import Foundation

// One binary, two front ends. `main.swift` exists so the choice happens before
// anything AppKit-related is touched: importing SwiftUI is fine, but starting
// the app is not something a command-line run should ever do.
if LaunchMode.isCommandLine() {
  await CLI.run(LaunchMode.userArguments())
} else {
  ForgeApp.main()
}
