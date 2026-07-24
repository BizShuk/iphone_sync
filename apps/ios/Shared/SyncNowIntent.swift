import AppIntents
import Foundation

/// Shared `AppIntent` that surfaces `Sync Now` in both the Shortcuts app
/// (via `SyncNowShortcuts` in the main app) and Control Center (via
/// `iPhoneSyncControlCenter`).
///
/// `openAppWhenRun` is **false** so the intent does not bring the
/// host app to the foreground. Instead `perform` posts a
/// system-wide Darwin notification; the host app's
/// `SyncNowIntentReceiver` (registered once at launch) forwards it to
/// `IOSAppModel.handleIncomingURL` on the main actor, which in turn
/// calls the existing foreground `syncNow()` entry point.
///
/// We deliberately reuse the URL-scheme path on the main-app side so
/// the intent, the original deep link, and any future external
/// triggers all funnel through the same `handleIncomingURL` →
/// `syncNow()` path — there is no second invocation surface to keep
/// in sync.
public struct SyncNowIntent: AppIntent {
    public static var title: LocalizedStringResource {
        "Sync Now"
    }
    public static var description: IntentDescription {
        IntentDescription("Trigger an immediate sync to your paired Mac.")
    }
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name: CFNotificationName = CFNotificationName(
            SyncNowIntentBridge.notificationID as CFString
        )
        CFNotificationCenterPostNotification(
            center,
            name,
            nil,
            nil,
            true
        )
        return .result()
    }
}
