import Foundation
import FileProvider

/// MountProvider backed by macOS File Provider (NSFileProviderDomain).
/// Mounts appear under ~/Library/CloudStorage/. Symlinks created at ~/MFuse/<name>.
public final class FileProviderMountProvider: MountProvider {

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
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try await NSFileProviderManager.add(domain)
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

        let sanitizedName = Self.sanitizeName(config.name)
        let symlinkURL = baseDir.appendingPathComponent(sanitizedName)

        // Remove existing symlink/file at path
        if fm.fileExists(atPath: symlinkURL.path) || (try? fm.attributesOfItem(atPath: symlinkURL.path)) != nil {
            try? fm.removeItem(at: symlinkURL)
        }

        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: mountURL)
        return symlinkURL
    }

    public func removeSymlink(for config: ConnectionConfig) async throws {
        let fm = FileManager.default
        let sanitizedName = Self.sanitizeName(config.name)
        let symlinkURL = Self.symlinkBaseURL.appendingPathComponent(sanitizedName)

        if fm.fileExists(atPath: symlinkURL.path) || (try? fm.attributesOfItem(atPath: symlinkURL.path)) != nil {
            try fm.removeItem(at: symlinkURL)
        }
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

    private func findDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain? {
        let domainID = NSFileProviderDomainIdentifier(rawValue: config.domainIdentifier)
        let domains = try await NSFileProviderManager.domains()
        return domains.first(where: { $0.identifier == domainID })
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
        guard try await findDomain(for: config) != nil else {
            return nil
        }
        return try await refreshDomain(for: config)
    }

    private func refreshDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        guard try await findDomain(for: config) != nil else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        let updatedDomain = try makeDomain(for: config)
        try await NSFileProviderManager.add(updatedDomain)
        return updatedDomain
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
