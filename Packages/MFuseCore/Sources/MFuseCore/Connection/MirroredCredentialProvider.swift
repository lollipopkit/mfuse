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

public enum MirroredCredentialSyncState: Sendable, Equatable {
    case local
    case synchronizable
    case mixed
}

/// Uses Keychain as the app-facing credential store while mirroring credentials
/// into the shared credential store used by the File Provider extension.
public final class MirroredCredentialProvider: CredentialProvider, @unchecked Sendable {
    private struct ModeTransitionContext {
        let credentialsToMove: [UUID: Credential]
        let sourcePrimary: CredentialProvider
        let sourceSharedStore: SharedCredentialStore
        let targetPrimary: KeychainService
        let targetSharedStore: SharedCredentialStore
        let connectionIDs: [UUID]
    }

    private let lock = NSLock()
    private let primaryFactory: @Sendable (KeychainItemSyncMode) -> KeychainService
    private let sharedStoreFactory: @Sendable (KeychainItemSyncMode) -> SharedCredentialStore
    private let credentialExistenceProbe: @Sendable (KeychainItemSyncMode, UUID) async throws -> Bool
    private var primary: CredentialProvider
    public private(set) var sharedStore: SharedCredentialStore

    public init(
        primary: CredentialProvider = KeychainService(),
        sharedStore: SharedCredentialStore = SharedCredentialStore(allowLegacyKeychainMigration: true),
        primaryFactory: @escaping @Sendable (KeychainItemSyncMode) -> KeychainService = {
            KeychainService(syncMode: $0)
        },
        sharedStoreFactory: @escaping @Sendable (KeychainItemSyncMode) -> SharedCredentialStore = {
            SharedCredentialStore(syncMode: $0, allowLegacyKeychainMigration: true)
        },
        credentialExistenceProbe: (@Sendable (KeychainItemSyncMode, UUID) async throws -> Bool)? = nil
    ) {
        self.primaryFactory = primaryFactory
        self.sharedStoreFactory = sharedStoreFactory
        if let credentialExistenceProbe {
            self.credentialExistenceProbe = credentialExistenceProbe
        } else {
            self.credentialExistenceProbe = { mode, connectionID in
                let primary = primaryFactory(mode)
                let sharedStore = sharedStoreFactory(mode)
                if try await primary.credential(for: connectionID) != nil {
                    return true
                }

                return try sharedStore.credential(for: connectionID) != nil
            }
        }
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

    public func credentialSyncState(for connectionIDs: [UUID]) async throws -> MirroredCredentialSyncState {
        guard !connectionIDs.isEmpty else {
            return syncMode == .synchronizable ? .synchronizable : .local
        }

        var foundLocalCredential = false
        var foundSynchronizableCredential = false

        for connectionID in connectionIDs {
            if try await credentialExistenceProbe(.local, connectionID) {
                foundLocalCredential = true
            }

            if try await credentialExistenceProbe(.synchronizable, connectionID) {
                foundSynchronizableCredential = true
            }

            if foundLocalCredential && foundSynchronizableCredential {
                return .mixed
            }
        }

        if foundSynchronizableCredential {
            return .synchronizable
        }

        if foundLocalCredential {
            return .local
        }

        return syncMode == .synchronizable ? .synchronizable : .local
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
        } catch {
            try? await rollbackModeTransition(context: ModeTransitionContext(
                credentialsToMove: credentialsToMove,
                sourcePrimary: sourcePrimary,
                sourceSharedStore: sourceSharedStore,
                targetPrimary: targetPrimary,
                targetSharedStore: targetSharedStore,
                connectionIDs: connectionIDs
            ))
            throw error
        }

        for connectionID in connectionIDs {
            do {
                try await sourcePrimary.delete(for: connectionID)
            } catch {
                NSLog(
                    "MFuse credential migration cleanup failed for source primary item %@: %@",
                    connectionID.uuidString,
                    error.localizedDescription
                )
            }

            do {
                try sourceSharedStore.delete(for: connectionID)
            } catch {
                NSLog(
                    "MFuse credential migration cleanup failed for source shared item %@: %@",
                    connectionID.uuidString,
                    error.localizedDescription
                )
            }
        }

        lock.withLock {
            primary = targetPrimary
            sharedStore = targetSharedStore
        }
    }

    private func rollbackModeTransition(context: ModeTransitionContext) async throws {
        for (connectionID, credential) in context.credentialsToMove {
            try? await context.sourcePrimary.store(credential, for: connectionID)
            try? context.sourceSharedStore.store(credential, for: connectionID)
        }

        for connectionID in context.connectionIDs {
            try? await context.targetPrimary.delete(for: connectionID)
            try? context.targetSharedStore.delete(for: connectionID)
        }
    }

    private func storesSnapshot() -> (CredentialProvider, SharedCredentialStore) {
        lock.withLock {
            (primary, sharedStore)
        }
    }
}
