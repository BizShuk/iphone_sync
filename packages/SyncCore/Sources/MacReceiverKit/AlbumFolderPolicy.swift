import Foundation

public enum AlbumFolderPolicy {
    public static let fallbackName = "Untitled Album"

    public static func folderName(for albumName: String) -> String {
        guard !albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallbackName
        }

        var folderName = albumName.unicodeScalars.map { scalar in
            if scalar == "/"
                || scalar == "\\"
                || CharacterSet.controlCharacters.contains(scalar) {
                return "_"
            }
            return String(scalar)
        }.joined()

        if folderName == "." || folderName == ".." || folderName.hasPrefix(".") {
            folderName.insert("_", at: folderName.startIndex)
        }
        return folderName
    }
}
