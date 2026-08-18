import Foundation
import Security

/// Minimal Keychain wrapper for the one thing that belongs there: the refresh token.
///
/// Rule 18 — no dependency for this. `Security` does the job in about sixty lines, and a
/// third-party keychain wrapper would be another package with access to the most sensitive
/// value the app holds.
nonisolated protocol SecureStore: Sendable {
    func save(_ data: Data, for key: String) throws(SecureStoreError)
    func read(_ key: String) -> Data?
    func delete(_ key: String) throws(SecureStoreError)
}

nonisolated enum SecureStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

nonisolated struct KeychainStore: SecureStore {
    private let service: String

    /// Scoped to the bundle identifier so the dev, staging and production builds cannot
    /// read each other's sessions — they are different accounts on different backends.
    init(service: String = Bundle.main.bundleIdentifier ?? "com.mymiracles.MyMiracles") {
        self.service = service
    }

    func save(_ data: Data, for key: String) throws(SecureStoreError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The session should not be readable while the device is locked, and should not
            // travel to a restored backup on another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw .unexpectedStatus(updateStatus)
        }

        let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw .unexpectedStatus(addStatus)
        }
    }

    func read(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    func delete(_ key: String) throws(SecureStoreError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .unexpectedStatus(status)
        }
    }
}

/// In-memory double for tests and previews.
nonisolated final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    init() {}

    func save(_ data: Data, for key: String) throws(SecureStoreError) {
        lock.withLock { storage[key] = data }
    }

    func read(_ key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    func delete(_ key: String) throws(SecureStoreError) {
        lock.withLock { _ = storage.removeValue(forKey: key) }
    }
}
