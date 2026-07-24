import AppIntents

/// Surfaces `SyncNowIntent` to the system Shortcuts app and to Siri
/// without requiring the user to author a shortcut manually.
///
/// iOS reads the catalogue at app launch and renders the entries inside
/// the Shortcuts gallery, the Shortcuts editor, and the system "Add to
/// Siri" sheet.
public struct SyncNowShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: [
                "Sync now in \(.applicationName)",
                "Trigger sync now with \(.applicationName)",
            ],
            shortTitle: "Sync Now",
            systemImageName: "arrow.triangle.2.circlepath.circle.fill"
        )
    }
}