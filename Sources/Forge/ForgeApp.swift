import SwiftUI

struct ForgeApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 880, minHeight: 600)
    }
    .commands { SidebarCommands() }
  }
}
