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
    /// The Keychain service every credential item is filed under.
    public static let defaultService = "com.lollipopkit.mfuse.credentials"

    public let containerURL: URL
    /// Overridable so tests do not file their fixtures under the service the installed
    /// app uses: an unentitled process — every test binary — has no access group, which
    /// puts its items in the login Keychain, where nothing but a matching service tells
    /// them apart from a developer's real credentials.
    public let service: String
    private let accessGroup: String?
    private let allowLegacyKeychainMigration: Bool
    private let legacyAccessGroups: [String]
    public let syncMode: KeychainItemSyncMode
    private var usesDataProtectionKeychain: Bool { accessGroup != nil }

    public init(
        allowFallbackToTemporaryDirectory: Bool = false,
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        ),
        accessGroup: String? = AppGroupConstants.keychainAccessGroup,
        service: String = SharedCredentialStore.defaultService,
        syncMode: KeychainItemSyncMode = SharedAppSettings.iCloudSyncEnabled ? .synchronizable : .local,
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
        self.service = service
        self.syncMode = syncMode
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
            // The secret is already in the Keychain, so failing the write that put it there
            // would only cost the caller the credential it just stored. What must not
            // survive is the cleartext copy: deleting needs the directory to be writable
            // and emptying only the file, so this is a second chance at the part that
            // matters even when the first one is refused.
            //
            // Truncated in place rather than replaced atomically: an atomic write creates a
            // temporary file and renames it over this one, which needs exactly the
            // directory permission the removal above was just refused — so it would fail
            // for the same reason and leave the secret readable.
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
            } catch {
                Self.logger.fault(
                    "Left a readable legacy credential file at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
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

    /// Both Keychain partitions, the one this store writes to first.
    ///
    /// A legacy item was written under whatever iCloud-sync setting was in force at the
    /// time, which need not be the one in force now: probing only this store's partition
    /// leaves an item in the other one invisible — the credential is never migrated, so the
    /// mount stops authenticating, and the item stays behind in an access group nothing
    /// else cleans up.
    private var legacySyncModes: [KeychainItemSyncMode] {
        syncMode == .synchronizable ? [.synchronizable, .local] : [.local, .synchronizable]
    }

    private func migrateLegacyKeychainDataIfNeeded(account: String) throws -> Data? {
        for legacyAccessGroup in legacyAccessGroups {
            for legacySyncMode in legacySyncModes {
                guard let legacyData = try readKeychainData(
                    account: account,
                    accessGroup: legacyAccessGroup,
                    useDataProtectionKeychain: true,
                    syncMode: legacySyncMode
                ) else {
                    continue
                }

                try writeKeychainData(
                    legacyData,
                    account: account,
                    useDataProtectionKeychain: true
                )
                // Deleted from the partition it was found in, not from this store's.
                try deleteKeychainData(
                    account: account,
                    accessGroup: legacyAccessGroup,
                    useDataProtectionKeychain: true,
                    syncMode: legacySyncMode
                )
                return legacyData
            }
        }

        return nil
    }

    private func cleanupLegacyKeychainData(account: String) {
        guard usesDataProtectionKeychain else {
            return
        }
        for legacyAccessGroup in legacyAccessGroups {
            for legacySyncMode in legacySyncModes {
                try? deleteKeychainData(
                    account: account,
                    accessGroup: legacyAccessGroup,
                    useDataProtectionKeychain: true,
                    syncMode: legacySyncMode
                )
            }
        }
    }

    private func deleteLegacyKeychainData(account: String) throws {
        for legacyAccessGroup in legacyAccessGroups {
            for legacySyncMode in legacySyncModes {
                try deleteKeychainData(
                    account: account,
                    accessGroup: legacyAccessGroup,
                    useDataProtectionKeychain: true,
                    syncMode: legacySyncMode
                )
            }
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
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
        useDataProtectionKeychain: Bool,
        syncMode: KeychainItemSyncMode? = nil
    ) throws -> Data? {
        var query = baseQuery(
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain,
            syncMode: syncMode
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
        useDataProtectionKeychain: Bool,
        syncMode: KeychainItemSyncMode? = nil
    ) throws {
        let query = baseQuery(
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain,
            syncMode: syncMode
        )
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(
        account: String,
        accessGroup: String?,
        useDataProtectionKeychain: Bool,
        syncMode: KeychainItemSyncMode? = nil
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        // Stated for both modes, the way `KeychainService` states it. Omitting it leaves
        // the partition to the Keychain's default rather than to this store, and the two
        // modes exist precisely so a local item and a synchronized one are never confused
        // for each other — a read, an update or a delete must address the one it was told.
        query[kSecAttrSynchronizable as String] =
            (syncMode ?? self.syncMode) == .synchronizable ? kCFBooleanTrue : kCFBooleanFalse
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
