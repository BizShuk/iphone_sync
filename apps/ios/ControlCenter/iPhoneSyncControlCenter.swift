import SwiftUI
import WidgetKit

/// Control Center entry for `Sync Now`.
///
/// Tapping the button forwards the `SyncNowIntent` defined in
/// `apps/ios/Shared/`, which opens the host app via the
/// `iphonesync://sync-now` URL scheme. `IOSAppModel.handleIncomingURL`
/// then starts the foreground sync runtime. We deliberately do not
/// attempt to run the sync inside the widget process — PhotoKit and
/// the paired Bonjour receiver both live in the host app.
///
/// `WidgetBundle` (not a Control Center–specific bundle protocol) is
/// the right container; it accepts a mix of `Widget` and
/// `ControlWidget` children.
struct SyncNowControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "iPhoneSync.SyncNowControl") {
            ControlWidgetButton(action: SyncNowIntent()) {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .displayName("Sync Now")
        .description("Trigger an immediate sync to your paired Mac.")
    }
}

@main
struct iPhoneSyncControlBundle: WidgetBundle {
    var body: some Widget {
        SyncNowControl()
    }
}