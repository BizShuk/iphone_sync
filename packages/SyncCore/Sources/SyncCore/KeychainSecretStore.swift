import Foundation
import Security

public struct KeychainSecretStore: Sendable {
    public let service: String

    public init(service: String = "com.bizshuk.iphonesync") {
        self.service = service
    }

    public func save<Value: Encodable>(_ value: Value, account: String) throws {
        let encoded = try JSONEncoder().encode(value)
        try delete(account: account)

        var query = baseQuery(account: account)
        query[kSecValueData as String] = encoded
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.operationFailed(status)
        }
    }

    public func load<Value: Decodable>(
        _ type: Value.Type,
        account: String
    ) throws -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainSecretStoreError.operationFailed(status)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.operationFailed(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum KeychainSecretStoreError: Error, Equatable {
    case operationFailed(OSStatus)
}
