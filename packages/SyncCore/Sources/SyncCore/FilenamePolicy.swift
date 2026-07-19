import Foundation

public enum FilenamePolicyError: Error, Equatable {
    case invalidFilename
    case invalidResourceID
    case invalidRole
}

public enum FilenamePolicy {
    public static func relativePath(
        originalFilename: String,
        resourceID: String,
        role: String?,
        creationDate: Date?,
        resourceIDPrefixLength: Int = 8
    ) throws -> String {
        try validate(filename: originalFilename)
        try validate(resourceID: resourceID)
        guard (8...resourceID.count).contains(resourceIDPrefixLength) else {
            throw FilenamePolicyError.invalidResourceID
        }

        let filename = originalFilename as NSString
        let stem = filename.deletingPathExtension
        let fileExtension = filename.pathExtension
        guard !stem.isEmpty, stem != ".", stem != "..", !stem.hasPrefix(".") else {
            throw FilenamePolicyError.invalidFilename
        }

        let roleSuffix: String
        if let role, !role.isEmpty {
            guard role.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }) else {
                throw FilenamePolicyError.invalidRole
            }
            roleSuffix = "_\(role)"
        } else {
            roleSuffix = ""
        }

        let dateComponents: (year: String, month: String)
        if let creationDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = calendar.dateComponents([.year, .month], from: creationDate)
            guard let year = components.year, let month = components.month else {
                throw FilenamePolicyError.invalidFilename
            }
            dateComponents = (String(format: "%04d", year), String(format: "%02d", month))
        } else {
            dateComponents = ("Unknown", "00")
        }

        let suffix = "__\(resourceID.prefix(resourceIDPrefixLength))\(roleSuffix)"
        let outputName = fileExtension.isEmpty
            ? "\(stem)\(suffix)"
            : "\(stem)\(suffix).\(fileExtension)"
        return "\(dateComponents.year)/\(dateComponents.month)/\(outputName)"
    }

    private static func validate(filename: String) throws {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.hasPrefix("."),
              !filename.contains("/"),
              !filename.contains("\\"),
              filename.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw FilenamePolicyError.invalidFilename
        }
    }

    private static func validate(resourceID: String) throws {
        guard resourceID.count == 64,
              resourceID.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
              })
        else {
            throw FilenamePolicyError.invalidResourceID
        }
    }
}
