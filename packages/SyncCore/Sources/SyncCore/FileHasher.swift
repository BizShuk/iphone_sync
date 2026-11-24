import CryptoKit
import Foundation

public enum FileHasher {
    public static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        // Each read returns a bridged buffer that is only freed when an
        // autorelease pool drains; without a per-chunk pool a multi-GB video
        // accumulates every chunk and iOS jetsams the app.
        while try autoreleasepool(invoking: {
            let data = try handle.read(upToCount: SyncConstants.chunkSize) ?? Data()
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().hexString
    }
}
