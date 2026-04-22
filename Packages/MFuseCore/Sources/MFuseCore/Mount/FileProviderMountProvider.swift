import Foundation
import FileProvider
import os.log

/// MountProvider backed by macOS File Provider (NSFileProviderDomain).
/// Mounts appear under ~/Library/CloudStorage/. Convenience links are created in a writable shortcuts directory.
public final class FileProviderMountProvider: MountProvider {

    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse.core",
        category: "FileProviderMountProvider"
    )

    public static let defaultSymlinkBaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("MFuse", isDirectory: true)

    /// Base directory for convenience symlinks.
    public let symlinkBaseURL: URL

    public init(
        symlinkBaseURL: URL = defaultSymlinkBaseURL
    ) {
        self.symlinkBaseURL = symlinkBaseURL
    }

    public func ensureRegistered(config: ConnectionConfig) async throws {
        let existingDomain = try await findDomain(for: config)
        let domain = try makeDomain(for: config)

        do {
            try await NSFileProviderManager.add(domain)
        } catch {
            if isExtensionNotEnabledError(error) {
                throw MountError.extensionNotEnabled
            }
            if shouldRetryMountAfterDomainRefresh(error) {
                if let stale = try await findDomain(for: config) {
                    try await NSFileProviderManager.remove(stale)
                    try await Task.sleep(nanoseconds: 500_000_000)
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
            } else {
                throw error
            }
        }

        do {
            try persistBootstrapConfig(for: config)
        } catch {
            if existingDomain == nil {
                let persistError = error
                do {
                    try await NSFileProviderManager.remove(domain)
                } catch {
                    let rollbackError = error
                    Self.logger.error(
                        "persistBootstrapConfig(for:) failed for domain \(domain.identifier.rawValue, privacy: .public): \(persistError.localizedDescription, privacy: .public); rollback via NSFileProviderManager.remove(domain) also failed: \(rollbackError.localizedDescription, privacy: .public)"
                    )
                    throw MountError.mountFailed(
                        "persistBootstrapConfig(for:) failed for \(domain.identifier.rawValue): \(persistError.localizedDescription); rollback via NSFileProviderManager.remove(domain) failed: \(rollbackError.localizedDescription)"
                    )
                }
            }
            throw error
        }
    }

    public func unregister(config: ConnectionConfig) async throws {
        if let domain = try await findDomain(for: config) {
            try await NSFileProviderManager.remove(domain)
        }
        try removeBootstrapConfig(for: config)
    }

    public func reconnect(config: ConnectionConfig) async throws {
        let domain = try await domainOrThrow(for: config)
        try persistBootstrapConfig(for: config)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw MountError.managerNotFound(config.domainIdentifier)
        }
        try await manager.reconnect()
    }

    public func disconnect(config: ConnectionConfig) async throws {
        let domain = try await domainOrThrow(for: config)
        try persistBootstrapConfig(for: config)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw MountError.managerNotFound(config.domainIdentifier)
        }
        try await manager.disconnect(
            reason: "Disconnected from MFuse",
            options: []
        )
    }

    public func domainStates() async throws -> [RegisteredDomainState] {
        let domains = try await NSFileProviderManager.domains()
        return domains.map {
            RegisteredDomainState(
                identifier: $0.identifier.rawValue,
                isDisconnected: $0.isDisconnected
            )
        }
    }

    public func signalEnumerator(for config: ConnectionConfig) async throws {
        guard let domain = try await refreshExistingDomain(for: config) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        try persistBootstrapConfig(for: config)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw MountError.managerNotFound(config.domainIdentifier)
        }
        try await manager.signalEnumerator(for: .workingSet)
    }

    public func mountURL(for config: ConnectionConfig) async throws -> URL? {
        try await resolveMountURL(for: config)
    }

    @discardableResult
    public func createSymlink(for config: ConnectionConfig) async throws -> URL? {
        guard let mountURL = try await mountURL(for: config) else { return nil }

        let fileManager = FileManager.default
        let baseDir = symlinkBaseURL

        let symlinkURL = Self.symlinkURL(for: config, baseDir: baseDir)
        let parentDirectoryURL = symlinkURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
        try cleanupLegacyShortcutIfNeeded(for: config)

        try removeManagedSymlinkIfNeeded(at: symlinkURL, expectedDestinationURL: mountURL)
        guard !fileManager.fileExists(atPath: symlinkURL.path) else {
            Self.logger.warning(
                "Skipping symlink creation because target path is occupied by a non-managed item: \(symlinkURL.path, privacy: .public)"
            )
            return nil
        }

        do {
            try fileManager.createSymbolicLink(
                atPath: symlinkURL.path,
                withDestinationPath: mountURL.path
            )
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(
                atPath: symlinkURL.path,
                withDestinationPath: mountURL.path
            )
        }
        return symlinkURL
    }

    public func removeSymlink(for config: ConnectionConfig) async throws {
        let expectedDestinationURL = try await resolveMountURL(for: config)
        let symlinkURL = Self.symlinkURL(for: config, baseDir: symlinkBaseURL)
        try removeManagedSymlinkIfNeeded(at: symlinkURL, expectedDestinationURL: expectedDestinationURL)
        try cleanupLegacyShortcutIfNeeded(for: config)
    }

    /// Sanitize a connection name for use as a filesystem directory name.
    public static func sanitizeName(_ name: String) -> String {
        var result = String()
        result.reserveCapacity(name.count)

        for character in name {
            switch character {
            case "/", ":", "\0":
                result.append("-")
            default:
                result.append(character)
            }
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

    public static func symlinkDisplayPath(for config: ConnectionConfig, baseDir: URL) -> String {
        symlinkURL(for: config, baseDir: baseDir).path
    }

    static func legacySymlinkBaseURL(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        )
    ) -> URL? {
        guard let containerURL else {
            return nil
        }

        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("Shortcuts", isDirectory: true)
    }

    public static func shouldRemoveManagedSymlink(at url: URL, fileManager: FileManager) -> Bool {
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

    public static func matchesManagedSymlinkFilename(_ name: String) -> Bool {
        let uuidLength = 36
        guard name.count > uuidLength else {
            return false
        }

        let uuidStartIndex = name.index(name.endIndex, offsetBy: -uuidLength)
        guard uuidStartIndex > name.startIndex else {
            return false
        }

        let separatorIndex = name.index(before: uuidStartIndex)
        guard name[separatorIndex] == "-" else {
            return false
        }

        let prefix = name[..<separatorIndex]
        let suffix = name[uuidStartIndex...]
        return !prefix.isEmpty && UUID(uuidString: String(suffix)) != nil
    }

    public static func isManagedMountDestination(_ url: URL) -> Bool {
        let cloudStorageRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .standardizedFileURL

        let destinationPath = url.path
        let rootPath = cloudStorageRoot.path
        return destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/")
    }

    func itemType(at url: URL) throws -> FileAttributeType? {
        let path = url.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil else {
            return nil
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            return attributes[.type] as? FileAttributeType
        } catch let error as NSError
            where (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
                || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT) {
            return nil
        }
    }

    private func removeManagedSymlinkIfNeeded(at symlinkURL: URL, expectedDestinationURL: URL?) throws {
        let fm = FileManager.default
        guard let itemType = try itemType(at: symlinkURL) else {
            return
        }
        guard itemType == .typeSymbolicLink else {
            return
        }

        if let expectedDestinationURL {
            guard Self.matchesManagedSymlinkFilename(symlinkURL.lastPathComponent) else {
                return
            }

            if let destinationPath = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path) {
                let resolvedDestinationURL = URL(
                    fileURLWithPath: destinationPath,
                    relativeTo: symlinkURL.deletingLastPathComponent()
                ).standardizedFileURL
                if resolvedDestinationURL == expectedDestinationURL.standardizedFileURL {
                    try fm.removeItem(at: symlinkURL)
                    return
                }
            }

            // Replace any managed same-name symlink so the current config always points
            // at the latest CloudStorage mount instead of a stale legacy container path.
            try fm.removeItem(at: symlinkURL)
            return
        }

        guard Self.shouldRemoveManagedSymlink(at: symlinkURL, fileManager: fm) else {
            return
        }

        try fm.removeItem(at: symlinkURL)
    }

    private func cleanupLegacyShortcutIfNeeded(for config: ConnectionConfig) throws {
        guard let legacyBaseURL = Self.legacySymlinkBaseURL(),
              legacyBaseURL.standardizedFileURL != symlinkBaseURL.standardizedFileURL else {
            return
        }

        let legacyShortcutURL = Self.symlinkURL(for: config, baseDir: legacyBaseURL)
        let fm = FileManager.default

        if Self.shouldRemoveManagedSymlink(at: legacyShortcutURL, fileManager: fm) {
            try? fm.removeItem(at: legacyShortcutURL)
            return
        }

        guard let itemType = try itemType(at: legacyShortcutURL),
              itemType == .typeDirectory,
              Self.matchesManagedSymlinkFilename(legacyShortcutURL.lastPathComponent),
              let contents = try? fm.contentsOfDirectory(atPath: legacyShortcutURL.path),
              contents.isEmpty else {
            return
        }

        try? fm.removeItem(at: legacyShortcutURL)
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

    private func shouldRetryMountAfterDomainRefresh(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError
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

    private func resolveMountURL(for config: ConnectionConfig) async throws -> URL? {
        guard let domain = try await refreshExistingDomain(for: config) else { return nil }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw MountError.managerNotFound(config.domainIdentifier)
        }
        return try await manager.getUserVisibleURL(for: .rootContainer)
    }

    private func domainOrThrow(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        guard let domain = try await findDomain(for: config) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        return domain
    }

    private func refreshDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        try await domainOrThrow(for: config)
    }

    private func resolveDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        try await domainOrThrow(for: config)
    }

    private func persistBootstrapConfig(for config: ConnectionConfig) throws {
        try FileProviderDomainStateStore.saveBootstrapConfig(config)
    }

    private func removeBootstrapConfig(for config: ConnectionConfig) throws {
        try FileProviderDomainStateStore.removeBootstrapConfig(for: config.domainIdentifier)
    }
}
