import Foundation
import MFuseCore
import FileProvider
import os.log

/// Bridges ConnectionManager operations with NSFileProviderDomain lifecycle.
/// Mount/unmount is now handled automatically by ConnectionManager.
/// This class provides domain sync on startup.
@MainActor
public final class DomainManager: ObservableObject {
    private static let replicatedDomainMigrationDefaultsKey =
        "com.lollipopkit.mfuse.fileprovider.replicated-domain-migration-v1"
    private static let logger = Logger(subsystem: "com.lollipopkit.mfuse", category: "DomainManager")

    struct SyncDomainsError: LocalizedError {
        enum Operation: String {
            case register = "register"
            case disconnect = "disconnect"
            case removeStaleDomain = "remove stale domain"
            case listDomains = "list domains"
            case cleanup = "cleanup"
            case removeAllDomains = "remove all domains"
        }

        struct Entry {
            let id: String
            let operation: Operation
            let error: Error
        }

        let errors: [Entry]

        var errorDescription: String? {
            let details = errors.map {
                "\($0.operation.rawValue) [\($0.id)]: \($0.error.localizedDescription)"
            }.joined(separator: "; ")
            return AppL10n.string(
                "domain.sync.error.reconcile",
                fallback: "Failed to reconcile one or more File Provider domains: %@",
                details
            )
        }
    }

    private let connectionManager: ConnectionManager
    private let mountProvider: FileProviderMountProvider

    public init(connectionManager: ConnectionManager, mountProvider: FileProviderMountProvider) {
        self.connectionManager = connectionManager
        self.mountProvider = mountProvider
    }

    /// Sync current connections with File Provider domains.
    /// Reconciles saved connections with File Provider domains so partial save-time
    /// registration failures can be retried and stale system state can be cleaned up
    /// during startup.
    public func syncDomains() async throws {
        try await repairReplicatedDomainRegistrationIfNeeded()
        try await reconcileDomainsAndSymlinks()
    }

    /// Remove currently registered MFuse domains that do not correspond to a saved connection.
    /// This intentionally skips the replicated-domain migration path so it can be used for
    /// targeted cleanup without invoking `removeAllDomains()`.
    public func cleanupResidualDomains() async throws {
        try await removeStaleDomainsAndSymlinks()
    }

    private func reconcileDomainsAndSymlinks() async throws {
        var errors: [SyncDomainsError.Entry] = []
        let existingDomainStates: [RegisteredDomainState]
        let didLoadExistingDomainStates: Bool
        do {
            existingDomainStates = try await mountProvider.domainStates()
            didLoadExistingDomainStates = true
        } catch {
            errors.append(.init(id: "__domains__", operation: .listDomains, error: error))
            Self.logger.error(
                "Failed to list existing domain states before reconciliation: \(String(describing: error), privacy: .private)"
            )
            existingDomainStates = []
            didLoadExistingDomainStates = false
        }
        let existingStatesByID = Dictionary(
            uniqueKeysWithValues: existingDomainStates.map { ($0.identifier, $0) }
        )

        for config in connectionManager.connections {
            do {
                try await mountProvider.ensureRegistered(config: config)
            } catch {
                errors.append(
                    .init(id: config.domainIdentifier, operation: .register, error: error)
                )
                continue
            }

            let existingState = existingStatesByID[config.domainIdentifier]
            let shouldRemainDisconnected: Bool
            if let existingState {
                shouldRemainDisconnected = existingState.isDisconnected
            } else if didLoadExistingDomainStates {
                // Newly reconciled domains should stay unmounted until the user
                // explicitly connects them or auto-mount runs.
                shouldRemainDisconnected = true
            } else {
                // If listing existing domain states failed, avoid disconnecting
                // potentially active mounts based on an empty snapshot.
                shouldRemainDisconnected = false
            }

            if shouldRemainDisconnected {
                do {
                    try await mountProvider.disconnect(config: config)
                } catch {
                    errors.append(
                        .init(id: config.domainIdentifier, operation: .disconnect, error: error)
                    )
                }
            }
        }

        do {
            try await removeStaleDomainsAndSymlinks()
        } catch let syncError as SyncDomainsError {
            errors.append(contentsOf: syncError.errors)
        } catch {
            errors.append(.init(id: "__cleanup__", operation: .cleanup, error: error))
        }

        if !errors.isEmpty {
            throw SyncDomainsError(errors: errors)
        }
    }

    private func removeStaleDomainsAndSymlinks() async throws {
        let knownIDs = Set(connectionManager.connections.map(\.domainIdentifier))
        var errors: [SyncDomainsError.Entry] = []
        let domains: [NSFileProviderDomain]

        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            errors.append(.init(id: "__domains__", operation: .listDomains, error: error))
            domains = []
        }
        let domainStates = domains.map {
            RegisteredDomainState(
                identifier: $0.identifier.rawValue,
                isDisconnected: $0.isDisconnected
            )
        }

        // Remove stale domains
        for domainState in domainStates where !knownIDs.contains(domainState.identifier) {
            do {
                if let domain = domains.first(where: { $0.identifier.rawValue == domainState.identifier }) {
                    try await NSFileProviderManager.remove(domain)
                }
            } catch {
                errors.append(
                    .init(id: domainState.identifier, operation: .removeStaleDomain, error: error)
                )
            }
        }

        // Remove orphaned symlinks
        let fm = FileManager.default
        let baseDir = mountProvider.symlinkBaseURL
        if fm.fileExists(atPath: baseDir.path),
           let contents = try? fm.contentsOfDirectory(atPath: baseDir.path) {
            let knownNames = Set(connectionManager.connections.map(FileProviderMountProvider.symlinkFilename(for:)))
            for name in contents where !knownNames.contains(name) {
                let candidateURL = baseDir.appendingPathComponent(name)
                guard FileProviderMountProvider.shouldRemoveManagedSymlink(at: candidateURL, fileManager: fm) else {
                    continue
                }
                try? fm.removeItem(at: candidateURL)
            }
        }

        if !errors.isEmpty {
            throw SyncDomainsError(errors: errors)
        }
    }

    private func repairReplicatedDomainRegistrationIfNeeded() async throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.replicatedDomainMigrationDefaultsKey) else {
            return
        }

        let existingDomains = try await NSFileProviderManager.domains()
        let domainIDs = Set(existingDomains.map(\.identifier.rawValue))
        let knownConfigsByDomainID = Dictionary(
            uniqueKeysWithValues: connectionManager.connections.map { ($0.domainIdentifier, $0) }
        )
        var errors: [SyncDomainsError.Entry] = []

        do {
            try await NSFileProviderManager.removeAllDomains()
            // File Provider domain removal completes asynchronously after the API returns.
            // This fixed delay gives the system time to finish tearing down internal state
            // before we re-register domains below. A future improvement could replace this
            // with a configurable constant or a more reliable readiness signal/callback if
            // Apple exposes one.
            try await Task.sleep(nanoseconds: FileProviderConstants.domainRemovalSettleNanoseconds)
        } catch {
            throw SyncDomainsError(
                errors: [.init(id: "__all_domains__", operation: .removeAllDomains, error: error)]
            )
        }

        for domainID in domainIDs {
            guard let config = knownConfigsByDomainID[domainID] else { continue }
            do {
                try await mountProvider.ensureRegistered(config: config)
            } catch {
                errors.append(.init(id: domainID, operation: .register, error: error))
            }
        }

        defaults.set(true, forKey: Self.replicatedDomainMigrationDefaultsKey)

        if !errors.isEmpty {
            throw SyncDomainsError(errors: errors)
        }
    }
}
