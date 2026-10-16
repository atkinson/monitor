//
// MonitorApp — menu-bar extra (accessory app: no Dock icon) for DDC/CI
// display control. The panel opens anchored under the menu bar icon.
// Protocol logic lives in the shared Sources/ core.
//

import SwiftUI

@main
struct MonitorAppApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Monitor", systemImage: "display") {
            ContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
