import Foundation
import os.log

/// Listens for the cross-process Darwin notification posted by
/// `SyncNowIntent` and re-broadcasts it on the local
/// `NotificationCenter` so the SwiftUI layer can react on the main
/// actor.
///
/// Registered exactly once from `iPhoneSyncApp.init`. The
/// `CFNotificationCenter` callback is C-function-shaped and runs on
/// an arbitrary thread, so we only post a thread-safe local
/// notification here and let `iPhoneSyncApp` forward to
/// `IOSAppModel.handleIncomingURL` on `MainActor`.
///
/// `@unchecked Sendable` is justified: the only mutable state is
/// `started`, guarded by `lock`. Everything else (`handler`) is set
/// once and never reassigned.
final class SyncNowIntentReceiver: @unchecked Sendable {
    static let shared = SyncNowIntentReceiver()

    private let logger = Logger(
        subsystem: "com.shuk.iphonesync.ios",
        category: "sync-intent"
    )
    private var started = false
    private let lock = NSLock()

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            Self.callback,
            SyncNowIntentBridge.notificationID as CFString,
            nil,
            .deliverImmediately
        )
    }

    private static let callback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let receiver = Unmanaged<SyncNowIntentReceiver>
            .fromOpaque(observer)
            .takeUnretainedValue()
        receiver.logger.debug("Received Sync Now Darwin notification")
        NotificationCenter.default.post(
            name: SyncNowIntentBridge.localNotification,
            object: nil
        )
    }
}