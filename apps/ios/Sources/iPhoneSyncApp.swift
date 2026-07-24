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
        // Register the cross-process receiver so a Shortcuts / Control
        // Center tap can request `syncNow()` without bringing the app
        // to the foreground. The intent (in another process) posts a
        // Darwin notification; we re-broadcast it locally and handle
        // it in `.onReceive` below on the main actor.
        SyncNowIntentReceiver.shared.start()
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
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: SyncNowIntentBridge.localNotification
                    )
                ) { _ in
                    // Funnel the background intent trigger through the
                    // same entry point as the URL scheme, so operation
                    // log entries and prerequisite guards stay aligned.
                    if let url = URL(string: "iphonesync://sync-now") {
                        model.handleIncomingURL(url)
                    }
                }
        }
    }
}
