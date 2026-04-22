import Foundation

public enum MirroredCredentialProviderError: Error, LocalizedError {
    case unsupportedPrimaryProvider

    public var errorDescription: String? {
        switch self {
        case .unsupportedPrimaryProvider:
            return "The current credential provider does not support iCloud Keychain migration."
        }
    }
}

/// Uses Keychain as the app-facing credential store while mirroring credentials
/// into the shared credential store used by the File Provider extension.
public final class MirroredCredentialProvider: CredentialProvider, @unchecked Sendable {

    private let lock = NSLock()
    private let primaryFactory: @Sendable (KeychainItemSyncMode) -> KeychainService
    private let sharedStoreFactory: @Sendable (KeychainItemSyncMode) -> SharedCredentialStore
    private var primary: CredentialProvider
    public private(set) var sharedStore: SharedCredentialStore

    public init(
        primary: CredentialProvider = KeychainService(),
        sharedStore: SharedCredentialStore = SharedCredentialStore(allowLegacyKeychainMigration: true)
    ) {
        self.primaryFactory = { KeychainService(syncMode: $0) }
        self.sharedStoreFactory = { SharedCredentialStore(syncMode: $0, allowLegacyKeychainMigration: true) }
        self.primary = primary
        self.sharedStore = sharedStore
    }

    public var syncMode: KeychainItemSyncMode {
        lock.withLock {
            (primary as? KeychainService)?.syncMode ?? .local
        }
    }

    public func credential(for connectionID: UUID) async throws -> Credential? {
        let (primary, sharedStore) = storesSnapshot()
        let primaryCredential = try await primary.credential(for: connectionID)
        if let primaryCredential {
            do {
                try sharedStore.store(primaryCredential, for: connectionID)
            } catch {
                // Best-effort mirror repair for the File Provider extension.
            }
            return primaryCredential
        }

        return try sharedStore.credential(for: connectionID)
    }

    public func store(_ credential: Credential, for connectionID: UUID) async throws {
        let (primary, sharedStore) = storesSnapshot()
        try await primary.store(credential, for: connectionID)
        try sharedStore.store(credential, for: connectionID)
    }

    public func delete(for connectionID: UUID) async throws {
        let (primary, sharedStore) = storesSnapshot()
        try await primary.delete(for: connectionID)
        try sharedStore.delete(for: connectionID)
    }

    public func setSynchronizableEnabled(_ enabled: Bool, connectionIDs: [UUID]) async throws {
        let targetMode: KeychainItemSyncMode = enabled ? .synchronizable : .local
        let (sourcePrimary, sourceSharedStore) = storesSnapshot()
        guard let keychainPrimary = sourcePrimary as? KeychainService else {
            throw MirroredCredentialProviderError.unsupportedPrimaryProvider
        }
        guard keychainPrimary.syncMode != targetMode else {
            return
        }

        let targetPrimary = primaryFactory(targetMode)
        let targetSharedStore = sharedStoreFactory(targetMode)

        var credentialsToMove: [UUID: Credential] = [:]
        for connectionID in connectionIDs {
            if let credential = try await credential(for: connectionID) {
                credentialsToMove[connectionID] = credential
            }
        }

        do {
            for (connectionID, credential) in credentialsToMove {
                try await targetPrimary.store(credential, for: connectionID)
                try targetSharedStore.store(credential, for: connectionID)
            }

            for connectionID in connectionIDs {
                try await sourcePrimary.delete(for: connectionID)
                try sourceSharedStore.delete(for: connectionID)
            }
        } catch {
            try? await rollbackModeTransition(
                credentialsToMove: credentialsToMove,
                sourcePrimary: sourcePrimary,
                sourceSharedStore: sourceSharedStore,
                targetPrimary: targetPrimary,
                targetSharedStore: targetSharedStore,
                connectionIDs: connectionIDs
            )
            throw error
        }

        lock.withLock {
            primary = targetPrimary
            sharedStore = targetSharedStore
        }
    }

    private func rollbackModeTransition(
        credentialsToMove: [UUID: Credential],
        sourcePrimary: CredentialProvider,
        sourceSharedStore: SharedCredentialStore,
        targetPrimary: KeychainService,
        targetSharedStore: SharedCredentialStore,
        connectionIDs: [UUID]
    ) async throws {
        for (connectionID, credential) in credentialsToMove {
            try? await sourcePrimary.store(credential, for: connectionID)
            try? sourceSharedStore.store(credential, for: connectionID)
        }

        for connectionID in connectionIDs {
            try? await targetPrimary.delete(for: connectionID)
            try? targetSharedStore.delete(for: connectionID)
        }
    }

    private func storesSnapshot() -> (CredentialProvider, SharedCredentialStore) {
        lock.withLock {
            (primary, sharedStore)
        }
    }
}
