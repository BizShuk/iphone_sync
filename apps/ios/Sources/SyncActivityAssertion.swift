import UIKit

/// Keeps a foreground sync run alive against the two ways iOS ends it early.
///
/// 1. Auto-lock turns the screen off while a long transfer is still running.
///    The run is cancelled as a `sceneBackgrounded` run and the user sees the
///    transfer simply stop.
/// 2. Leaving the foreground suspends the process almost immediately, so the
///    cancellation never reaches the TLS connection. The socket stays half
///    open and the receiver keeps waiting on a sender that will never speak
///    again.
///
/// The idle-timer hold removes cause 1 for as long as a run is active; the
/// background task assertion buys enough execution time to close the session
/// cleanly for cause 2.
@MainActor
final class SyncActivityAssertion {
    private let application: UIApplication
    private var isHoldingIdleTimer = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(application: UIApplication = .shared) {
        self.application = application
    }

    /// Called when a foreground run starts.
    func beginRun() {
        guard !isHoldingIdleTimer else { return }
        isHoldingIdleTimer = true
        application.isIdleTimerDisabled = true
    }

    /// Called when the run finishes, whatever its outcome.
    func endRun() {
        if isHoldingIdleTimer {
            isHoldingIdleTimer = false
            application.isIdleTimerDisabled = false
        }
        endBackgroundTask()
    }

    /// Called when the scene backgrounds — the user pressed the side button,
    /// switched apps, or auto-lock fired anyway — while a run is active.
    func beginBackgroundGracePeriod() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = application.beginBackgroundTask(
            withName: "com.shuk.iphonesync.sync-teardown"
        ) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        let taskID = backgroundTaskID
        backgroundTaskID = .invalid
        application.endBackgroundTask(taskID)
    }
}
