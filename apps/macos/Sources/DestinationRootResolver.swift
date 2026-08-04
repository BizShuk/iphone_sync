import Foundation

enum DestinationRootError: Error, Equatable, LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The selected destination must resolve to an existing folder."
        }
    }
}

struct DestinationRootResolver {
    static func resolve(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard url.isFileURL else {
            throw DestinationRootError.unavailable
        }

        let resolved = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: resolved.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw DestinationRootError.unavailable
        }
        return resolved
    }
}
