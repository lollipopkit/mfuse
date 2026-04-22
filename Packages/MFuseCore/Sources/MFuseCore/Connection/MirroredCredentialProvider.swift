import Foundation

public enum MirroredCredentialProviderError: Error, LocalizedError {
    case unsupportedPrimaryProvider

    public var errorDescription: String? {
        switch self {
        case .unsupportedPrimaryProvider:
            return MFuseCoreL10n.string(
                "credential.error.unsupportedPrimaryProvider",
                fallback: "The current credential provider does not support iCloud Keychain migration."
            )
        }
    }
}

public struct ModeTransitionError: Error, LocalizedError {
    public let originalError: Error
    public let rollbackError: Error

    public init(originalError: Error, rollbackError: Error) {
        self.originalError = originalError
        self.rollbackError = rollbackError
    }

    public var errorDescription: String? {
        MFuseCoreL10n.string(
            "credential.error.modeTransitionFailed",
            fallback: "Credential mode transition failed: %@. Rollback failed: %@",
            originalError.localizedDescription,
            rollbackError.localizedDescription
        )
    }
}

private struct ModeTransitionRollbackError: Error, LocalizedError {
    let failures: [String]

    var errorDescription: String? {
        failures.joined(separator: " ")
    }
}

public enum MirroredCredentialSyncState: Sendable, Equatable {
    case local
    case synchronizable
    case mixed
}

