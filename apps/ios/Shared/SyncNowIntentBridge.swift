import Foundation

/// Bridge between the cross-process `AppIntent` runtime and the main
/// `IOSAppModel` runtime.
///
/// The intent lives in `apps/ios/Shared/`, so it is compiled into both
/// the host app and the Control Center extension. Neither process can
/// reach the main app's `@MainActor` model directly, so we send a
/// system-wide Darwin notification and let the main app pick it up
/// whenever it is alive (foreground or briefly woken from the
/// background to service a Shortcuts / Control Center invocation).
///
/// Note: a Darwin notification does **not** relaunch a terminated
/// app. If the host app has been killed, the request is lost — the
/// user has to open the app at least once. That matches the "do not
/// open the app" UX the user asked for and avoids surprising launches.
public enum SyncNowIntentBridge {
    /// Raw string identifier. Cast to `CFString` for
    /// `CFNotificationCenterAddObserver` and to `CFNotificationName`
    /// for `CFNotificationCenterPostNotification` at each call site —
    /// Swift treats those as distinct nominal types even though they
    /// are the same underlying C type.
    public static var notificationID: String {
        "com.shuk.iphonesync.ios.intent.syncNow"
    }

    /// Local-process notification that `SyncNowIntentReceiver` posts
    /// after receiving the Darwin notification. `iPhoneSyncApp`
    /// observes this on the main actor and forwards to
    /// `IOSAppModel.handleIncomingURL`.
    public static let localNotification = Notification.Name(
        "com.shuk.iphonesync.ios.intent.syncNow.local"
    )
}