import Foundation
import MFuseCore
import FileProvider

/// Bridges ConnectionManager operations with NSFileProviderDomain lifecycle.
/// Mount/unmount is now handled automatically by ConnectionManager.
/// This class provides domain sync on startup.
@MainActor
public final class DomainManager: ObservableObject {

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

        // Remove stale domains
        for domain in domains where !knownIDs.contains(domain.identifier.rawValue) {
            try await NSFileProviderManager.remove(domain)
        }

        // Remove orphaned symlinks
        let fm = FileManager.default
        let baseDir = FileProviderMountProvider.symlinkBaseURL
        if fm.fileExists(atPath: baseDir.path),
           let contents = try? fm.contentsOfDirectory(atPath: baseDir.path) {
            let knownNames = Set(connectionManager.connections.map { FileProviderMountProvider.sanitizeName($0.name) })
            for name in contents where !knownNames.contains(name) {
                try? fm.removeItem(at: baseDir.appendingPathComponent(name))
            }
        }
    }
}
