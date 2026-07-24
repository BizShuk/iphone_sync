/// How received resources are arranged inside the chosen destination.
///
/// All layouts keep the fixed `iPhoneSync` container that lives directly under
/// the user-selected destination root. The cases below describe what appears
/// inside that container.
public enum DestinationStorageMode: String, Codable, Equatable, Sendable {
    /// `<destination>/iPhoneSync/<album>/<year>/<month>/<file>`
    case albumDate
    /// `<destination>/iPhoneSync/<album>/<file>`
    case albumOnly
    /// `<destination>/iPhoneSync/<file>`
    case flat
}
