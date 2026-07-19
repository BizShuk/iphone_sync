import CryptoKit
import Foundation

public enum ResourceIdentity {
    public static func make(
        sourceBindingID: String,
        descriptor: ResourceDescriptor
    ) -> String {
        let fields = [
            sourceBindingID,
            descriptor.assetLocalIdentifier,
            descriptor.resourceType,
            descriptor.originalFilename,
            String(descriptor.duplicateOrdinal),
        ]

        var canonical = Data()
        for (index, field) in fields.enumerated() {
            if index > 0 {
                canonical.append(0)
            }
            canonical.append(contentsOf: field.utf8)
        }

        return SHA256.hash(data: canonical).hexString
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