private actor MirroredCredentialOperationBarrier {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withExclusive<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isRunning = false
        }
    }
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
        let writtenConnectionIDs: Set<UUID>
    }

    private let lock = NSLock()
    private let operationBarrier = MirroredCredentialOperationBarrier()
    private let primaryFactory: @Sendable (KeychainItemSyncMode) -> KeychainService
    private let sharedStoreFactory: @Sendable (KeychainItemSyncMode) -> SharedCredentialStore
    private let customCredentialExistenceProbe: (@Sendable (KeychainItemSyncMode, UUID) async throws -> Bool)?
    private var primaryStoreCache: [KeychainItemSyncMode: KeychainService] = [:]
    private var sharedStoreCache: [KeychainItemSyncMode: SharedCredentialStore] = [:]
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
        self.customCredentialExistenceProbe = credentialExistenceProbe
        self.primary = primary
        self.sharedStore = sharedStore
    }

    public var syncMode: KeychainItemSyncMode {
        lock.withLock {
            (primary as? KeychainService)?.syncMode ?? .local
        }
    }

    public func credential(for connectionID: UUID) async throws -> Credential? {
        try await operationBarrier.withExclusive {
            let (primary, sharedStore) = storesSnapshot()
            return try await resolveCredential(
                for: connectionID,
                primary: primary,
                sharedStore: sharedStore
            )
        }
    }

    public func store(_ credential: Credential, for connectionID: UUID) async throws {
        try await operationBarrier.withExclusive {
            let (primary, sharedStore) = storesSnapshot()
            try await primary.store(credential, for: connectionID)
            try sharedStore.store(credential, for: connectionID)
        }
    }

    public func delete(for connectionID: UUID) async throws {
        try await operationBarrier.withExclusive {
            let (primary, sharedStore) = storesSnapshot()
            try sharedStore.delete(for: connectionID)
            try await primary.delete(for: connectionID)
        }
    }

    public func credentialSyncState(for connectionIDs: [UUID]) async throws -> MirroredCredentialSyncState {
        try await operationBarrier.withExclusive {
            guard !connectionIDs.isEmpty else {
                return syncMode == .synchronizable ? .synchronizable : .local
            }

            var foundLocalCredential = false
            var foundSynchronizableCredential = false

            for connectionID in connectionIDs {
                if try await credentialExists(in: .local, for: connectionID) {
                    foundLocalCredential = true
                }

                if try await credentialExists(in: .synchronizable, for: connectionID) {
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
    }

    public func setSynchronizableEnabled(_ enabled: Bool, connectionIDs: [UUID]) async throws {
        try await operationBarrier.withExclusive {
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
            var writtenConnectionIDs: Set<UUID> = []
            for connectionID in connectionIDs {
                if let credential = try await resolveCredential(
                    for: connectionID,
                    primary: sourcePrimary,
                    sharedStore: sourceSharedStore
                ) {
                    credentialsToMove[connectionID] = credential
                }
            }

            do {
                for (connectionID, credential) in credentialsToMove {
                    try await targetPrimary.store(credential, for: connectionID)
                    writtenConnectionIDs.insert(connectionID)
                    try targetSharedStore.store(credential, for: connectionID)
                    writtenConnectionIDs.insert(connectionID)
                }
            } catch {
                let originalError = error
                let context = ModeTransitionContext(
                    credentialsToMove: credentialsToMove,
                    sourcePrimary: sourcePrimary,
                    sourceSharedStore: sourceSharedStore,
                    targetPrimary: targetPrimary,
                    targetSharedStore: targetSharedStore,
                    writtenConnectionIDs: writtenConnectionIDs
                )

                do {
                    try await rollbackModeTransition(context: context)
                } catch {
                    throw ModeTransitionError(
                        originalError: originalError,
                        rollbackError: error
                    )
                }

                throw originalError
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
    }

    private func rollbackModeTransition(context: ModeTransitionContext) async throws {
        var failures: [String] = []

        for (connectionID, credential) in context.credentialsToMove {
            do {
                try await context.sourcePrimary.store(credential, for: connectionID)
            } catch {
                failures.append(
                    "rollbackModeTransition sourcePrimary.store failed for \(connectionID.uuidString): \(error.localizedDescription)"
                )
            }

            do {
                try context.sourceSharedStore.store(credential, for: connectionID)
            } catch {
                failures.append(
                    "rollbackModeTransition sourceSharedStore.store failed for \(connectionID.uuidString): \(error.localizedDescription)"
                )
            }
        }

        for connectionID in context.writtenConnectionIDs {
            do {
                try await context.targetPrimary.delete(for: connectionID)
            } catch {
                failures.append(
                    "rollbackModeTransition targetPrimary.delete failed for \(connectionID.uuidString): \(error.localizedDescription)"
                )
            }

            do {
                try context.targetSharedStore.delete(for: connectionID)
            } catch {
                failures.append(
                    "rollbackModeTransition targetSharedStore.delete failed for \(connectionID.uuidString): \(error.localizedDescription)"
                )
            }
        }

        if !failures.isEmpty {
            throw ModeTransitionRollbackError(failures: failures)
        }
    }

    private func storesSnapshot() -> (CredentialProvider, SharedCredentialStore) {
        lock.withLock {
            (primary, sharedStore)
        }
    }

    private func resolveCredential(
        for connectionID: UUID,
        primary: CredentialProvider,
        sharedStore: SharedCredentialStore
    ) async throws -> Credential? {
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

    private func credentialExists(in mode: KeychainItemSyncMode, for connectionID: UUID) async throws -> Bool {
        if let customCredentialExistenceProbe {
            return try await customCredentialExistenceProbe(mode, connectionID)
        }

        let (primary, sharedStore) = cachedStores(for: mode)
        if try await primary.credential(for: connectionID) != nil {
            return true
        }

        return try sharedStore.credential(for: connectionID) != nil
    }

    private func cachedStores(
        for mode: KeychainItemSyncMode
    ) -> (primary: KeychainService, sharedStore: SharedCredentialStore) {
        lock.withLock {
            let primary: KeychainService
            if let cachedPrimary = primaryStoreCache[mode] {
                primary = cachedPrimary
            } else {
                let createdPrimary = primaryFactory(mode)
                primaryStoreCache[mode] = createdPrimary
                primary = createdPrimary
            }

            let sharedStore: SharedCredentialStore
            if let cachedSharedStore = sharedStoreCache[mode] {
                sharedStore = cachedSharedStore
            } else {
                let createdSharedStore = sharedStoreFactory(mode)
                sharedStoreCache[mode] = createdSharedStore
                sharedStore = createdSharedStore
            }

            return (primary, sharedStore)
        }
    }
}
