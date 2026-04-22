import Foundation
import MFuseCore
import FileProvider

/// Bridges ConnectionManager operations with NSFileProviderDomain lifecycle.
/// Mount/unmount is now handled automatically by ConnectionManager.
/// This class provides domain sync on startup.
@MainActor
public final class DomainManager: ObservableObject {
    private static let replicatedDomainMigrationDefaultsKey =
        "com.lollipopkit.mfuse.fileprovider.replicated-domain-migration-v1"

    struct SyncDomainsError: LocalizedError {
        let errors: [(id: String, error: Error)]

        var errorDescription: String? {
            let details = errors.map { "\($0.id): \($0.error.localizedDescription)" }.joined(separator: "; ")
            return AppL10n.string(
                "domain.sync.error.removeStaleDomains",
                fallback: "Failed to remove one or more stale File Provider domains: %@",
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
    /// Reconciles saved connections with File Provider domains.
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
        let existingDomainStates = try await mountProvider.domainStates()
        let existingStatesByID = Dictionary(
            uniqueKeysWithValues: existingDomainStates.map { ($0.identifier, $0) }
        )

        for config in connectionManager.connections {
            try await mountProvider.ensureRegistered(config: config)

            if existingStatesByID[config.domainIdentifier]?.isDisconnected != false {
                try? await mountProvider.disconnect(config: config)
            }
        }

        try await removeStaleDomainsAndSymlinks()
    }

    private func removeStaleDomainsAndSymlinks() async throws {
        let knownIDs = Set(connectionManager.connections.map(\.domainIdentifier))
        let domainStates = try await mountProvider.domainStates()
        var errors: [(id: String, error: Error)] = []

        // Remove stale domains
        for domainState in domainStates where !knownIDs.contains(domainState.identifier) {
            do {
                let domains = try await NSFileProviderManager.domains()
                if let domain = domains.first(where: { $0.identifier.rawValue == domainState.identifier }) {
                    try await NSFileProviderManager.remove(domain)
                }
            } catch {
                errors.append((id: domainState.identifier, error: error))
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
        var errors: [(id: String, error: Error)] = []

        do {
            try await NSFileProviderManager.removeAllDomains()
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            throw SyncDomainsError(errors: [("__all_domains__", error)])
        }

        for domainID in domainIDs {
            guard let config = knownConfigsByDomainID[domainID] else { continue }
            do {
                try await mountProvider.ensureRegistered(config: config)
            } catch {
                errors.append((id: domainID, error: error))
            }
        }

        if !errors.isEmpty {
            throw SyncDomainsError(errors: errors)
        }

        defaults.set(true, forKey: Self.replicatedDomainMigrationDefaultsKey)
    }
}
