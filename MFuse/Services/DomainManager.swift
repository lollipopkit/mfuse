import Foundation
import MFuseCore
import FileProvider

/// Bridges ConnectionManager operations with NSFileProviderDomain lifecycle.
/// Mount/unmount is now handled automatically by ConnectionManager.
/// This class provides domain sync on startup.
@MainActor
public final class DomainManager: ObservableObject {

    struct SyncDomainsError: LocalizedError {
        let errors: [(id: String, error: Error)]

        var errorDescription: String? {
            let details = errors.map { "\($0.id): \($0.error.localizedDescription)" }.joined(separator: "; ")
            return "Failed to remove one or more stale File Provider domains: \(details)"
        }
    }

    private let connectionManager: ConnectionManager
    private let mountProvider: FileProviderMountProvider

    public init(connectionManager: ConnectionManager, mountProvider: FileProviderMountProvider) {
        self.connectionManager = connectionManager
        self.mountProvider = mountProvider
    }

    /// Sync current connections with File Provider domains.
    /// Removes stale domains that no longer have a corresponding connection.
    public func syncDomains() async throws {
        let knownIDs = Set(connectionManager.connections.map(\.domainIdentifier))
        let domains = try await NSFileProviderManager.domains()
        var errors: [(id: String, error: Error)] = []

        // Remove stale domains
        for domain in domains where !knownIDs.contains(domain.identifier.rawValue) {
            do {
                try await NSFileProviderManager.remove(domain)
            } catch {
                errors.append((id: domain.identifier.rawValue, error: error))
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
}
