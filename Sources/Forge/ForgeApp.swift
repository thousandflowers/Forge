import SwiftUI

struct ForgeApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    Window("Forge", id: MenuBarView.windowID) {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 880, minHeight: 600)
    }
    .commands { SidebarCommands() }

    // A conversion is usually a small errand, and going to the window for it
    // is more ceremony than the errand deserves.
    MenuBarExtra("Forge", systemImage: "hammer") {
      MenuBarView()
        .environmentObject(model)
    }
  }
}
