import Foundation
import FileProvider
import os.log

/// MountProvider backed by macOS File Provider (NSFileProviderDomain).
/// Mounts appear under ~/Library/CloudStorage/. Symlinks created at ~/MFuse/<name>.
public final class FileProviderMountProvider: MountProvider {

    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse.core",
        category: "FileProviderMountProvider"
    )

    /// Base directory for convenience symlinks.
    public static var symlinkBaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("MFuse")

    public init() {}

    public func mount(config: ConnectionConfig) async throws {
        let domainID = NSFileProviderDomainIdentifier(rawValue: config.domainIdentifier)
        try persistBootstrapConfig(for: config)

        // Remove stale domain with the same identifier before adding
        let existing = try await NSFileProviderManager.domains()
        if let stale = existing.first(where: { $0.identifier == domainID }) {
            try? await NSFileProviderManager.remove(stale)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let domain = try makeDomain(for: config)

        // Retry once if first attempt fails (system may need time after removal)
        do {
            try await NSFileProviderManager.add(domain)
        } catch {
            if isExtensionNotEnabledError(error) {
                throw MountError.extensionNotEnabled
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try Task.checkCancellation()
            do {
                try await NSFileProviderManager.add(domain)
            } catch {
                if isExtensionNotEnabledError(error) {
                    throw MountError.extensionNotEnabled
                }
                throw error
            }
        }
    }

    public func unmount(config: ConnectionConfig) async throws {
        let domainID = NSFileProviderDomainIdentifier(rawValue: config.domainIdentifier)
        let domains = try await NSFileProviderManager.domains()
        guard let domain = domains.first(where: { $0.identifier == domainID }) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        try? removeBootstrapConfig(for: config)
        try await NSFileProviderManager.remove(domain)
    }

    public func mountedDomains() async throws -> [String] {
        let domains = try await NSFileProviderManager.domains()
        return domains.map(\.identifier.rawValue)
    }

    public func signalEnumerator(for config: ConnectionConfig) async throws {
        try persistBootstrapConfig(for: config)
        guard let domain = try await refreshExistingDomain(for: config) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        let manager = NSFileProviderManager(for: domain)
        try await manager?.signalEnumerator(for: .rootContainer)
    }

    public func mountURL(for config: ConnectionConfig) async throws -> URL? {
        try persistBootstrapConfig(for: config)
        guard let domain = try await refreshExistingDomain(for: config) else { return nil }
        guard let manager = NSFileProviderManager(for: domain) else { return nil }
        return try await manager.getUserVisibleURL(for: .rootContainer)
    }

    @discardableResult
    public func createSymlink(for config: ConnectionConfig) async throws -> URL? {
        guard let mountURL = try await mountURL(for: config) else { return nil }

        let fm = FileManager.default
        let baseDir = Self.symlinkBaseURL

        // Ensure ~/MFuse/ exists
        if !fm.fileExists(atPath: baseDir.path) {
            try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }

        let symlinkURL = Self.symlinkURL(for: config, baseDir: baseDir)

        if try isSymbolicLink(at: symlinkURL) {
            try fm.removeItem(at: symlinkURL)
        } else {
            try removeManagedSymlinkIfNeeded(at: symlinkURL, expectedDestinationURL: mountURL)
        }
        guard !fm.fileExists(atPath: symlinkURL.path) else {
            Self.logger.warning(
                "Skipping symlink creation because target path is occupied by a non-managed item: \(symlinkURL.path, privacy: .public)"
            )
            return nil
        }

        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: mountURL)
        return symlinkURL
    }

    public func removeSymlink(for config: ConnectionConfig) async throws {
        let expectedDestinationURL = (try? await mountURL(for: config)) ?? nil
        let symlinkURL = Self.symlinkURL(for: config, baseDir: Self.symlinkBaseURL)
        try removeManagedSymlinkIfNeeded(at: symlinkURL, expectedDestinationURL: expectedDestinationURL)
    }

    /// Sanitize a connection name for use as a filesystem directory name.
    public static func sanitizeName(_ name: String) -> String {
        var result = name
        // Replace characters unsafe for filesystem paths
        for ch: Character in ["/", ":", "\0"] {
            result = result.map { $0 == ch ? "-" : $0 }.map(String.init).joined()
        }
        // Collapse multiple dashes and trim
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return result.isEmpty ? "unnamed" : result
    }

    public static func symlinkFilename(for config: ConnectionConfig) -> String {
        let sanitizedName = sanitizeName(config.name)
        return "\(sanitizedName)-\(config.id.uuidString)"
    }

    public static func symlinkURL(for config: ConnectionConfig, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(symlinkFilename(for: config))
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func removeManagedSymlinkIfNeeded(at symlinkURL: URL, expectedDestinationURL: URL?) throws {
        let fm = FileManager.default
        let path = symlinkURL.path
        guard let attributes = try? fm.attributesOfItem(atPath: path) else {
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return
        }
        if let expectedDestinationURL {
            let destinationPath = try fm.destinationOfSymbolicLink(atPath: path)
            let resolvedDestinationURL = URL(
                fileURLWithPath: destinationPath,
                relativeTo: symlinkURL.deletingLastPathComponent()
            ).standardizedFileURL
            guard resolvedDestinationURL == expectedDestinationURL.standardizedFileURL else {
                return
            }
        }
        try fm.removeItem(at: symlinkURL)
    }

    private func findDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain? {
        let domainID = NSFileProviderDomainIdentifier(rawValue: config.domainIdentifier)
        let domains = try await NSFileProviderManager.domains()
        return domains.first(where: { $0.identifier == domainID })
    }

    private func isExtensionNotEnabledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSFileProviderErrorDomain,
           nsError.code == NSFileProviderError.Code.providerNotFound.rawValue {
            return true
        }
        return MountError.matchesExtensionNotEnabledMessage(nsError.localizedDescription)
    }

    private func makeDomain(for config: ConnectionConfig) throws -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: config.domainIdentifier),
            displayName: config.name
        )
        if #available(macOS 15.0, *) {
            domain.userInfo = try FileProviderDomainStateStore.bootstrapUserInfo(for: config)
        }
        return domain
    }

    private func refreshExistingDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain? {
        try await findDomain(for: config)
    }

    private func refreshDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        guard let existingDomain = try await findDomain(for: config) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        return existingDomain
    }

    private func resolveDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        guard let domain = try await findDomain(for: config) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        return domain
    }

    private func persistBootstrapConfig(for config: ConnectionConfig) throws {
        try FileProviderDomainStateStore.saveBootstrapConfig(config)
    }

    private func removeBootstrapConfig(for config: ConnectionConfig) throws {
        try FileProviderDomainStateStore.removeBootstrapConfig(for: config.domainIdentifier)
    }
}
