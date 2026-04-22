import Foundation
import Security

public enum KeychainItemSyncMode: Sendable, Equatable {
    case local
    case synchronizable
}

/// Keychain-backed credential storage using the shared access group
/// so both the app and File Provider extension can access credentials.
public final class KeychainService: CredentialProvider, @unchecked Sendable {

    private let service = "com.lollipopkit.mfuse.credentials"
    private let accessGroup: String?
    private let allowLegacyMigration: Bool
    private let legacyAccessGroups: [String]
    public let syncMode: KeychainItemSyncMode
    private var usesDataProtectionKeychain: Bool { accessGroup != nil }

    public init(
        accessGroup: String? = AppGroupConstants.keychainAccessGroup,
        syncMode: KeychainItemSyncMode = SharedAppSettings.iCloudSyncEnabled ? .synchronizable : .local,
        allowLegacyMigration: Bool = true,
        legacyAccessGroups: [String] = [AppGroupConstants.legacyKeychainAccessGroup].compactMap { $0 }
    ) {
        self.accessGroup = accessGroup
        self.syncMode = syncMode
        self.allowLegacyMigration = allowLegacyMigration
        self.legacyAccessGroups = legacyAccessGroups.filter { $0 != accessGroup }
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
        if let data = try readKeychainData(
            account: account,
            useDataProtectionKeychain: usesDataProtectionKeychain
        ) {
            return data
        }

        guard usesDataProtectionKeychain,
              allowLegacyMigration,
              let migrated = try migrateLegacyKeychainDataIfNeeded(account: account) else {
            return nil
        }
        return migrated
    }

    private func writeKeychainData(_ data: Data, account: String) throws {
        try writeKeychainData(
            data,
            account: account,
            useDataProtectionKeychain: usesDataProtectionKeychain
        )
        guard usesDataProtectionKeychain else {
            return
        }
        cleanupLegacyKeychainData(account: account)
    }

    private func deleteKeychainData(account: String) throws {
        try deleteKeychainData(
            account: account,
            useDataProtectionKeychain: usesDataProtectionKeychain
        )
        guard usesDataProtectionKeychain else {
            return
        }
        try deleteLegacyKeychainData(account: account)
    }

    private func migrateLegacyKeychainDataIfNeeded(account: String) throws -> Data? {
        for legacyAccessGroup in legacyAccessGroups {
            guard let legacyData = try readKeychainData(
                account: account,
                accessGroup: legacyAccessGroup,
                useDataProtectionKeychain: true
            ) else {
                continue
            }

            try writeKeychainData(
                legacyData,
                account: account,
                useDataProtectionKeychain: true
            )
            try deleteKeychainData(
                account: account,
                accessGroup: legacyAccessGroup,
                useDataProtectionKeychain: true
            )
            return legacyData
        }

        return nil
    }

    private func cleanupLegacyKeychainData(account: String) {
        guard usesDataProtectionKeychain else {
            return
        }
        for legacyAccessGroup in legacyAccessGroups {
            try? deleteKeychainData(
                account: account,
                accessGroup: legacyAccessGroup,
                useDataProtectionKeychain: true
            )
        }
    }

    private func deleteLegacyKeychainData(account: String) throws {
        for legacyAccessGroup in legacyAccessGroups {
            try deleteKeychainData(
                account: account,
                accessGroup: legacyAccessGroup,
                useDataProtectionKeychain: true
            )
        }
    }

    private func readKeychainData(account: String, useDataProtectionKeychain: Bool) throws -> Data? {
        var query = baseQuery(
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        return result as? Data
    }

    private func writeKeychainData(
        _ data: Data,
        account: String,
        useDataProtectionKeychain: Bool
    ) throws {
        let searchQuery = baseQuery(
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw keychainError(updateStatus)
        }
    }

    private func deleteKeychainData(account: String, useDataProtectionKeychain: Bool) throws {
        try deleteKeychainData(
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
    }

    private func readKeychainData(
        account: String,
        accessGroup: String?,
        useDataProtectionKeychain: Bool
    ) throws -> Data? {
        var query = baseQuery(
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        return result as? Data
    }

    private func deleteKeychainData(
        account: String,
        accessGroup: String?,
        useDataProtectionKeychain: Bool
    ) throws {
        let query = baseQuery(
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(
        account: String,
        accessGroup: String?,
        useDataProtectionKeychain: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if syncMode == .synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return query
    }

    private func keychainError(_ status: OSStatus) -> Error {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error (\(status))"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: msg])
    }

    public static func isSynchronizableKeychainAvailable(
        accessGroup: String? = AppGroupConstants.keychainAccessGroup
    ) -> Bool {
        let probeAccount = "probe.\(UUID().uuidString)"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lollipopkit.mfuse.credentials.probe",
            kSecAttrAccount as String: probeAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecValueData as String: Data("probe".utf8),
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            return false
        }

        var readQuery = query
        readQuery[kSecValueData as String] = nil
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)

        let deleteStatus = SecItemDelete(query as CFDictionary)
        let deleteSucceeded = deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound

        return readStatus == errSecSuccess && deleteSucceeded && result as? Data != nil
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
