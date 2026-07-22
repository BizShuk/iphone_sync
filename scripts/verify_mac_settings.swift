import Foundation

@main
enum VerifyMacSettings {
    static func main() {
        let suiteName = "com.shuk.iphonesync.settings-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = MacSettingsStore(defaults: defaults)
        let receiverID = first.receiverID()
        let sourceBindingID = first.sourceBindingID()
        precondition(!receiverID.isEmpty)
        precondition(!sourceBindingID.isEmpty)
        precondition(first.launchAtLoginRequested)

        let bookmark = Data([0x01, 0x02, 0x03])
        first.destinationBookmark = bookmark
        first.launchAtLoginRequested = false

        let relaunched = MacSettingsStore(defaults: defaults)
        precondition(relaunched.receiverID() == receiverID)
        precondition(relaunched.sourceBindingID() == sourceBindingID)
        precondition(relaunched.destinationBookmark == bookmark)
        precondition(!relaunched.launchAtLoginRequested)

        let resetBindingID = relaunched.resetSourceBindingID()
        precondition(resetBindingID != sourceBindingID)
        precondition(MacSettingsStore(defaults: defaults).sourceBindingID() == resetBindingID)

        relaunched.destinationBookmark = nil
        precondition(MacSettingsStore(defaults: defaults).destinationBookmark == nil)
    }
}
