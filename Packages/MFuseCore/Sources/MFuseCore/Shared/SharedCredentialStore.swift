import Foundation
import os.log
import Security

/// Stores provider-readable credential snapshots in the shared Keychain.
/// Legacy cleartext credential files in the App Group container are only used
/// as a read-once migration source and are deleted after successful migration.
public final class SharedCredentialStore: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse",
        category: "SharedCredentialStore"
    )
    private static let service = "com.lollipopkit.mfuse.credentials"

    public let containerURL: URL
    private let accessGroup: String?
    private let allowLegacyKeychainMigration: Bool
    private let legacyAccessGroups: [String]
    private var usesDataProtectionKeychain: Bool { accessGroup != nil }

    public init(
        allowFallbackToTemporaryDirectory: Bool = false,
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        ),
        accessGroup: String? = AppGroupConstants.keychainAccessGroup,
        allowLegacyKeychainMigration: Bool = true,
        legacyAccessGroups: [String] = [AppGroupConstants.legacyKeychainAccessGroup].compactMap { $0 }
    ) {
        if let containerURL {
            self.containerURL = containerURL
        } else if allowFallbackToTemporaryDirectory {
            self.containerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MFuseSharedCredentials", isDirectory: true)
        } else {
            preconditionFailure(
                "SharedCredentialStore failed to resolve App Group container for \(AppGroupConstants.groupIdentifier). " +
                "Pass allowFallbackToTemporaryDirectory: true only for tests, or inject an explicit containerURL."
            )
        }
        self.accessGroup = accessGroup
        self.allowLegacyKeychainMigration = allowLegacyKeychainMigration
        self.legacyAccessGroups = legacyAccessGroups.filter { $0 != accessGroup }
    }

    public func credential(for connectionID: UUID) throws -> Credential? {
        if let data = try readKeychainData(account: connectionID.uuidString) {
            do {
                return try JSONDecoder().decode(Credential.self, from: data)
            } catch {
                Self.logger.error(
                    "Failed to decode shared credential from Keychain for \(connectionID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                throw error
            }
        }

        return try migrateLegacyCredentialIfNeeded(for: connectionID)
    }

    public func store(_ credential: Credential, for connectionID: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        try writeKeychainData(data, account: connectionID.uuidString)
        removeLegacyCredentialFileIfPresent(for: connectionID)
    }

    public func delete(for connectionID: UUID) throws {
        try deleteKeychainData(account: connectionID.uuidString)
        removeLegacyCredentialFileIfPresent(for: connectionID)
    }

    public func credentialURL(for connectionID: UUID) throws -> URL {
        credentialFileURL(for: connectionID)
    }

    private var credentialsDirectoryURL: URL {
        containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
    }

    private func credentialFileURL(for connectionID: UUID) -> URL {
        credentialsDirectoryURL.appendingPathComponent("\(connectionID.uuidString).json")
    }

    private func migrateLegacyCredentialIfNeeded(for connectionID: UUID) throws -> Credential? {
        let url = credentialFileURL(for: connectionID)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        do {
            let credential = try JSONDecoder().decode(Credential.self, from: data)
            let encoded = try JSONEncoder().encode(credential)
            try writeKeychainData(encoded, account: connectionID.uuidString)
            removeLegacyCredentialFileIfPresent(for: connectionID)
            return credential
        } catch {
            Self.logger.error(
                "Failed to migrate legacy shared credential at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func removeLegacyCredentialFileIfPresent(for connectionID: UUID) {
        let url = credentialFileURL(for: connectionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error(
                "Failed to remove legacy shared credential at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func readKeychainData(account: String) throws -> Data? {
        if let data = try readKeychainData(
            account: account,
            useDataProtectionKeychain: usesDataProtectionKeychain
        ) {
            return data
        }

        guard usesDataProtectionKeychain,
              allowLegacyKeychainMigration,
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
        let query = baseQuery(
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
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
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func keychainError(_ status: OSStatus) -> Error {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error (\(status))"
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
