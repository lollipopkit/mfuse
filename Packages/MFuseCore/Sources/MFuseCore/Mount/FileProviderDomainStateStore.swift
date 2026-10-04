#if canImport(FileProvider)
import FileProvider
import Foundation
import os.log

/// Resolves File Provider managed per-domain state directories on macOS.
public struct FileProviderDomainStateStore: @unchecked Sendable {

    public static let bootstrapUserInfoKey = "com.lollipopkit.mfuse.bootstrapConfig"
    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse",
        category: "FileProviderDomainStateStore"
    )

    public let domain: NSFileProviderDomain
    public let manager: NSFileProviderManager

    public init?(domain: NSFileProviderDomain) {
        guard let manager = NSFileProviderManager(for: domain) else {
            return nil
        }
        self.domain = domain
        self.manager = manager
    }

    public func metadataCacheURL() throws -> URL {
        try stateStorageURL().appendingPathComponent(AppGroupConstants.metadataCacheDB)
    }

    public func syncAnchorStoreURL() throws -> URL {
        try stateStorageURL().appendingPathComponent(AppGroupConstants.syncAnchorDB)
    }

    public func contentCacheDirectoryURL() throws -> URL {
        let directoryURL = try stateStorageURL().appendingPathComponent("content_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    public func bootstrapConfigURL() throws -> URL {
        let directoryURL = try Self.bootstrapStorageURL(for: domain.identifier.rawValue)
        return directoryURL.appendingPathComponent("connection-bootstrap.json")
    }

    public func loadBootstrapConfig() throws -> ConnectionConfig? {
        let url = try bootstrapConfigURL()
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ConnectionConfig.self, from: data)
        } catch {
            Self.logger.error(
                "Failed to decode bootstrap config at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    public func saveBootstrapConfig(_ config: ConnectionConfig) throws {
        let url = try bootstrapConfigURL()
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
    }

    public func temporaryFileURL(for identifier: String, extension ext: String = "tmp") throws -> URL {
        let directoryURL: URL
        if let temporaryDirectoryURL = try temporaryDirectoryURL() {
            directoryURL = temporaryDirectoryURL
        } else {
            directoryURL = try stateStorageURL().appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL.appendingPathComponent("\(identifier).\(ext)")
    }

    public func stateStorageURL() throws -> URL {
        let baseURL = try Self.requiredAppGroupContainerURL()
        return try Self.providerStateStorageURL(
            containerURL: baseURL,
            domainIdentifier: domain.identifier.rawValue
        )
    }

    public func temporaryDirectoryURL() throws -> URL? {
        if #available(macOS 15.0, *) {
            return try Self.prepareManagedDirectoryURL(try manager.temporaryDirectoryURL())
        }
        return nil
    }

    public func close() {
        // File Provider managed state and temporary directories are directly accessible
        // to the extension process; no scoped access bookkeeping is required.
    }

    @available(macOS 15.0, *)
    static func prepareManagedDirectoryURL(_ url: URL?) throws -> URL? {
        guard let url else {
            return nil
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func bootstrapConfigURL(for domainIdentifier: String) throws -> URL {
        try bootstrapStorageURL(for: domainIdentifier)
            .appendingPathComponent("connection-bootstrap.json")
    }

    public static func loadBootstrapConfig(for domainIdentifier: String) throws -> ConnectionConfig? {
        let url = try bootstrapConfigURL(for: domainIdentifier)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ConnectionConfig.self, from: data)
        } catch {
            logger.error(
                "Failed to decode bootstrap config at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    public static func saveBootstrapConfig(_ config: ConnectionConfig) throws {
        let url = try bootstrapConfigURL(for: config.domainIdentifier)
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
    }

    public static func bootstrapUserInfo(for config: ConnectionConfig) throws -> [String: Any] {
        let payload = try JSONEncoder().encode(config)
        return [bootstrapUserInfoKey: payload]
    }

    public static func loadBootstrapConfig(from userInfo: [AnyHashable: Any]?) throws -> ConnectionConfig? {
        guard
            let userInfo,
            let payload = userInfo[bootstrapUserInfoKey] as? Data
        else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ConnectionConfig.self, from: payload)
        } catch {
            logger.error(
                "Failed to decode \(String(describing: ConnectionConfig.self), privacy: .public) bootstrap config from userInfo payload: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Removes everything kept on disk for a domain: the bootstrap snapshot and the
    /// provider state directory holding its metadata cache, cached file contents and sync
    /// anchors. Removing a connection has to take these with it — they are copies of the
    /// user's remote files and listings, and nothing else ever deletes them.
    public static func removeDomainState(for domainIdentifier: String) throws {
        try removeDomainState(for: domainIdentifier, containerURL: requiredAppGroupContainerURL())
    }

    /// Each directory is attempted even when another fails: a bootstrap snapshot that
    /// cannot be removed must not keep the cached file contents next to it on disk. The
    /// first failure is rethrown once both have been tried.
    static func removeDomainState(for domainIdentifier: String, containerURL: URL) throws {
        var firstError: Error?
        for rootURL in domainStateRootURLs(containerURL: containerURL) {
            let directoryURL = rootURL.appendingPathComponent(domainIdentifier, isDirectory: true)
            do {
                // Removed outright rather than after an existence check, which a directory
                // vanishing in between would turn into a reported failure.
                try FileManager.default.removeItem(at: directoryURL)
            } catch where isNotFound(error) {
                continue
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    /// Removes the on-disk state of every domain not in `identifiersToKeep`, returning the
    /// identifiers whose removal failed.
    ///
    /// Covers state that `removeDomainState(for:)` never got to: a removal whose cleanup
    /// failed after the domain was gone, an extension that recreated its directory while
    /// being torn down, and connections removed by builds that did not delete this state.
    /// Only UUID-named entries are touched, since every domain identifier is one.
    public static func removeOrphanedDomainStates(
        keeping identifiersToKeep: Set<String>
    ) throws -> [(identifier: String, error: Error)] {
        try removeOrphanedDomainStates(keeping: identifiersToKeep, containerURL: requiredAppGroupContainerURL())
    }

    static func removeOrphanedDomainStates(
        keeping identifiersToKeep: Set<String>,
        containerURL: URL
    ) throws -> [(identifier: String, error: Error)] {
        var orphanedIdentifiers = Set<String>()
        for rootURL in domainStateRootURLs(containerURL: containerURL) {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            } catch where isNotFound(error) {
                // Nothing has ever been stored under this root.
                continue
            }
            for name in names where UUID(uuidString: name) != nil && !identifiersToKeep.contains(name) {
                orphanedIdentifiers.insert(name)
            }
        }

        var failures: [(identifier: String, error: Error)] = []
        for identifier in orphanedIdentifiers.sorted() {
            do {
                try removeDomainState(for: identifier, containerURL: containerURL)
            } catch {
                failures.append((identifier, error))
            }
        }
        return failures
    }

    public static func providerStateStorageURL(
        containerURL: URL,
        domainIdentifier: String
    ) throws -> URL {
        let directoryURL = providerStateRootURL(containerURL: containerURL)
            .appendingPathComponent(domainIdentifier, isDirectory: true)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private static func bootstrapStorageURL(for domainIdentifier: String) throws -> URL {
        let directoryURL = bootstrapRootURL(containerURL: try requiredAppGroupContainerURL())
            .appendingPathComponent(domainIdentifier, isDirectory: true)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private static func supportDirectoryURL(containerURL: URL) -> URL {
        containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
    }

    private static func providerStateRootURL(containerURL: URL) -> URL {
        supportDirectoryURL(containerURL: containerURL)
            .appendingPathComponent("FileProviderState", isDirectory: true)
    }

    private static func bootstrapRootURL(containerURL: URL) -> URL {
        supportDirectoryURL(containerURL: containerURL)
            .appendingPathComponent("Bootstrap", isDirectory: true)
    }

    /// Whether a file operation failed only because its target does not exist. Anything
    /// else — a permission error above all — is a real failure and is propagated.
    private static func isNotFound(_ error: Error) -> Bool {
        guard let cocoaError = error as? CocoaError else { return false }
        return cocoaError.code == .fileNoSuchFile || cocoaError.code == .fileReadNoSuchFile
    }

    /// Every directory that holds one subdirectory per domain identifier.
    private static func domainStateRootURLs(containerURL: URL) -> [URL] {
        [bootstrapRootURL(containerURL: containerURL), providerStateRootURL(containerURL: containerURL)]
    }

    private static func requiredAppGroupContainerURL() throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        ) else {
            logger.error(
                "FileProviderDomainStateStore app group container unavailable for \(AppGroupConstants.groupIdentifier, privacy: .public)"
            )
            throw RemoteFileSystemError.operationFailed(
                "App Group container unavailable for \(AppGroupConstants.groupIdentifier)"
            )
        }

        return containerURL
    }
}
#endif
