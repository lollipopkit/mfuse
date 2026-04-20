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
            let knownNames = Set(connectionManager.connections.map(FileProviderMountProvider.symlinkFilename(for:)))
            for name in contents where !knownNames.contains(name) {
                let candidateURL = baseDir.appendingPathComponent(name)
                guard shouldRemoveManagedSymlink(at: candidateURL, fileManager: fm) else {
                    continue
                }
                try? fm.removeItem(at: candidateURL)
            }
        }
    }

    private func shouldRemoveManagedSymlink(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              matchesManagedSymlinkFilename(url.lastPathComponent),
              let destinationPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }

        let resolvedDestinationURL = URL(
            fileURLWithPath: destinationPath,
            relativeTo: url.deletingLastPathComponent()
        ).standardizedFileURL

        return isManagedMountDestination(resolvedDestinationURL)
    }

    private func matchesManagedSymlinkFilename(_ name: String) -> Bool {
        guard let separatorIndex = name.lastIndex(of: "-") else {
            return false
        }
        let prefix = name[..<separatorIndex]
        let suffix = name[name.index(after: separatorIndex)...]
        return !prefix.isEmpty && UUID(uuidString: String(suffix)) != nil
    }

    private func isManagedMountDestination(_ url: URL) -> Bool {
        let cloudStorageRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .standardizedFileURL

        let destinationPath = url.path
        let rootPath = cloudStorageRoot.path
        return destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/")
    }
}
