import Foundation
import UserNotifications

/// Best-effort local notification telling the user that a background sync left
/// fully backed-up photos queued for the foreground deletion confirmation.
///
/// PhotoKit cannot present its system confirmation from a task iOS launched in
/// the background, so a scheduled run can only enqueue candidates. Without this
/// prompt that queue is invisible until the user happens to reopen the app.
struct PendingDeletionNotifier: Sendable {
    var requestAuthorization: @Sendable () async -> Void
    var notifyPending: @Sendable (Int) async -> Void
    var clearPending: @Sendable () async -> Void

    static let disabled = PendingDeletionNotifier(
        requestAuthorization: {},
        notifyPending: { _ in },
        clearPending: {}
    )
}

extension PendingDeletionNotifier {
    static let requestIdentifier = "deleteAfterSync.pendingConfirmation"

    static func userNotifications() -> PendingDeletionNotifier {
        PendingDeletionNotifier(
            requestAuthorization: {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            },
            notifyPending: { pendingCount in
                guard pendingCount > 0 else { return }
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                    return
                }
                center.removeDeliveredNotifications(
                    withIdentifiers: [requestIdentifier]
                )
                let content = UNMutableNotificationContent()
                content.title = "Photos waiting for deletion"
                content.body = "\(pendingCount) fully backed-up "
                    + (pendingCount == 1 ? "photo is" : "photos are")
                    + " ready to delete. Open the app to confirm."
                content.sound = .default
                try? await center.add(UNNotificationRequest(
                    identifier: requestIdentifier,
                    content: content,
                    trigger: nil
                ))
            },
            clearPending: {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(
                    withIdentifiers: [requestIdentifier]
                )
                center.removeDeliveredNotifications(
                    withIdentifiers: [requestIdentifier]
                )
            }
        )
    }
}
