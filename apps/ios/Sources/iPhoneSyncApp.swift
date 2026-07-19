import SwiftUI

@main
@MainActor
struct iPhoneSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = IOSAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        model.enteredBackground()
                    }
                }
        }
    }
}
