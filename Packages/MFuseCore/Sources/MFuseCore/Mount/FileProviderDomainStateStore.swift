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

    public func removeBootstrapConfig() throws {
        let url = try bootstrapConfigURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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
        if #available(macOS 15.0, *) {
            guard let url = try Self.prepareManagedDirectoryURL(try manager.stateDirectoryURL()) else {
                throw RemoteFileSystemError.operationFailed(
                    "File Provider state directory unavailable for \(domain.identifier.rawValue)"
                )
            }
            return url
        }

        let baseURL = try Self.requiredAppGroupContainerURL()
        let fallbackURL = baseURL
            .appendingPathComponent("File Provider State", isDirectory: true)
            .appendingPathComponent(domain.identifier.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: fallbackURL, withIntermediateDirectories: true)
        return fallbackURL
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
        return try JSONDecoder().decode(ConnectionConfig.self, from: payload)
    }

    public static func removeBootstrapConfig(for domainIdentifier: String) throws {
        let url = try bootstrapConfigURL(for: domainIdentifier)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func bootstrapStorageURL(for domainIdentifier: String) throws -> URL {
        let baseURL = try requiredAppGroupContainerURL()

        let directoryURL = baseURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("Bootstrap", isDirectory: true)
            .appendingPathComponent(domainIdentifier, isDirectory: true)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
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
