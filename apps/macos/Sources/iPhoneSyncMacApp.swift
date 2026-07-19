import SwiftUI

@main
@MainActor
struct iPhoneSyncMacApp: App {
    @State private var model = MacAppModel()

    var body: some Scene {
        MenuBarExtra("iPhone Sync", systemImage: model.statusSymbol) {
            MenuContentView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("iPhone Sync Setup", id: "setup") {
            SetupView(model: model)
        }
        .defaultSize(width: 620, height: 520)
    }
}
