import Foundation
import Security

/// Keychain-backed credential storage using the shared access group
/// so both the app and File Provider extension can access credentials.
public final class KeychainService: CredentialProvider, @unchecked Sendable {

    private let service = "com.lollipopkit.mfuse.credentials"
    private let accessGroup: String?

    public init(accessGroup: String? = AppGroupConstants.keychainAccessGroup) {
        self.accessGroup = accessGroup
    }

    // MARK: - CredentialProvider

    public func credential(for connectionID: UUID) async throws -> Credential? {
        guard let data = try readKeychainData(account: connectionID.uuidString) else {
            return nil
        }
        return try JSONDecoder().decode(StoredCredential.self, from: data).toCredential()
    }

    public func store(_ credential: Credential, for connectionID: UUID) async throws {
        let stored = StoredCredential(from: credential)
        let data = try JSONEncoder().encode(stored)
        try writeKeychainData(data, account: connectionID.uuidString)
    }

    public func delete(for connectionID: UUID) async throws {
        try deleteKeychainData(account: connectionID.uuidString)
    }

    // MARK: - Raw Keychain Operations

    private func readKeychainData(account: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        return result as? Data
    }

    private func writeKeychainData(_ data: Data, account: String) throws {
        // Try update first
        var searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let group = accessGroup {
            searchQuery[kSecAttrAccessGroup as String] = group
        }

        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Create new item
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw keychainError(updateStatus)
        }
    }

    private func deleteKeychainData(account: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func keychainError(_ status: OSStatus) -> Error {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error (\(status))"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - Codable wrapper for Keychain storage

private struct StoredCredential: Codable {
    var password: String?
    var privateKey: Data?
    var passphrase: String?
    var accessKeyID: String?
    var secretAccessKey: String?
    var token: String?

    init(from credential: Credential) {
        self.password = credential.password
        self.privateKey = credential.privateKey
        self.passphrase = credential.passphrase
        self.accessKeyID = credential.accessKeyID
        self.secretAccessKey = credential.secretAccessKey
        self.token = credential.token
    }

    func toCredential() -> Credential {
        Credential(
            password: password,
            privateKey: privateKey,
            passphrase: passphrase,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            token: token
        )
    }
}
