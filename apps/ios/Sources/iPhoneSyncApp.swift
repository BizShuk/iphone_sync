import SwiftUI

@main
@MainActor
struct iPhoneSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: IOSAppModel

    init() {
        let model = IOSAppModel()
        model.registerAutomaticSyncScheduler()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        model.enteredForeground()
                    case .background:
                        model.enteredBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
